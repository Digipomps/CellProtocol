// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@_spi(HAVENRuntime) @testable import CellBase

final class BridgeIdentityBoundaryTests: XCTestCase {
    private final class PeerTransport: BridgeTransportProtocol {
        weak var delegate: BridgeDelegateProtocol?
        let peerVault: IdentityVaultProtocol?
        private let lock = NSLock()
        private var commands: [BridgeCommand] = []

        init(peerVault: IdentityVaultProtocol? = nil) { self.peerVault = peerVault }
        static func new() -> BridgeTransportProtocol { PeerTransport() }
        func setDelegate(_ delegate: BridgeDelegateProtocol) { self.delegate = delegate }
        func setup(_ endpointURL: URL, identity: Identity) async throws {}
        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
            // Deliberately reproduce transport hydration with the server's vault.
            CellBase.defaultIdentityVault!
        }
        func snapshot() -> [BridgeCommand] { lock.withLock { commands } }

        func sendData(_ data: Data) async throws {
            let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
            lock.withLock { commands.append(command) }
            guard command.command == .sign,
                  let identity = command.identity,
                  case let .signData(challenge) = command.payload else { return }
            let payload: ValueType
            if let peerVault,
               let signature = try? await peerVault.signMessageForIdentity(messageData: challenge, identity: identity) {
                payload = .signature(signature)
            } else {
                payload = .string("peer does not control this key")
            }
            try await delegate?.consumeResponse(command: BridgeCommand(
                cmd: Command.response.rawValue, payload: payload, cid: command.cid
            ))
        }
    }

    private final class PairedTransport: BridgeTransportProtocol {
        weak var peer: BridgeDelegateProtocol?
        private let lock = NSLock()
        private var commands: [BridgeCommand] = []
        static func new() -> BridgeTransportProtocol { PairedTransport() }
        func setDelegate(_ delegate: BridgeDelegateProtocol) {}
        func setup(_ endpointURL: URL, identity: Identity) async throws {}
        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { CellBase.defaultIdentityVault! }
        func snapshot() -> [BridgeCommand] { lock.withLock { commands } }
        func sendData(_ data: Data) async throws {
            let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
            lock.withLock { commands.append(command) }
            command.identity?.identityVault = CellBase.defaultIdentityVault
            if command.command == .response {
                try await peer?.consumeResponse(command: command)
            } else {
                try await peer?.consumeCommand(command: command)
            }
        }
    }

    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousDebug = false

    override func setUp() {
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousDebug = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.debugValidateAccessForEverything = previousDebug
    }

    private final class GuestSurface: GeneralCell {
        required init(owner: Identity) async {
            await super.init(owner: owner)
            await addInterceptForGet(requester: owner, key: "guest.configuration") { _, _ in
                .string("private-surface-\(owner.uuid)")
            }
        }
        required init(from decoder: Decoder) throws { try super.init(from: decoder) }
    }

    // Function: a fresh identity-unique guest surface can be resolved through
    // the real resolver, with the key proof travelling back to the peer.
    func testGuestCanCreateAndReadOwnSurfaceOverBridge() async throws {
        let vault = EphemeralIdentityVault()
        CellBase.defaultIdentityVault = vault
        let guest = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let house = await vault.identity(for: "house", makeNewIfNotFound: true)!
        let resolver = CellResolver.sharedInstance
        CellBase.defaultCellResolver = resolver
        let name = "GuestSurface-\(UUID().uuidString)"
        let domain = "guest-surface-test"
        try await resolver.addCellResolve(name: name, cellScope: .identityUnique,
            identityDomain: domain, type: GuestSurface.self)
        let result = try await readPersonalSurface(publisher: name, requester: guest,
            serverOwner: house, peerVault: vault)
        XCTAssertEqual(result.response.payload, .string("private-surface-\(guest.uuid)"))
        let challenges = try result.proofs.map { command -> IdentitySigningChallenge in
            guard case let .signData(data) = command.payload else { throw IdentitySigningChallengeError.invalidPayload }
            return try IdentitySigningChallenge.validateSigningData(data, for: guest)
        }
        XCTAssertFalse(challenges.isEmpty)
        let creation = try XCTUnwrap(challenges.first)
        XCTAssertEqual(creation.domain, domain)
        XCTAssertEqual(creation.resource, name)
        XCTAssertEqual(creation.action, "checkIdentityOrigin")
        XCTAssertEqual(creation.audience, "GeneralCell")
        XCTAssertEqual(Set(challenges.map(\.nonce)).count, challenges.count,
            "Every proof must use a fresh resolver/cell nonce")
    }

    // Purpose: neither a real house key nor the guest's copied public identity
    // may read the guest's private data. Possessing the route is not authority.
    func testHouseCannotReadGuestDataOrUseCopiedGuestDescriptorOverBridge() async throws {
        let vault = EphemeralIdentityVault()
        CellBase.defaultIdentityVault = vault
        let guest = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let house = await vault.identity(for: "house", makeNewIfNotFound: true)!
        let resolver = CellResolver.sharedInstance
        CellBase.defaultCellResolver = resolver
        let name = "GuestIsolation-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .identityUnique,
            identityDomain: "guest-isolation-test", type: GuestSurface.self)
        let cell = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: guest)
        let allowedGuest = try await readPersonalSurface(publisher: cell.uuid, requester: guest,
            serverOwner: house, peerVault: vault)
        XCTAssertEqual(allowedGuest.response.payload, .string("private-surface-\(guest.uuid)"),
            "The exact UUID route must work for the guest before checking house rejection")
        let deniedHouse = try await readPersonalSurface(publisher: cell.uuid, requester: house,
            serverOwner: house, peerVault: vault)
        XCTAssertNotEqual(deniedHouse.response.payload, .string("private-surface-\(guest.uuid)"))
        guard case let .string(houseFailure) = deniedHouse.response.payload else { return XCTFail("Expected explicit denial") }
        XCTAssertTrue(houseFailure.contains("ownerAuthorityUnavailable"), houseFailure)
        let copied = try await readPersonalSurface(publisher: name, requester: guest.publicIdentitySnapshot(),
            serverOwner: house, peerVault: nil)
        XCTAssertGreaterThan(copied.proofs.count, 0, "The server's local guest key must not answer for the peer")
        guard case let .string(copyFailure) = copied.response.payload else { return XCTFail("Expected explicit denial") }
        XCTAssertTrue(copyFailure.contains("ownerAuthorityUnavailable"), copyFailure)
        let freshName = "UnprovenGuest-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: freshName, cellScope: .identityUnique,
            identityDomain: "guest-isolation-test", type: GuestSurface.self)
        let freshDenied = try await readPersonalSurface(publisher: freshName, requester: guest.publicIdentitySnapshot(),
            serverOwner: house, peerVault: nil)
        XCTAssertGreaterThan(freshDenied.proofs.count, 0)
        guard case let .string(freshFailure) = freshDenied.response.payload else { return XCTFail("Expected explicit denial") }
        XCTAssertTrue(freshFailure.contains("ownerAuthorityUnavailable"), freshFailure)
        let mappings = await resolver.identityNamedCells(requester: house)
        XCTAssertNil(mappings[guest.uuid]?[freshName], "No private instance is registered without a proof")
        let stillOwned = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: guest)
        XCTAssertEqual(stillOwned.uuid, cell.uuid)
    }

    /// A host that explicitly knows the private surface's UUID can pin both
    /// creation and cell scopes. This fixture does not grant discovery authority.
    private final class PinnedGuestSurface: GeneralCell {
        static let identifier = UUID().uuidString
        static let domain = "paired-guest-surface"
        required init(owner: Identity) async {
            await super.init(owner: owner)
            uuid = Self.identifier
            identityDomain = Self.domain
            await addInterceptForGet(requester: owner, key: "guest.configuration") { _, _ in
                .string("paired-private-surface-\(owner.uuid)")
            }
        }
        required init(from decoder: Decoder) throws { try super.init(from: decoder) }
    }

    func testPairedBridgesCreateFreshGuestSurfaceOnlyWithinExplicitProofScopes() async throws {
        let clientVault = EphemeralIdentityVault()
        let guest = await clientVault.identity(for: "guest", makeNewIfNotFound: true)!
        let serverVault = EphemeralIdentityVault()
        CellBase.defaultIdentityVault = serverVault
        let house = await serverVault.identity(for: "house", makeNewIfNotFound: true)!
        let resolver = CellResolver.sharedInstance
        CellBase.defaultCellResolver = resolver
        let name = "PairedGuest-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .identityUnique,
            identityDomain: PinnedGuestSurface.domain, type: PinnedGuestSurface.self)
        for allowCreation in [false, true] {
            let outgoing = PairedTransport()
            let incoming = PairedTransport()
            let client = try await BridgeBase(BridgeBase.Config(owner: guest, transport: outgoing,
                connection: .outbound, identityProofScopes: [
                    .init(domain: PinnedGuestSurface.domain, resource: allowCreation ? name : "another-surface"),
                    .init(domain: PinnedGuestSurface.domain, resource: PinnedGuestSurface.identifier)
                ]))
            let server = try await BridgeBase(BridgeBase.Config(owner: house, transport: incoming,
                connection: .inbound(publisherUuid: name)))
            try await client.setTransport(outgoing, connection: .outbound)
            try await server.setTransport(incoming, connection: .inbound(publisherUuid: name))
            outgoing.peer = server
            incoming.peer = client
            for endpoint in [client, server] {
                try await endpoint.consumeCommand(command: BridgeCommand(cmd: "ready", payload: nil, cid: 0))
            }
            await client.sendCommand(command: .get, identity: guest, payload: .string("guest.configuration"))
            let reply = try XCTUnwrap(incoming.snapshot().last { $0.command == .response })
            if !allowCreation {
                guard case let .string(reason) = reply.payload else { return XCTFail("Unpinned creation must be denied") }
                XCTAssertTrue(reason.contains("ownerAuthorityUnavailable"), reason)
                let mappings = await resolver.identityNamedCells(requester: house)
                XCTAssertNil(mappings[guest.uuid]?[name])
                continue
            }
            XCTAssertEqual(reply.payload, .string("paired-private-surface-\(guest.uuid)"))
            let proofs = incoming.snapshot().filter { $0.command == .sign }
            let challenges = try proofs.map { command -> IdentitySigningChallenge in
                guard case let .signData(data) = command.payload else { throw IdentitySigningChallengeError.invalidPayload }
                return try IdentitySigningChallenge.validateSigningData(data, for: guest)
            }
            XCTAssertEqual(Set(challenges.map(\.resource)), Set([name, PinnedGuestSurface.identifier]))
            XCTAssertTrue(challenges.allSatisfy { $0.domain == PinnedGuestSurface.domain })
            let signed = outgoing.snapshot().filter { if case .signature = $0.payload { return true }; return false }
            XCTAssertEqual(signed.count, proofs.count)
            XCTAssertGreaterThan(signed.count, 1, "Both resolver and Cell proofs must be signed by the real client")
            let firstProof = try XCTUnwrap(proofs.first)
            try await client.consumeCommand(command: BridgeCommand(cmd: "sign", identity: guest.publicIdentitySnapshot(),
                payload: firstProof.payload, cid: 980))
            let replay = try XCTUnwrap(outgoing.snapshot().last)
            guard case let .string(reason) = replay.payload else { return XCTFail("Completed operation must not retain signing authority") }
            XCTAssertTrue(reason.contains("signing denied"), reason)
        }
    }

    private func readPersonalSurface(publisher: String, requester: Identity, serverOwner: Identity,
                                    peerVault: IdentityVaultProtocol?) async throws
        -> (response: BridgeCommand, proofs: [BridgeCommand]) {
        let transport = PeerTransport(peerVault: peerVault)
        let server = try await BridgeBase(BridgeBase.Config(owner: serverOwner, transport: transport,
            connection: .inbound(publisherUuid: publisher)))
        try await server.setTransport(transport, connection: .inbound(publisherUuid: publisher))
        transport.setDelegate(server)
        try await server.consumeCommand(command: BridgeCommand(cmd: "ready", payload: nil, cid: 0))
        try await server.consumeCommand(command: BridgeCommand(cmd: "get", identity: requester,
            payload: .string("guest.configuration"), cid: 801))
        return (try XCTUnwrap(transport.snapshot().last { $0.command == .response && $0.cid == 801 }),
                transport.snapshot().filter { $0.command == .sign })
    }

    func testCopiedPublicOwnerCannotUseServerVaultForProtectedRead() async throws {
        let result = try await readThroughBridge(peerControlsOwnerKey: false)
        XCTAssertNotEqual(result.response.payload, .string("protected-value"))
        XCTAssertGreaterThan(result.proofRequests, 0, "The peer must prove control; the server must not prove it for the peer")
    }

    func testSetResponseReflectsActualWriteSuccessAndFailure() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "set-owner", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        await cell.addInterceptForSet(requester: owner, key: "writable") { _, value, _ in value }
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "SetTarget", emitCell: cell, scope: .template, identity: owner)
        let transport = PeerTransport(peerVault: vault)
        let server = try await BridgeBase(BridgeBase.Config(owner: owner, transport: transport,
            connection: .inbound(publisherUuid: "SetTarget"), inboundPublisherLookupIdentity: owner))
        try await server.setTransport(transport, connection: .inbound(publisherUuid: "SetTarget"))
        transport.setDelegate(server)
        try await server.consumeCommand(command: BridgeCommand(cmd: "ready", payload: nil, cid: 0))
        for (index, key) in ["writable", "unknownKey", ""].enumerated() {
            let cid = 800 + index
            try await server.consumeCommand(command: BridgeCommand(cmd: "set", identity: owner,
                payload: .keyValue(.init(key: key, value: .string("synthetic-write"))), cid: cid))
            let response = try XCTUnwrap(transport.snapshot().last { $0.command == .response && $0.cid == cid })
            guard case let .setValueResponse(result) = response.payload else { return XCTFail("Missing typed set response") }
            XCTAssertEqual(result.state, index == 0 ? .ok : .error)
            XCTAssertEqual(result.value, index == 0 ? .string("synthetic-write") : nil)
        }
    }

    func testPeerThatControlsOwnerKeyCanStillReadThroughBridge() async throws {
        let result = try await readThroughBridge(peerControlsOwnerKey: true)
        XCTAssertEqual(result.response.payload, .string("protected-value"))
        XCTAssertGreaterThan(result.proofRequests, 0)
    }

    func testTwoSerializedBridgeEndpointsReadWithClientProofThenCloseSigningAuthority() async throws {
        let clientVault = MockIdentityVault()
        let owner = await clientVault.identity(for: "client-owner", makeNewIfNotFound: true)!
        let serverVault = MockIdentityVault()
        CellBase.defaultIdentityVault = serverVault
        let serverOwner = await serverVault.identity(for: "server-route", makeNewIfNotFound: true)!
        let publisher = await GeneralCell(owner: owner.publicIdentitySnapshot())
        await publisher.addInterceptForGet(requester: owner, key: "secret") { _, _ in .string("protected-value") }
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: publisher, scope: .template, identity: serverOwner)
        let clientTransport = PairedTransport()
        let serverTransport = PairedTransport()
        let client = try await BridgeBase(BridgeBase.Config(
            owner: owner, transport: clientTransport, connection: .outbound,
            identityProofScopes: [.init(domain: publisher.identityDomain, resource: publisher.uuid)]
        ))
        let server = try await BridgeBase(BridgeBase.Config(
            owner: serverOwner, transport: serverTransport, connection: .inbound(publisherUuid: "Protected"),
            inboundPublisherLookupIdentity: serverOwner
        ))
        try await client.setTransport(clientTransport, connection: .outbound)
        try await server.setTransport(serverTransport, connection: .inbound(publisherUuid: "Protected"))
        clientTransport.peer = server
        serverTransport.peer = client
        for endpoint in [client, server] {
            try await endpoint.consumeCommand(command: BridgeCommand(cmd: "ready", payload: nil, cid: 0))
        }
        await client.sendCommand(command: .get, identity: owner, payload: .string("secret"))
        let reply = try XCTUnwrap(serverTransport.snapshot().last(where: { $0.command == .response }))
        XCTAssertEqual(reply.payload, .string("protected-value"))
        XCTAssertTrue(clientTransport.snapshot().contains { if case .signature = $0.payload { return true }; return false })

        let unsolicitedProof = try IdentitySigningChallenge.signingData(
            for: owner, trustedIdentity: owner, domain: publisher.identityDomain, resource: publisher.uuid,
            action: "checkIdentityOrigin", audience: "GeneralCell", nonce: Data(repeating: 3, count: 32)
        )
        try await client.consumeCommand(command: BridgeCommand(
            cmd: "sign", identity: owner.publicIdentitySnapshot(), payload: .signData(unsolicitedProof), cid: 700
        ))
        let denial = try XCTUnwrap(clientTransport.snapshot().last)
        guard case let .string(reason) = denial.payload else { return XCTFail("Completed read must not leave signing authority open") }
        XCTAssertTrue(reason.contains("signing denied"))
    }

    func testRevokingOneBridgeFeedPreservesTheOtherBridgeFeed() async throws {
        let previousSink = CellBase.securityEventSink
        let securityEvents = InMemoryCellSecurityEventSink()
        CellBase.securityEventSink = securityEvents
        defer { CellBase.securityEventSink = previousSink }
        let serverVault = EphemeralIdentityVault()
        CellBase.defaultIdentityVault = serverVault
        var owner = Identity(UUID().uuidString, displayName: "server-owner", identityVault: serverVault)
        await serverVault.addIdentity(identity: &owner, for: "server-owner")
        let clientsVault = EphemeralIdentityVault()
        var first = Identity(UUID().uuidString, displayName: "first-client", identityVault: clientsVault)
        var second = Identity(UUID().uuidString, displayName: "second-client", identityVault: clientsVault)
        await clientsVault.addIdentity(identity: &first, for: "first-client")
        await clientsVault.addIdentity(identity: &second, for: "second-client")
        let cell = await GeneralCell(owner: owner)
        cell.agreementTemplate.addGrant("r---", for: "feed")
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "ProtectedFeed", emitCell: cell, scope: .template, identity: owner)
        let before = expectation(description: "both bridge clients receive authorized event")
        before.expectedFulfillmentCount = 2
        let after = expectation(description: "remaining bridge client receives new event")
        let valuesLock = NSLock()
        var firstValues: [String] = []
        var bridges: [(client: BridgeBase, server: BridgeBase)] = []
        var subscriptions: [AnyCancellable] = []
        for identity in [first, second] {
            let agreement = Agreement(owner: owner)
            agreement.addGrant("r---", for: "feed")
            let admission = await cell.addAgreement(agreement, for: identity, authorizedBy: owner)
            XCTAssertEqual(admission, .signed)
            let localDecision = await cell.authorizationDecision(requestedAccess: "r---", at: "feed", for: identity)
            XCTAssertTrue(localDecision.allowed, "Fresh local contract: \(localDecision.reasonCode)")
            let outgoing = PairedTransport()
            let incoming = PairedTransport()
            let client = try await BridgeBase(BridgeBase.Config(
                owner: identity, transport: outgoing, connection: .outbound,
                identityProofScopes: [.init(domain: cell.identityDomain, resource: cell.uuid)]
            ))
            let server = try await BridgeBase(BridgeBase.Config(
                owner: owner, transport: incoming, connection: .inbound(publisherUuid: "ProtectedFeed"),
                inboundPublisherLookupIdentity: owner
            ))
            try await client.setTransport(outgoing, connection: .outbound)
            try await server.setTransport(incoming, connection: .inbound(publisherUuid: "ProtectedFeed"))
            outgoing.peer = server
            incoming.peer = client
            for endpoint in [client, server] {
                try await endpoint.consumeCommand(command: BridgeCommand(cmd: "ready", payload: nil, cid: 0))
            }
            let stream: AnyPublisher<FlowElement, Error>
            do { stream = try await client.flow(requester: identity) }
            catch {
                let rejections = outgoing.snapshot().compactMap { command -> String? in
                    if case let .string(reason) = command.payload { return reason }
                    return nil
                }
                let incomingCommands = incoming.snapshot().map { $0.cmd }
                let reasons = await securityEvents.snapshot().map(\.reasonCode)
                XCTFail("Valid bridge feed was denied; peer replies: \(rejections), incoming commands: \(incomingCommands), reasons: \(reasons)")
                throw error
            }
            subscriptions.append(stream.sink(receiveCompletion: { _ in }, receiveValue: { element in
                if identity === first { valuesLock.withLock { firstValues.append(element.title) } }
                if element.title == "before" { before.fulfill() }
                if element.title == "after", identity === second { after.fulfill() }
            }))
            bridges.append((client, server))
        }
        let emitValue = await cell.makeCellOwnedFlowEmitterForRuntimeBinding(requester: owner)
        let emit = try XCTUnwrap(emitValue)
        emit(FlowElement(title: "before", content: .string("before"), properties: nil))
        await fulfillment(of: [before], timeout: 3)
        await cell.removeMember(member: first, requester: owner)
        XCTAssertFalse(bridges[0].server.feedActive)
        emit(FlowElement(title: "after", content: .string("after"), properties: nil))
        await fulfillment(of: [after], timeout: 3)
        XCTAssertEqual(valuesLock.withLock { firstValues }, ["before"])
        subscriptions.forEach { $0.cancel() }
    }

    private func readThroughBridge(peerControlsOwnerKey: Bool) async throws -> (response: BridgeCommand, proofRequests: Int) {
        let localVault = MockIdentityVault()
        CellBase.defaultIdentityVault = localVault
        let owner = await localVault.identity(for: "protected-owner", makeNewIfNotFound: true)!
        let publisher = await GeneralCell(owner: owner)
        await publisher.addInterceptForGet(requester: owner, key: "secret") { _, _ in .string("protected-value") }
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: publisher, scope: .template, identity: owner)
        let transport = PeerTransport(peerVault: peerControlsOwnerKey ? localVault : nil)
        let bridge = try await BridgeBase(BridgeBase.Config(
            owner: owner, transport: transport, connection: .inbound(publisherUuid: "Protected"),
            inboundPublisherLookupIdentity: owner
        ))
        try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Protected"))
        try await bridge.consumeCommand(command: BridgeCommand(cmd: Command.ready.rawValue, payload: nil, cid: 0))

        let command = try JSONDecoder().decode(BridgeCommand.self, from: JSONEncoder().encode(BridgeCommand(
            cmd: Command.get.rawValue, identity: owner.publicIdentitySnapshot(), payload: .string("secret"), cid: 17
        )))
        command.identity?.identityVault = localVault
        try await bridge.consumeCommand(command: command)

        let commands = transport.snapshot()
        let response = try XCTUnwrap(commands.last(where: { $0.command == .response && $0.cid == 17 }))
        XCTAssertTrue(owner.identityVault is MockIdentityVault, "Sanitizing the wire identity must not mutate the local owner")
        return (response, commands.filter { $0.command == .sign }.count)
    }
}
