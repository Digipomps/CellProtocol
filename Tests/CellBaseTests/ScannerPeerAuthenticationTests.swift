import Foundation
import MultipeerConnectivity
import XCTest
import Combine
@testable import CellApple
@testable import CellBase

final class ScannerPeerAuthenticationTests: XCTestCase {
    typealias A = BridgeChannelAuthentication
    private var previousResolver: CellResolverProtocol?
    override func setUp() { previousResolver = CellBase.defaultCellResolver }
    override func tearDown() { CellBase.defaultCellResolver = previousResolver }

    func testScannerMutualProofPrecedesBaseLookupAndRegistration() async throws {
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let pair = try await ScannerPair()
        defer { pair.stop() }
        XCTAssertNil(pair.pa.bridge); XCTAssertNil(pair.pb.bridge)
        let tasks = pair.start()
        try await pair.deliverNext() // hello; responder signs, but has no initiator proof
        XCTAssertNil(pair.pa.bridge); XCTAssertNil(pair.pb.bridge)
        try await pair.deliverNext() // responder proof; initiator still waits for accepted
        XCTAssertNil(pair.pa.bridge); XCTAssertNil(pair.pb.bridge)
        XCTAssertEqual(resolver.lookupCountSnapshot(), 0)
        let aRegistered = await resolver.cellUUID(for: pair.a.mySessionUUID)
        XCTAssertNil(aRegistered)
        try await pair.finish(tasks)
        XCTAssertNotNil(pair.pa.bridge); XCTAssertNotNil(pair.pb.bridge)
        XCTAssertEqual(resolver.lookupCountSnapshot(), 0)
        XCTAssertEqual(pair.pa.channelSession?.publicIdentity, try A.PublicIdentity(pair.b.owner))
        XCTAssertEqual(pair.pb.channelSession?.publicIdentity, try A.PublicIdentity(pair.a.owner))
        XCTAssertFalse(pair.wire.history.contains { $0.command.cmd == "ready" })
    }

    func testScannerRejectsCommandBeforeProofAndReportsConsumerFailure() async throws {
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let pair = try await ScannerPair(), observer = ScannerStatusObserver()
        pair.b.radarDelegate = observer; defer { pair.stop() }
        let command = BridgeCommand(cmd: "get", identity: pair.a.owner.publicIdentitySnapshot(), payload: .string("purposes"), cid: 1)
        do { try await pair.b.extractCommandFromData(A.encode(command), from: pair.aPeer); XCTFail() } catch {}
        XCTAssertEqual(resolver.lookupCountSnapshot(), 0)
        XCTAssertNil(pair.pb.bridge)
        XCTAssertTrue(observer.statuses.contains { $0.hasPrefix("bridgeFailed:") })
    }

    func testScannerForgedProofAndReplayedProofCannotCreateBase() async throws {
        let original = try await ScannerPair(); defer { original.stop() }
        let oldTasks = original.start(); try await original.finish(oldTasks)
        let oldProof = try XCTUnwrap(original.wire.history.first { $0.command.cmd == "channelAuthPeerProof" })
        for replay in [false, true] {
            let pair = try await ScannerPair(); defer { pair.stop() }
            let tasks = pair.start()
            try await pair.deliverNext(); try await pair.deliverNext()
            let pending = try await pair.next()
            XCTAssertEqual(pending.command.cmd, "channelAuthPeerProof")
            let current = try A.decode(A.Proof.self, from: Data(try XCTUnwrap(pending.command.payload?.stringValue()).utf8))
            let proof = replay ? oldProof.command : BridgeCommand(cmd: pending.command.cmd,
                payload: .string(String(decoding: try A.encode(A.Proof(sessionID: current.sessionID, generation: current.generation,
                    signature: Data(repeating: 0, count: 64))), as: UTF8.self)), cid: 0)
            do { try await pair.b.extractCommandFromData(A.encode(proof), from: pair.aPeer); XCTFail() } catch {}
            XCTAssertNil(pair.pb.bridge)
            await pair.pa.gate.close(); await pair.pb.gate.close()
            _ = try? await tasks.0.value; _ = try? await tasks.1.value
        }
    }

    func testScannerWrongPeerBindingAndRoleAreRejected() async throws {
        for field in ["initiator", "responder", "setupID", "role", "profile"] {
            let pair = try await ScannerPair(); defer { pair.stop() }
            let tasks = pair.start()
            let hello = try await pair.next()
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(hello.command.payload?.stringValue()).utf8)) as? [String: Any])
            if ["initiator", "responder", "setupID"].contains(field) {
                var endpoint = try XCTUnwrap(json["endpoint"] as? [String: Any]); endpoint[field] = UUID().uuidString; json["endpoint"] = endpoint
            } else { json[field] = field == "role" ? "responder" : A.profile }
            let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
            let changed = BridgeCommand(cmd: hello.command.cmd, payload: .string(String(decoding: bytes, as: UTF8.self)), cid: 0)
            do { try await pair.b.extractCommandFromData(A.encode(changed), from: pair.aPeer); XCTFail(field) } catch {}
            XCTAssertNil(pair.pb.bridge)
            await pair.pa.gate.close(); await pair.pb.gate.close()
            _ = try? await tasks.0.value; _ = try? await tasks.1.value
        }
    }

    func testScannerReconnectSamePeerIDRetiresOldTransportAndRejectsOldProof() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        let tasks = pair.start(); try await pair.finish(tasks)
        let old = pair.pa
        await pair.pa.gate.close(); await pair.pb.gate.close()
        let endpoint = try pair.a.makeInvitation(remoteUUID: pair.b.mySessionUUID)
        pair.b.receiveInvitation(from: pair.aPeer, endpoint: endpoint) { _, _ in }
        XCTAssertTrue(pair.b.respondToInvitation(remoteUUID: pair.a.mySessionUUID, accept: true))
        let fresh = try pair.a.prepareBridge(remoteUUID: pair.b.mySessionUUID, peerID: pair.bPeer)
        XCTAssertNotEqual(fresh.channelSession?.generation, old.channelSession?.generation)
        do { try await old.sendData(Data([1])); XCTFail("Old generation sent") } catch {}
        await old.close()
        XCTAssertTrue(try pair.a.prepareBridge(remoteUUID: pair.b.mySessionUUID, peerID: pair.bPeer) === fresh)
        let oldProof = try XCTUnwrap(pair.wire.history.first { $0.command.cmd == "channelAuthPeerChallenge" })
        do { try await pair.a.extractCommandFromData(A.encode(oldProof.command), from: pair.bPeer); XCTFail() } catch {}
        XCTAssertNil(fresh.bridge)
    }

    func testScannerRevocationClosesOnlyAffectedPeerAndReclaimsQuota() async throws {
        let limits = BridgeChannelLimits()
        let pair = try await ScannerPair(limits: limits), sibling = try await ScannerPair(limits: limits)
        defer { pair.stop(); sibling.stop() }
        try await pair.finish(pair.start()); try await sibling.finish(sibling.start())
        limits.revoke(identity: try A.PublicIdentity(pair.a.owner), domain: "nearby")
        XCTAssertThrowsError(try pair.pb.channelSession?.check())
        try sibling.pa.channelSession?.check(); try sibling.pb.channelSession?.check()
        await pair.pb.gate.close()
        for _ in 0..<100 where pair.b.bridgeDelegateCount != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(pair.b.bridgeDelegateCount, 0)
    }

    func testScannerQuotaPlusOneDoesNotCreateTransportOrBase() async throws {
        var config = BridgeChannelLimits.Configuration(); config.maximumConnections = 2
        let limits = BridgeChannelLimits(configuration: config), pair = try await ScannerPair(limits: limits)
        defer { pair.stop() }
        try await pair.finish(pair.start())
        do { let extra = try await ScannerPair(limits: limits); extra.stop(); XCTFail() }
        catch { XCTAssertEqual(error as? A.Failure, .capacity) }
        try pair.pa.channelSession?.check(); try pair.pb.channelSession?.check()
        await pair.pa.gate.close(); await pair.pb.gate.close()
        XCTAssertEqual(limits.retainedConnectionCount, 0)
        let recovered = try await ScannerPair(limits: limits); recovered.stop()
    }

    func testActualScannerSetupLobbyDescriptionAttachAndFeedForEitherInviter() async throws {
        for inviter in ["first-device", "second-device"] {
            let pair = try await ScannerPair(reverse: inviter == "second-device"); defer { pair.stop() }
            let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
            let lobby = await ScannerObservedLobby(owner: pair.a.owner)
            lobby.agreementTemplate.ensureGrant("r---", for: "feed")
            let agreement = Agreement(owner: pair.a.owner)
            agreement.grants = [Grant(keypath: "feed", permission: "r---"), Grant(keypath: "purposes", permission: "r---")]
            let granted = await lobby.addAgreement(agreement, for: pair.b.owner, authorizedBy: pair.a.owner)
            XCTAssertEqual(granted, .signed)
            let localScanner = await GeneralCell(owner: pair.a.owner), remoteScanner = await GeneralCell(owner: pair.b.owner)
            try await resolver.registerNamedEmitCell(name: "Lobby", emitCell: lobby, scope: .template, identity: pair.a.owner)
            try await resolver.registerNamedEmitCell(name: "EntityScanner", emitCell: localScanner, scope: .template, identity: pair.a.owner)
            try await resolver.registerNamedEmitCell(name: "ConnectRadar", emitCell: remoteScanner, scope: .template, identity: pair.b.owner)
            let localFlow = expectation(description: "local lobby \(inviter)"), remoteFlow = expectation(description: "remote lobby \(inviter)")
            let marker = "lobby-\(inviter)-\(UUID())"
            let localSubscription = localScanner.getFeedPublisher().sink(receiveCompletion: { _ in }, receiveValue: { if case let .string(value) = $0.content, value == marker { localFlow.fulfill() } })
            let remoteSubscription = remoteScanner.getFeedPublisher().sink(receiveCompletion: { _ in }, receiveValue: { if case let .string(value) = $0.content, value == marker { remoteFlow.fulfill() } })
            let pump = pair.pump(); defer { pump.cancel(); localSubscription.cancel(); remoteSubscription.cancel() }
            async let aSetup: Void = pair.a.setupBridge(remoteUUID: pair.b.mySessionUUID, peerID: pair.bPeer)
            async let bSetup: Void = pair.b.setupBridge(remoteUUID: pair.a.mySessionUUID, peerID: pair.aPeer)
            try await aSetup; try await bSetup
            XCTAssertEqual(pair.pb.bridge?.uuid, lobby.uuid, "Description installs actual Lobby UUID")
            let aRegistered = await resolver.cellUUID(for: pair.a.mySessionUUID), bRegistered = await resolver.cellUUID(for: pair.b.mySessionUUID)
            XCTAssertNotNil(aRegistered); XCTAssertNotNil(bRegistered)
            for _ in 0..<1000 where lobby.subscriptionCount < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(lobby.subscriptionCount, 2, "Both real feed subscriptions are installed before emission")
            lobby.pushFlowElement(FlowElement(title: "lobby", content: .string(marker), properties: .init(type: .content, contentType: .string)), requester: pair.a.owner)
            await fulfillment(of: [localFlow, remoteFlow], timeout: 3)
            XCTAssertTrue(pair.wire.history.contains { $0.command.cmd == "description" })
            XCTAssertTrue(pair.wire.history.contains { $0.command.cmd == "admit" })
            XCTAssertTrue(pair.wire.history.contains { $0.command.cmd == "feed" })
            XCTAssertTrue(pair.wire.errors.isEmpty, "\(pair.wire.errors)")
        }
    }

    func testScannerPeerProofDoesNotOverrideLobbyOwnerApproval() async throws {
        let pair = try await ScannerPair(), observer = ScannerStatusObserver()
        defer { pair.stop() }
        pair.b.radarDelegate = observer
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let lobby = await LobbyCell(owner: pair.a.owner)
        let local = await GeneralCell(owner: pair.a.owner), remote = await GeneralCell(owner: pair.b.owner)
        for (name, cell) in [("Lobby", lobby as GeneralCell), ("EntityScanner", local), ("ConnectRadar", remote)] {
            try await resolver.registerNamedEmitCell(name: name, emitCell: cell, scope: .template, identity: cell.owner)
        }
        let pump = pair.pump(); defer { pump.cancel() }
        let server = Task { try await pair.a.setupBridge(remoteUUID: pair.b.mySessionUUID, peerID: pair.bPeer) }
        do {
            try await pair.b.setupBridge(remoteUUID: pair.a.mySessionUUID, peerID: pair.aPeer)
            XCTFail("Transport proof granted unapproved Lobby access")
        } catch { XCTAssertEqual(error as? StreamState, .denied) }
        _ = try? await server.value
        XCTAssertTrue(pair.wire.history.contains { $0.command.cmd == "channelAuthPeerAccepted" })
        XCTAssertTrue(pair.wire.history.contains { $0.command.cmd == "agreement" })
        XCTAssertTrue(observer.statuses.contains { $0 == "bridgeFailed:denied" })
    }

    func testScannerDisconnectRetainsFeedQuotaUntilNoncooperativeWorkReturns() async throws {
        var configuration = BridgeChannelLimits.Configuration(); configuration.maximumFeeds = 1
        let limits = BridgeChannelLimits(configuration: configuration)
        let pair = try await ScannerPair(limits: limits), spare = try await ScannerPair(limits: limits)
        defer { pair.stop(); spare.stop() }
        try await pair.finish(pair.start()); try await spare.finish(spare.start())
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let cell = await ScannerObservedLobby(owner: pair.a.owner), barrier = ScannerWorkBarrier()
        let entered = expectation(description: "remote flow entered")
        cell.beforeFlow = { entered.fulfill(); await barrier.wait(); try Task.checkCancellation() }
        try await resolver.registerNamedEmitCell(name: "Lobby", emitCell: cell, scope: .template, identity: pair.a.owner)
        let command = BridgeCommand(cmd: "feed", identity: pair.b.owner.publicIdentitySnapshot(), payload: nil, cid: 3)
        let work = Task { try await pair.a.extractCommandFromData(A.encode(command), from: pair.bPeer) }
        await fulfillment(of: [entered], timeout: 2)
        await pair.pa.gate.close()
        XCTAssertEqual(limits.retainedConnectionCount, 4)
        XCTAssertThrowsError(try BridgeChannelResourceLease(session: spare.pa.gate.session, resource: .feed))
        XCTAssertGreaterThan(limits.outstandingWorkCount, 0)
        await barrier.resume()
        do { try await work.value; XCTFail("Disconnected work succeeded") } catch {}
        XCTAssertEqual(limits.retainedConnectionCount, 3)
        let recovered = try BridgeChannelResourceLease(session: spare.pa.gate.session, resource: .feed)
        recovered.release()
        XCTAssertEqual(limits.outstandingWorkCount, 0)
    }

    func testScannerCopiedPublicKeyAlwaysGetsProxyIncludingWithoutDelegate() async throws {
        let pair = try await ScannerPair(); defer { pair.stop() }
        let previous = CellBase.defaultIdentityVault; CellBase.defaultIdentityVault = pair.a.owner.identityVault
        defer { CellBase.defaultIdentityVault = previous }
        for delegate in [nil, BridgeBase(owner: pair.a.owner)] {
            let copy = pair.a.owner.publicIdentitySnapshot()
            let vault = await pair.a.identityVault(for: copy, bridgeDelegate: delegate)
            XCTAssertTrue(vault is BridgeIdentityVault)
            let exists = await vault.identityExistInVault(copy); XCTAssertFalse(exists)
        }
        let copied = pair.a.owner.publicIdentitySnapshot(); copied.identityVault = nil
        let unsigned = try await ScannerPair(ownerA: copied); defer { unsigned.stop() }
        let tasks = unsigned.start()
        try await unsigned.deliverNext()
        do { try await unsigned.deliverNext(); XCTFail("Copied key signed") } catch {}
        XCTAssertNil(unsigned.pa.bridge); XCTAssertNil(unsigned.pb.bridge)
        await unsigned.pa.gate.close(); await unsigned.pb.gate.close()
        _ = try? await tasks.0.value; _ = try? await tasks.1.value
    }
}

private final class ScannerPair {
    let a: ScannerService, b: ScannerService
    let aPeer = MCPeerID(displayName: "test-a"), bPeer = MCPeerID(displayName: "test-b")
    let pa: ScannerPeerTransport, pb: ScannerPeerTransport
    let wire = ScannerControlledWire()
    init(limits: BridgeChannelLimits = BridgeChannelLimits(), ownerA: Identity? = nil, reverse: Bool = false) async throws {
        let resolvedOwnerA: Identity
        if let ownerA { resolvedOwnerA = ownerA }
        else { resolvedOwnerA = await Self.owner() }
        let ownerB = await Self.owner()
        let suffix = UUID().uuidString
        a = ScannerService(owner: resolvedOwnerA, sessionUUID: (reverse ? "second-" : "first-") + suffix)
        b = ScannerService(owner: ownerB, sessionUUID: (reverse ? "first-" : "second-") + suffix)
        a.channelLimits = limits; b.channelLimits = limits
        a.foundPeersDict[b.mySessionUUID] = bPeer; a.reversedFoundPeersDict[bPeer] = b.mySessionUUID
        b.foundPeersDict[a.mySessionUUID] = aPeer; b.reversedFoundPeersDict[aPeer] = a.mySessionUUID
        let endpoint = try a.makeInvitation(remoteUUID: b.mySessionUUID)
        b.receiveInvitation(from: aPeer, endpoint: endpoint) { _, _ in }
        _ = b.respondToInvitation(remoteUUID: a.mySessionUUID, accept: true)
        pa = try a.prepareBridge(remoteUUID: b.mySessionUUID, peerID: bPeer)
        pb = try b.prepareBridge(remoteUUID: a.mySessionUUID, peerID: aPeer)
        a.peerSend = { [wire] data, _ in try wire.append(data, toB: true) }
        b.peerSend = { [wire] data, _ in try wire.append(data, toB: false) }
    }
    static func owner() async -> Identity {
        let vault = MockIdentityVault()
        var identity = Identity(UUID().uuidString, displayName: "test", identityVault: vault)
        await vault.addIdentity(identity: &identity, for: UUID().uuidString)
        return identity
    }
    func pump() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                if let frame = wire.take() {
                    Task {
                        do { try await (frame.toB ? b : a).extractCommandFromData(A.encode(frame.command), from: frame.toB ? aPeer : bPeer) }
                        catch { wire.failed(error) }
                    }
                } else { try? await Task.sleep(nanoseconds: 1_000_000) }
            }
        }
    }
    func start() -> (Task<Void, Error>, Task<Void, Error>) {
        (Task { try await pa.gate.startPeer() }, Task { try await pb.gate.startPeer() })
    }
    func next() async throws -> ScannerControlledWire.Frame {
        for _ in 0..<1000 {
            if let frame = wire.take() { return frame }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NSError(domain: "Scanner wire timeout", code: 1)
    }
    func deliverNext() async throws {
        let frame = try await next()
        try await (frame.toB ? b : a).extractCommandFromData(A.encode(frame.command), from: frame.toB ? aPeer : bPeer)
    }
    private typealias A = BridgeChannelAuthentication
    func finish(_ tasks: (Task<Void, Error>, Task<Void, Error>)) async throws {
        for _ in 0..<4 where pa.channelSession?.state != .authenticated || pb.channelSession?.state != .authenticated {
            try await deliverNext()
        }
        try await tasks.0.value; try await tasks.1.value
    }
    func stop() { a.stop(); b.stop() }
}
private final class ScannerControlledWire: @unchecked Sendable {
    struct Frame { let command: BridgeCommand; let toB: Bool }
    private let lock = NSLock()
    private var pending: [Frame] = [], recorded: [Frame] = []
    private var failures: [String] = []
    var errors: [String] { lock.withLock { failures } }
    func failed(_ error: Error) { lock.withLock { failures.append(String(describing: error)) } }
    var history: [Frame] { lock.withLock { recorded } }
    func append(_ data: Data, toB: Bool) throws {
        let frame = Frame(command: try JSONDecoder().decode(BridgeCommand.self, from: data), toB: toB)
        lock.withLock { pending.append(frame); recorded.append(frame) }
    }
    func take() -> Frame? { lock.withLock { pending.isEmpty ? nil : pending.removeFirst() } }
}
private final class ScannerStatusObserver: ConnectServiceDelegate {
    private let lock = NSLock(); private var values: [String] = []
    var statuses: [String] { lock.withLock { values } }
    func scannerStatusChanged(manager: ScannerService, status: String, remoteUUID: String?) { lock.withLock { values.append(status) } }
    func connectedDevicesChanged(manager: ScannerService, connectedDevices: [String]) {}
    func foundDevicesChanged(manager: ScannerService, foundDevice: MCPeerID, remoteUUID: String, discoveryInfo: [String: String]?) {}
    func lostDeviceChanged(manager: ScannerService, lostDevice: MCPeerID, remoteUUID: String) {}
    func invitationReceived(manager: ScannerService, peerID: MCPeerID, remoteUUID: String) {}
    func proximityChanged(manager: ScannerService, remoteUUID: String, distanceMeters: Float?, directionX: Float?, directionY: Float?, directionZ: Float?) {}
    func scannerFlowReceived(manager: ScannerService, flowElement: FlowElement, remoteUUID: String?) {}
}

private final class ScannerObservedLobby: LobbyCell {
    private let lock = NSLock()
    private var subscriptions = 0
    var subscriptionCount: Int { lock.withLock { subscriptions } }
    var beforeFlow: (() async throws -> Void)?
    override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
        try await beforeFlow?()
        return try await super.flow(requester: requester).handleEvents(receiveSubscription: { [weak self] _ in
            self?.lock.withLock { self?.subscriptions += 1 }
        }).eraseToAnyPublisher()
    }
}
private actor ScannerWorkBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func resume() { released = true; continuation?.resume(); continuation = nil }
}
