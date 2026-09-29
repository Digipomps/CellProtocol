// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import MultipeerConnectivity
import XCTest
@testable import CellApple
@testable import CellBase

final class EntityScannerConsumerSecurityTests: XCTestCase {
    private var oldRoot: String?, oldKey: Data?, oldResolver: CellResolverProtocol?
    private var root: URL!
    override func setUpWithError() throws {
        oldRoot = CellBase.documentRootPath; oldKey = CellBase.persistedCellMasterKey
        oldResolver = CellBase.defaultCellResolver
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cp53-consumer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path; CellBase.persistedCellMasterKey = Data(repeating: 71, count: 32)
    }
    override func tearDownWithError() throws {
        CellBase.documentRootPath = oldRoot; CellBase.persistedCellMasterKey = oldKey
        CellBase.defaultCellResolver = oldResolver
        try FileManager.default.removeItem(at: root)
    }

    @MainActor func testEverySignedAcceptanceBindingRejectsBeforeStateOrStorageAndRealEncounterPersists() async throws {
        let f = try await ConsumerFixture(); defer { f.stop() }
        let request = try await f.request()
        let valid = try await f.acceptance(request)
        let baseline = try f.disk()
        let wrong: [String: ValueType] = [
            "messageType": .string("request"), "protocolVersion": .string("entity-contact-v0"),
            "requestHash": .string("wrong"), "requestId": .string(UUID().uuidString),
            "encounterId": .string(UUID().uuidString), "requesterSessionUUID": .string("wrong-local"),
            "responderSessionUUID": .string("wrong-remote"), "remoteUUID": .string("wrong-target"),
            "responderIdentityUUID": .string(UUID().uuidString), "acceptanceHash": .string("wrong"),
            "createdAt": .float(Date().timeIntervalSince1970 - 61)
        ]
        for (field, value) in wrong.sorted(by: { $0.key < $1.key }) {
            var changed = valid; changed[field] = value
            changed = try await f.signAcceptance(changed, keepHash: field == "acceptanceHash")
            try await f.deliver(changed)
            XCTAssertEqual(f.established, 0, field)
            XCTAssertEqual(try f.disk(), baseline, field)
            XCTAssertNotNil(f.cell.pendingRequests.find(.outgoing, id: f.id(request), context: f.context), field)
        }
        var unrelated = valid
        let stranger = await ScannerPair.owner()
        unrelated["responderIdentity"] = .identity(stranger); unrelated["responderIdentityUUID"] = .string(stranger.uuid)
        unrelated = try await f.signAcceptance(unrelated, signer: stranger)
        try await f.deliver(unrelated)
        XCTAssertEqual(f.established, 0); XCTAssertEqual(try f.disk(), baseline)
        // Same request and valid signature, delivered on a different proved channel.
        try await f.pair.addThirdPeer()
        try await f.receiveDirect(valid, context: f.pair.a.consumerContext(remoteUUID: f.pair.c!.mySessionUUID))
        XCTAssertEqual(f.established, 0); XCTAssertEqual(try f.disk(), baseline)
        XCTAssertNotNil(f.cell.pendingRequests.find(.outgoing, id: f.id(request), context: f.context), "pending before valid")
        try await f.deliver(valid)
        XCTAssertEqual(f.established, 1)
        let stored = try await f.anchor.get(keypath: "proofs.encounters.\(f.id(request))", requester: f.pair.a.owner)
        guard case let .object(encounter) = stored else { return XCTFail("Real encounter missing") }
        guard case let .object(storedRequest)? = encounter["requestProof"], case let .object(storedAcceptance)? = encounter["acceptanceProof"] else { return XCTFail("Stored proofs missing") }
        XCTAssertEqual(try f.canonical(storedRequest), try f.canonical(request))
        XCTAssertEqual(try f.canonical(storedAcceptance), try f.canonical(valid))
        XCTAssertTrue(CellPersistenceCrypto.isEncryptedEnvelope(try f.disk()))
        try await f.anchor.reloadStorage()
        let reloaded = try await f.anchor.get(keypath: "proofs.encounters.\(f.id(request))", requester: f.pair.a.owner)
        guard case let .object(reloadedObject) = reloaded else { return XCTFail("Reloaded encounter missing") }
        XCTAssertEqual(try f.canonical(reloadedObject), try f.canonical(encounter))
        try await f.deliver(valid) // consumed replay cannot store or publish twice
        XCTAssertEqual(f.established, 1)
    }

    @MainActor func testRealRequestAndUserAcceptanceStoreBothSidesAndRejectSameUUIDOtherKey() async throws {
        let f = try await ConsumerFixture(); defer { f.stop() }
        let remoteCell = await EntityScannerCell(owner: f.pair.b.owner)
        remoteCell.connectService = f.pair.b; remoteCell.requester = f.pair.b.owner; f.pair.b.radarDelegate = remoteCell
        defer { remoteCell.pendingRequests.reset(); remoteCell.connectService = nil; f.pair.b.radarDelegate = nil }
        let remoteAnchor = await EntityAnchorCell(owner: f.pair.b.owner)
        try await f.resolver.registerNamedEmitCell(name: "EntityAnchor", emitCell: remoteAnchor, scope: .identityUnique, identity: f.pair.b.owner)
        let request = try await f.request()
        let remoteContext = try f.pair.b.consumerContext(remoteUUID: f.pair.a.mySessionUUID)
        XCTAssertNotNil(remoteCell.pendingRequests.find(.incoming, id: f.id(request), context: remoteContext))
        let vault = MockIdentityVault()
        var alias = Identity(f.pair.b.owner.uuid, displayName: "unrelated key", identityVault: vault)
        await vault.addIdentity(identity: &alias, for: "alias")
        var wrong = try await f.acceptance(request)
        wrong["responderIdentity"] = .identity(alias)
        wrong = try await f.signAcceptance(wrong, signer: alias)
        try await f.deliver(wrong)
        XCTAssertEqual(f.established, 0)
        let result = try await remoteCell.set(keypath: "acceptContact", value: .object(request), requester: f.pair.b.owner)
        guard case let .object(reply)? = result else { return XCTFail("Missing acceptance result") }
        XCTAssertEqual(reply["status"], .string("accepted"))
        try await f.pair.deliverNext()
        XCTAssertEqual(f.established, 1)
        for (anchor, owner) in [(f.anchor, f.pair.a.owner), (remoteAnchor, f.pair.b.owner)] {
            let value = try await anchor.get(keypath: "proofs.encounters.\(f.id(request))", requester: owner)
            guard case let .object(encounter) = value else { return XCTFail("Missing stored encounter") }
            XCTAssertEqual(encounter["requestId"], .string(f.id(request)))
        }
        let duplicate = try await remoteCell.set(keypath: "acceptContact", value: .object(request), requester: f.pair.b.owner)
        guard case let .object(denied)? = duplicate else { return XCTFail("Missing replay rejection") }
        XCTAssertEqual(denied["status"], .string("rejected"))
    }

    @MainActor func testSameSigningIdentityOnTwoSessionsPersistsTheResponderRole() async throws {
        let owner = await ScannerPair.owner()
        let f = try await ConsumerFixture(sharedOwner: owner); defer { f.stop() }
        XCTAssertEqual(f.context.localIdentity, f.context.identity)
        XCTAssertNotEqual(f.context.localUUID, f.context.remoteUUID)
        let request = try await f.incomingRequest(signer: f.pair.b.owner, context: f.context)
        var flow = f.flow(request); flow.topic = "scanner.transport.contact.request"
        try await f.pair.b.sendScannerFlowElement(flow, remoteUUID: f.pair.a.mySessionUUID)
        try await f.pair.deliverNext()
        let result = try await f.cell.set(keypath: "acceptContact", value: .object(request), requester: owner)
        guard case let .object(reply)? = result else { return XCTFail("Missing acceptance") }
        XCTAssertEqual(reply["status"], .string("accepted"))
        let stored = try await f.anchor.get(keypath: "proofs.encounters.\(f.id(request))", requester: owner)
        guard case let .object(encounter) = stored else { return XCTFail("Missing real encounter") }
        XCTAssertEqual(encounter["localRole"], .string("responder"))
        XCTAssertEqual(encounter["localSessionUUID"], .string(f.context.localUUID))
        XCTAssertEqual(encounter["remoteSessionUUID"], .string(f.context.remoteUUID))
        XCTAssertEqual(f.established, 1)
    }

    @MainActor func testPendingExpiryDuringVerificationAndFutureSignedAcceptanceCannotPersist() async throws {
        let f = try await ConsumerFixture(); defer { f.stop() }
        let request = try await f.request()
        var future = try await f.acceptance(request)
        future["createdAt"] = .float(Date().timeIntervalSince1970 + 30)
        try await f.deliver(f.signAcceptance(future))
        XCTAssertEqual(f.established, 0)
        let barrier = ConsumerBarrier(), acceptance = try await f.acceptance(request)
        f.cell.consumerSuspension = { if $0 == "verification" { await barrier.hold() } }
        let receiving = Task { try await f.receiveDirect(acceptance) }
        try await barrier.waitFor(1)
        f.cell.pendingRequests.clock = { ProcessInfo.processInfo.systemUptime + 61 }
        await barrier.release(); try await receiving.value
        XCTAssertEqual(f.established, 0)
        XCTAssertEqual(f.cell.pendingRequests.snapshot.count, 0)
        XCTAssertTrue(f.context.isLive)
    }

    @MainActor func testSubscriberMayRevokeAfterCommitWithoutDeadlockOrLaterPublication() async throws {
        let f = try await ConsumerFixture(); defer { f.stop() }
        let request = try await f.request(), acceptance = try await f.acceptance(request)
        var events: [String] = []
        f.cell.consumerEventForTesting = { topic in
            events.append(topic)
            if topic == "scanner.contact.established" { f.context.session.revoke() }
        }
        do { try await f.receiveDirect(acceptance); XCTFail("Revoked operation continued") } catch {}
        XCTAssertEqual(events.filter { $0 == "scanner.contact.established" }.count, 1)
        XCTAssertFalse(events.contains("scanner.encounter.saved"))
        // Revocation cannot undo a commit that had already won admission.
        let value = try await f.anchor.get(keypath: "proofs.encounters.\(f.id(request))", requester: f.pair.a.owner)
        guard case .object = value else { return XCTFail("Admitted commit lost") }
    }

    @MainActor func testConcurrentAcceptancesConsumePendingExactlyOnce() async throws {
        let f = try await ConsumerFixture(); defer { f.stop() }
        let request = try await f.request(), barrier = ConsumerBarrier()
        let acceptance = try await f.acceptance(request)
        f.cell.consumerSuspension = { point in if point == "verification" { await barrier.hold() } }
        let first = Task { try await f.receiveDirect(acceptance) }
        let second = Task { try await f.receiveDirect(acceptance) }
        try await barrier.waitFor(2)
        XCTAssertGreaterThanOrEqual(f.pair.a.channelLimits.outstandingWorkCount, 2)
        await barrier.release()
        try await first.value; try await second.value
        XCTAssertEqual(f.established, 1)
        XCTAssertEqual(f.pair.a.channelLimits.outstandingWorkCount, 0)
        let trace = try await f.anchor.get(keypath: "trace", requester: f.pair.a.owner)
        guard case let .list(entries) = trace else { return XCTFail("One actual persistence trace required") }
        XCTAssertEqual(entries.count, 1)
    }

    @MainActor func testRealConsumerRetainsLeaseAcrossEveryAwaitAndDropsRetiredGeneration() async throws {
        for point in ["verification", "resolver", "storageResolved", "storage"] {
            for mode in ["revoke", "reconnect"] {
                let f = try await ConsumerFixture(); defer { f.stop() }
                let request = try await f.request(), barrier = ConsumerBarrier()
                let acceptance = try await f.acceptance(request), before = try f.disk()
                f.cell.consumerSuspension = { current in if current == point { await barrier.hold() } }
                try await f.pair.b.sendScannerFlowElement(f.flow(acceptance), remoteUUID: f.pair.a.mySessionUUID)
                let frame = try await f.pair.next()
                let receiving = f.pair.pa.enqueueReceive(frame.data)
                try await barrier.waitFor(1)
                XCTAssertEqual(f.pair.a.channelLimits.outstandingWorkCount, 1, point)
                if mode == "revoke" {
                    f.pair.a.channelLimits.revoke(identity: f.context.identity, domain: "nearby")
                } else { f.context.session.close() }
                await f.pair.pa.gate.close(); await f.pair.pb.gate.close()
                XCTAssertEqual(f.pair.a.channelLimits.outstandingWorkCount, 1, "Noncooperative \(point) still owns its lease")
                let (freshA, freshB) = try f.pair.prepareReconnect()
                try await f.pair.authenticateTransports(freshA, freshB)
                XCTAssertNotEqual(freshA.gate.session.generation, f.context.generation)
                await barrier.release()
                do { try await receiving.value; XCTFail("Retired consumer returned success") } catch {}
                XCTAssertEqual(f.established, 0, "\(point)/\(mode)")
                XCTAssertEqual(try f.disk(), before, "\(point)/\(mode)")
                XCTAssertEqual(f.cell.pendingRequests.snapshot.count, 0)
                XCTAssertEqual(f.pair.a.channelLimits.outstandingWorkCount, 0)
                XCTAssertNoThrow(try freshA.gate.session.check())
                // Actual consumer remains usable on the new generation.
                f.cell.consumerSuspension = nil
                let freshRequest = try await f.request()
                try await f.deliver(f.acceptance(freshRequest))
                XCTAssertEqual(f.established, 1)
            }
        }
    }

    @MainActor func testGlobalCountAndByteBudgetsWithManyAuthenticatedPeersAndContactIDs() async throws {
        var config = BridgeChannelLimits.Configuration()
        // The fixture models multiple remote hosts using one in-process pool.
        config.maximumConnectionsPerKey = 32
        let f = try await ConsumerFixture(limits: BridgeChannelLimits(configuration: config)); defer { f.stop() }
        var services = [ScannerService](), contexts = [f.context], signers = [f.pair.b.owner]
        defer { services.forEach { $0.stop() } }
        for i in 0..<8 {
            f.pair.cPeer = MCPeerID(displayName: "budget-\(i)")
            try await f.pair.addThirdPeer()
            services.append(f.pair.c!)
            contexts.append(try f.pair.a.consumerContext(remoteUUID: f.pair.c!.mySessionUUID))
            signers.append(f.pair.c!.owner)
        }
        for (index, context) in contexts.enumerated() {
            for _ in 0..<16 {
                let request = try await f.incomingRequest(signer: signers[index], context: context)
                var requestFlow = f.flow(request); requestFlow.topic = "scanner.transport.contact.request"
                let flow = requestFlow
                try await context.physical.gate.withAuthenticatedWork { try await f.cell.scannerFlowReceived(manager: f.pair.a, flowElement: flow, context: context) }
            }
        }
        XCTAssertEqual(f.cell.pendingRequests.snapshot.count, ScannerPendingRequests.maximumCount)
        XCTAssertLessThanOrEqual(f.cell.pendingRequests.snapshot.bytes, ScannerPendingRequests.maximumBytes)
        f.cell.pendingRequests.reset()
        for (index, context) in contexts.enumerated() {
            for _ in 0..<3 {
                let request = try await f.incomingRequest(signer: signers[index], context: context, padding: 60_000)
                var requestFlow = f.flow(request); requestFlow.topic = "scanner.transport.contact.request"
                let flow = requestFlow
                try await context.physical.gate.withAuthenticatedWork { try await f.cell.scannerFlowReceived(manager: f.pair.a, flowElement: flow, context: context) }
            }
        }
        let usage = f.cell.pendingRequests.snapshot
        XCTAssertLessThanOrEqual(usage.bytes, ScannerPendingRequests.maximumBytes)
        XCTAssertGreaterThan(usage.bytes, ScannerPendingRequests.maximumBytes - ScannerPendingRequests.maximumPayloadBytes)
        XCTAssertLessThan(usage.count, 18, "Global bytes, not only per-peer or count limits, must reject")
        f.cell.pendingRequests.clock = { ProcessInfo.processInfo.systemUptime + 61 }
        // Exercise the installed TTL task, without a new frame or snapshot prune.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(f.cell.pendingRequests.retainedCountForTesting, 0)
    }

    @MainActor func testPendingRequestFloodInvalidProofsTTLAndRetirementStayBoundedWithHealthyPeer() async throws {
        let f = try await ConsumerFixture(); defer { f.stop() }
        for i in 0..<1000 {
            var detailFlow = FlowElement(title: "detail", content: .object(["requestId": .string("detail-\(i)")]), properties: .init(type: .event, contentType: .object))
            detailFlow.topic = "scanner.probe.detail.request"
            let flow = detailFlow
            try await f.pair.pa.gate.withAuthenticatedWork { try await f.cell.scannerFlowReceived(manager: f.pair.a, flowElement: flow, context: f.context) }
        }
        XCTAssertEqual(f.cell.pendingRequests.snapshot.count, ScannerPendingRequests.maximumPerPeer)
        XCTAssertLessThanOrEqual(f.cell.pendingRequests.snapshot.bytes, ScannerPendingRequests.maximumBytesPerPeer)
        // An independent peer still admits records when B has reached its limit.
        try await f.pair.addThirdPeer()
        let healthy = try f.pair.a.consumerContext(remoteUUID: f.pair.c!.mySessionUUID)
        let request = try await f.incomingRequest(signer: f.pair.c!.owner, context: healthy)
        var flow = f.flow(request); flow.topic = "scanner.transport.contact.request"
        try await f.cell.scannerFlowReceived(manager: f.pair.a, flowElement: flow, context: healthy)
        XCTAssertNotNil(f.cell.pendingRequests.find(.incoming, id: f.id(request), context: healthy))
        // Invalid signed payloads never remain in pending state.
        let count = f.cell.pendingRequests.snapshot.count
        for _ in 0..<100 {
            var bad = try await f.incomingRequest(signer: f.pair.c!.owner, context: healthy)
            bad["requestSignature"] = .data(Data(repeating: 0, count: 64))
            var flow = f.flow(bad); flow.topic = "scanner.transport.contact.request"
            try await f.cell.scannerFlowReceived(manager: f.pair.a, flowElement: flow, context: healthy)
        }
        XCTAssertEqual(f.cell.pendingRequests.snapshot.count, count)
        f.context.session.close(); await f.pair.pa.gate.close()
        XCTAssertEqual(f.cell.pendingRequests.snapshot.count, 1)
        XCTAssertTrue(healthy.isLive)
        f.cell.pendingRequests.clock = { ProcessInfo.processInfo.systemUptime + 61 }
        XCTAssertEqual(f.cell.pendingRequests.snapshot.count, 0)
    }
}

private actor ConsumerBarrier {
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async { count += 1; await withCheckedContinuation { waiters.append($0) } }
    func release() { let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
    func waitFor(_ target: Int) async throws {
        for _ in 0..<5000 {
            if count >= target { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NSError(domain: "Consumer barrier timeout", code: target)
    }
}

@MainActor private final class ConsumerFixture {
    let pair: ScannerPair
    let cell: EntityScannerCell
    let anchor: EntityAnchorCell
    let resolver: MockCellResolver
    let context: ScannerConsumerContext
    var established = 0
    init(limits: BridgeChannelLimits = BridgeChannelLimits(), sharedOwner: Identity? = nil) async throws {
        pair = try await ScannerPair(limits: limits, ownerA: sharedOwner, ownerB: sharedOwner)
        try await pair.finish(pair.start())
        context = try pair.a.consumerContext(remoteUUID: pair.b.mySessionUUID)
        resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        cell = await EntityScannerCell(owner: pair.a.owner)
        cell.connectService = pair.a; cell.requester = pair.a.owner; pair.a.radarDelegate = cell
        anchor = await EntityAnchorCell(owner: pair.a.owner)
        try await resolver.registerNamedEmitCell(name: "EntityAnchor", emitCell: anchor, scope: .identityUnique, identity: pair.a.owner)
        let perspective = await GeneralCell(owner: pair.a.owner)
        await perspective.addInterceptForGet(requester: pair.a.owner, key: "perspective.state") { _, _ in .object([:]) }
        await perspective.addInterceptForGet(requester: pair.a.owner, key: "advertisedPurpose") { _, _ in .null }
        await perspective.addInterceptForSet(requester: pair.a.owner, key: "perspective.query.match") { _, _, _ in .object(["count": .integer(0)]) }
        try await resolver.registerNamedEmitCell(name: "Perspective", emitCell: perspective, scope: .identityUnique, identity: pair.a.owner)
        cell.consumerEventForTesting = { [weak self] topic in if topic == "scanner.contact.established" { self?.established += 1 } }
    }
    func stop() { cell.pendingRequests.reset(); cell.connectService = nil; pair.a.radarDelegate = nil; pair.stop() }
    func disk() throws -> Data { try Data(contentsOf: anchor.getCellDirectory().appendingPathComponent(EntityAnchorCell.storageFilename)) }
    func id(_ object: Object) -> String { if case let .string(id)? = object["requestId"] { return id }; return "missing" }
    func request() async throws -> Object {
        let result = try await cell.set(keypath: "requestContact", value: .string(pair.b.mySessionUUID), requester: pair.a.owner)
        guard case let .object(reply)? = result, case let .string(id)? = reply["requestId"] else { throw NSError(domain: "Request failed: \(String(describing: result))", code: 1) }
        let current = try pair.a.consumerContext(remoteUUID: pair.b.mySessionUUID)
        let record = try XCTUnwrap(cell.pendingRequests.find(.outgoing, id: id, context: current))
        // Consume real request wire at B, keeping both counters/receipts correct.
        try await pair.deliverNext()
        return record.payload
    }
    func acceptance(_ request: Object) async throws -> Object {
        try await signAcceptance([
            "protocolVersion": .string("entity-contact-v1"), "messageType": .string("accept"),
            "requestId": request["requestId"]!, "encounterId": request["encounterId"]!,
            "requestHash": .string(hash(request)), "createdAt": .float(Date().timeIntervalSince1970),
            "requesterSessionUUID": .string(pair.a.mySessionUUID), "responderSessionUUID": .string(pair.b.mySessionUUID),
            "remoteUUID": .string(pair.a.mySessionUUID), "responderIdentity": .identity(pair.b.owner),
            "responderIdentityUUID": .string(pair.b.owner.uuid)
        ])
    }
    func wire(_ object: Object) throws -> Object { try JSONDecoder().decode(Object.self, from: JSONEncoder().encode(object)) }
    func canonical(_ object: Object) throws -> Data { try FlowCanonicalEncoder.canonicalData(for: .object(wire(object))) }
    func hash(_ object: Object) throws -> String { try FlowHasher.sha256Hex(canonical(object)) }
    func signAcceptance(_ object: Object, signer: Identity? = nil, keepHash: Bool = false) async throws -> Object {
        var object = object; object["acceptanceSignature"] = nil
        if !keepHash { object["acceptanceHash"] = nil; object["acceptanceHash"] = .string(try hash(object)) }
        let bytes = try canonical(object), signer = signer ?? pair.b.owner
        let signed = try await signer.sign(data: bytes)
        let signature = try XCTUnwrap(signed)
        XCTAssertTrue(IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: bytes, identity: signer))
        object["acceptanceSignature"] = .data(signature); return object
    }
    func flow(_ object: Object) -> FlowElement {
        var flow = FlowElement(title: "accept", content: .object(object), properties: .init(type: .event, contentType: .object))
        flow.topic = "scanner.transport.contact.accept"; return flow
    }
    func deliver(_ acceptance: Object) async throws {
        let roundtrip = try JSONDecoder().decode(FlowElement.self, from: JSONEncoder().encode(flow(acceptance)))
        guard case var .object(payload) = roundtrip.content,
              case let .string(encoded)? = payload.removeValue(forKey: "acceptanceSignature"), let signature = Data(base64Encoded: encoded),
              let identity = payload["responderIdentity"] else { return XCTFail("Wire proof fields missing") }
        let signer = try JSONDecoder().decode(Identity.self, from: JSONEncoder().encode(identity))
        XCTAssertTrue(IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: try canonical(payload), identity: signer), "Round-trip must preserve signed bytes")
        try await pair.b.sendScannerFlowElement(flow(acceptance), remoteUUID: pair.a.mySessionUUID)
        let frame = try await pair.next()
        try await pair.deliver(frame)
    }
    func receiveDirect(_ acceptance: Object, context: ScannerConsumerContext? = nil) async throws {
        let context = context ?? self.context
        try await context.physical.gate.withAuthenticatedWork { @MainActor [self] in
            try await cell.scannerFlowReceived(manager: pair.a, flowElement: flow(acceptance), context: context)
        }
    }
    func incomingRequest(signer: Identity, context: ScannerConsumerContext, padding: Int = 0) async throws -> Object {
        let id = UUID().uuidString
        var request: Object = ["protocolVersion": .string("entity-contact-v1"), "messageType": .string("request"),
            "requestId": .string(id), "encounterId": .string(id), "createdAt": .float(Date().timeIntervalSince1970),
            "requesterSessionUUID": .string(context.remoteUUID), "remoteUUID": .string(context.localUUID),
            "requesterIdentity": .identity(signer), "requesterIdentityUUID": .string(signer.uuid)]
        if padding > 0 { request["padding"] = .string(String(repeating: "x", count: padding)) }
        request["requestHash"] = .string(try hash(request))
        let signature = try await signer.sign(data: canonical(request))
        request["requestSignature"] = .data(try XCTUnwrap(signature)); return request
    }
}
