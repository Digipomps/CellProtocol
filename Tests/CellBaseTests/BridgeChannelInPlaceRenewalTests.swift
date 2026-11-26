// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@_spi(HAVENRuntime) @testable import CellBase

/// HD-0352 WP8: the 300 s lease is renewed on the same physical connection.
/// Kjetil 19.11: one websocket from the Mac, owned by the agent, and «forny»
/// (renew on the same connection), so streams no longer fall every five minutes.
final class BridgeChannelInPlaceRenewalTests: XCTestCase {
    typealias A = BridgeChannelAuthentication
    private var previousResolver: CellResolverProtocol?
    override func setUp() { previousResolver = CellBase.defaultCellResolver }
    override func tearDown() { CellBase.defaultCellResolver = previousResolver }

    private func endpoint() throws -> A.Endpoint {
        try .init(url: XCTUnwrap(URL(string: "wss://bridge.example/bridgehead/Protected/client")), domain: "bridge")
    }
    private func identity(_ context: String = "client") async -> Identity {
        await MockIdentityVault().identity(for: context, makeNewIfNotFound: true)!
    }

    private func connected(owner: Identity, limits: BridgeChannelLimits = BridgeChannelLimits(),
                           policy: @escaping @Sendable (A.PublicIdentity) async throws -> Void = { _ in }) async throws ->
        (client: BridgeBase, clientGate: BridgeChannelTransport, serverGate: BridgeChannelTransport,
         clientWire: RenewalWire, serverWire: RenewalWire) {
        let serverOwner = await identity("server")
        let publisher = await GeneralCell(owner: owner.publicIdentitySnapshot())
        await publisher.addInterceptForGet(requester: owner, key: "secret") { _, _ in .string("protected-value") }
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "Protected", emitCell: publisher, scope: .template, identity: serverOwner)
        let clientWire = RenewalWire(), serverWire = RenewalWire(), endpoint = try endpoint()
        clientWire.peer = serverWire; serverWire.peer = clientWire
        let server = try BridgeChannelTransport(underlying: serverWire, endpoint: endpoint, limits: limits, source: "one",
                                                recheckPolicy: policy) { transport, _ in
            let bridge = try await BridgeBase(.init(owner: serverOwner, transport: transport,
                connection: .inbound(publisherUuid: "Protected"), inboundPublisherLookupIdentity: serverOwner))
            try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Protected"))
            return bridge
        }
        let clientGate = try BridgeChannelTransport(underlying: clientWire, endpoint: endpoint)
        let client = try await BridgeBase(.init(owner: owner, transport: clientGate, connection: .outbound,
            identityProofScopes: [.init(domain: publisher.identityDomain, resource: publisher.uuid)]))
        try await client.setTransport(clientGate, connection: .outbound)
        try await clientGate.setup(URL(string: endpoint.audience)!, identity: owner)
        return (client, clientGate, server, clientWire, serverWire)
    }

    func testRenewalKeepsTheConnectionAndMovesTheExpiryOnBothSides() async throws {
        let owner = await identity()
        let pair = try await connected(owner: owner)
        let serverSession = pair.serverGate.session, clientSession = pair.clientGate.session
        let serverBefore = try XCTUnwrap(serverSession.expiresAt), clientBefore = try XCTUnwrap(clientSession.expiresAt)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await pair.clientGate.renewInPlace(identity: owner)
        XCTAssertGreaterThan(try XCTUnwrap(serverSession.expiresAt), serverBefore)
        XCTAssertGreaterThan(try XCTUnwrap(clientSession.expiresAt), clientBefore)
        XCTAssertTrue(pair.serverGate.session === serverSession, "same server lease object")
        XCTAssertEqual(serverSession.state, .authenticated)
        XCTAssertEqual(clientSession.state, .authenticated)
        XCTAssertFalse(pair.serverWire.isClosed); XCTAssertFalse(pair.clientWire.isClosed)
        XCTAssertEqual(pair.clientWire.snapshot.map(\.cmd).filter { $0.hasPrefix("channelAuth") },
                       ["channelAuthHello", "channelAuthProof", "channelAuthRenewHello", "channelAuthRenewProof"])
        // The connection still carries authenticated work after the renewal.
        await pair.client.sendCommand(command: .get, identity: owner, payload: .string("secret"))
        XCTAssertTrue(pair.serverWire.snapshot.contains { $0.command == .response && $0.payload == .string("protected-value") })
        await pair.clientGate.close(); await pair.serverGate.close()
    }

    func testRenewalTwiceInARowWorksAndEachIsAFreshProof() async throws {
        let owner = await identity()
        let pair = try await connected(owner: owner)
        try await pair.clientGate.renewInPlace(identity: owner)
        try await Task.sleep(nanoseconds: 5_000_000)
        try await pair.clientGate.renewInPlace(identity: owner)
        let proofs = pair.clientWire.snapshot.filter { $0.cmd == "channelAuthRenewProof" }
        XCTAssertEqual(proofs.count, 2)
        XCTAssertNotEqual(proofs[0].payload, proofs[1].payload, "a new transcript and signature each time")
        XCTAssertEqual(pair.serverGate.session.state, .authenticated)
        await pair.clientGate.close(); await pair.serverGate.close()
    }

    func testRenewalWithAnotherIdentityIsRefusedAndTheLeaseIsUnchanged() async throws {
        let owner = await identity(), other = await identity("other")
        let pair = try await connected(owner: owner)
        let before = pair.serverGate.session.expiresAt
        do { try await pair.clientGate.renewInPlace(identity: other); XCTFail("another identity must not renew") }
        catch { XCTAssertEqual(error as? A.Failure, .identityMismatch) }
        XCTAssertEqual(pair.serverGate.session.expiresAt, before)
        XCTAssertFalse(pair.clientWire.snapshot.contains { $0.cmd == "channelAuthRenewHello" }, "refused before any wire traffic")
        await pair.clientGate.close(); await pair.serverGate.close()
    }

    /// A key revoked after the connection opened stops at the next renewal.
    func testAKeyRevokedSinceOpeningClosesTheConnectionAtRenewal() async throws {
        let owner = await identity()
        let revoked = RenewalFlag()
        let pair = try await connected(owner: owner, policy: { _ in
            if revoked.value { throw A.Failure.revoked }
        })
        revoked.set()
        do { try await pair.clientGate.renewInPlace(identity: owner); XCTFail("revoked key must not renew") } catch {}
        XCTAssertNotEqual(pair.serverGate.session.state, .authenticated)
        XCTAssertTrue(pair.serverWire.isClosed)
        await pair.clientGate.close()
    }

    /// Renewal is charged to the same per-key handshake budget as a new
    /// connection: renewing can never sign more often than reconnecting.
    func testRenewalIsChargedToTheKeyHandshakeBudget() async throws {
        let owner = await identity()
        var configuration = BridgeChannelLimits.Configuration()
        configuration.maximumVerifiedHandshakesPerKeyPerMinute = 1
        let pair = try await connected(owner: owner, limits: BridgeChannelLimits(configuration: configuration))
        do { try await pair.clientGate.renewInPlace(identity: owner); XCTFail("budget of one is spent by the opening") } catch {}
        XCTAssertNotEqual(pair.serverGate.session.state, .authenticated)
        await pair.clientGate.close(); await pair.serverGate.close()
    }

    /// Domain separation: a renewal transcript has its own direction and the
    /// live generation, so it can never open a new connection, and an opening
    /// transcript is not accepted as a renewal.
    func testRenewalAndOpeningProofsCannotStandInForEachOther() async throws {
        let owner = await identity()
        // An operation for a fresh opening refuses to sign a renewal transcript.
        let first = try await connected(owner: owner)
        let opening = try BridgeChannelClientOperation(owner: owner, endpoint: try endpoint())
        let forOpening = try first.serverGate.session.issueRenewalChallenge(opening.hello)
        XCTAssertEqual(forOpening.transcript.direction, A.renewalDirection)
        XCTAssertEqual(forOpening.transcript.generation, first.serverGate.session.generation)
        do { _ = try await opening.sign(forOpening); XCTFail("an opening operation must not sign a renewal") } catch {}
        await first.clientGate.close(); await first.serverGate.close()

        // A renewal operation refuses a transcript for another generation.
        let second = try await connected(owner: owner)
        let wrong = try BridgeChannelClientOperation(owner: owner, endpoint: try endpoint(), renewingGeneration: UUID().uuidString)
        let forWrong = try second.serverGate.session.issueRenewalChallenge(wrong.hello)
        do { _ = try await wrong.sign(forWrong); XCTFail("wrong generation must not be signed") } catch {}
        await second.clientGate.close(); await second.serverGate.close()

        // A valid renewal proof presented to a fresh connection is refused,
        // and only one renewal can be outstanding.
        let third = try await connected(owner: owner)
        let server = third.serverGate.session
        let right = try BridgeChannelClientOperation(owner: owner, endpoint: try endpoint(), renewingGeneration: server.generation)
        let renewal = try server.issueRenewalChallenge(right.hello)
        let proof = try await right.sign(renewal)
        let fresh = try BridgeChannelSession(endpoint: try endpoint())
        _ = try fresh.issueChallenge(A.Hello(identity: try A.PublicIdentity(owner)))
        do { try fresh.reserveOpen(proof); XCTFail("renewal proof must not open a connection") } catch {}
        do { _ = try server.issueRenewalChallenge(A.Hello(identity: try A.PublicIdentity(owner))); XCTFail("one renewal at a time") }
        catch { XCTAssertEqual(error as? A.Failure, .unexpectedMessage) }
        // An opening transcript is not a renewal: the live lease refuses an opening hello.
        do { _ = try server.issueChallenge(A.Hello(identity: try A.PublicIdentity(owner))); XCTFail("no second opening on a live lease") } catch {}
        await third.clientGate.close(); await third.serverGate.close()
    }

    func testRenewalIsOffByDefaultForClients() {
        XCTAssertFalse(A.inPlaceRenewalEnabled, "a server without renewal would close every lease early")
    }
}

private final class RenewalFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

final class RenewalWire: BridgeTransportProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var delegate: BridgeDelegateProtocol?
    weak var peer: RenewalWire?
    private var commands: [BridgeCommand] = []
    private var closed = false
    var snapshot: [BridgeCommand] { lock.withLock { commands } }
    var isClosed: Bool { lock.withLock { closed } }
    static func new() -> BridgeTransportProtocol { RenewalWire() }
    func setDelegate(_ delegate: BridgeDelegateProtocol) { lock.withLock { self.delegate = delegate } }
    func setup(_ endpointURL: URL, identity: Identity) async throws {}
    func sendData(_ data: Data) async throws {
        guard !isClosed else { throw BridgeChannelAuthentication.Failure.closed }
        let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
        lock.withLock { commands.append(command) }
        guard let peer, let destination = peer.lock.withLock({ peer.delegate }) else { throw BridgeChannelAuthentication.Failure.unavailable }
        try destination.validateInboundPayload(data)
        if command.command == .response { try await destination.consumeResponse(command: command) }
        else { try await destination.consumeCommand(command: command) }
    }
    func close() async { lock.withLock { closed = true } }
    func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
}
