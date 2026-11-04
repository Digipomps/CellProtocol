// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
#if canImport(CellVapor)
import XCTest
import Vapor
@_spi(Testing) @testable import CellBase
import CellVapor

final class ResolverPinnedProofScopeTests: XCTestCase {
    func testPinnedScopesResolveDescriptionAndGetWithFreshIdentity() async throws {
        try await exercise(.correct)
    }

    func testWrongDomainIsDenied() async throws {
        try await exercise(.wrongDomain)
    }

    func testWrongResourceIsDenied() async throws {
        try await exercise(.wrongResource)
    }

    func testUnpinnedLookupCannotReusePinnedBridge() async throws {
        try await exercise(.unpinnedAfterPinned)
    }

    func testNamePinDoesNotAuthorizeCellUUID() async throws {
        try await exercise(.nameOnly)
    }

    func testEmptyPinsDenyEveryScope() async throws {
        try await exercise(.empty)
    }

    func testScopesCannotBeAppliedToLocalEndpoint() async throws {
        let resolver = CellResolver.makeIsolatedForTesting()
        let vault = EphemeralIdentityVault()
        let owner = await vault.identity(for: "local", makeNewIfNotFound: true)!
        do {
            _ = try await resolver.cellAtEndpoint(endpoint: "cell:///Local", requester: owner,
                identityProofScopes: [.init(domain: "local", resource: "Local")])
            XCTFail("Proof pins are only accepted for an explicit WebSocket endpoint")
        } catch CellResolverError.invalidRemoteCellReference { }
    }

    private enum Scenario { case correct, wrongDomain, wrongResource, unpinnedAfterPinned, nameOnly, empty }

    private func exercise(_ scenario: Scenario) async throws {
        let previousResolver = CellBase.defaultCellResolver
        let previousVault = CellBase.defaultIdentityVault
        let previousPolicy = CellBase.webSocketSecurityPolicy
        let previousDebug = CellBase.debugValidateAccessForEverything
        defer {
            CellBase.defaultCellResolver = previousResolver
            CellBase.defaultIdentityVault = previousVault
            CellBase.webSocketSecurityPolicy = previousPolicy
            CellBase.debugValidateAccessForEverything = previousDebug
        }
        CellBase.debugValidateAccessForEverything = false
        CellBase.webSocketSecurityPolicy = .developmentOnlyInsecureAllowed
        let serverVault = EphemeralIdentityVault()
        let house = await serverVault.identity(for: "house", makeNewIfNotFound: true)!
        let clientVault = EphemeralIdentityVault()
        let guest = await clientVault.identity(for: "fresh-guest", makeNewIfNotFound: true)!
        CellBase.defaultIdentityVault = serverVault
        let serverResolver = CellResolver.makeIsolatedForTesting()
        CellBase.defaultCellResolver = serverResolver
        let name = "PinnedSurface-" + UUID().uuidString
        try await serverResolver.addCellResolve(name: name, cellScope: .identityUnique,
            identityDomain: ResolverPinnedSurface.domain, type: ResolverPinnedSurface.self)
        let clientResolver = CellResolver.makeIsolatedForTesting()
        try await clientResolver.registerTransport(VaporBridgeTransport.self, for: "ws")
        let app = try await Application.make(.testing)
        let state = ResolverPinnedSocketState()
        app.webSocket("proof", ":bridgeID") { request, socket in
            do {
                let endpoint = try BridgeChannelAuthentication.Endpoint(
                    url: URL(string: state.baseURL + request.url.path)!, domain: "bridge",
                    allowInsecureLoopback: true)
                let gate = try BridgeChannelTransport(underlying: VaporBridgeTransport(webSocket: socket),
                    endpoint: endpoint, limits: BridgeChannelLimits(), source: "127.0.0.1") { transport, _ in
                    let bridge = try await BridgeBase(.init(owner: house, transport: transport,
                        connection: .inbound(publisherUuid: name)))
                    try await bridge.setTransport(transport, connection: .inbound(publisherUuid: name))
                    return bridge
                }
                state.add(gate)
            } catch { socket.close(code: .policyViolation, promise: nil) }
        }
        do {
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
            state.baseURL = "ws://127.0.0.1:\(port)"
            let endpoint = state.baseURL + "/proof"
            var scopes: [BridgeIdentityProofScope] = [
                .init(domain: scenario == .wrongDomain ? "wrong-domain" : ResolverPinnedSurface.domain,
                      resource: scenario == .wrongResource ? "another-resource" : name),
                .init(domain: ResolverPinnedSurface.domain, resource: ResolverPinnedSurface.identifier)
            ]
            if scenario == .nameOnly { scopes = [scopes[0]] }
            if scenario == .empty { scopes = [] }
            let bridge = try await clientResolver.cellAtEndpoint(endpoint: endpoint, requester: guest,
                identityProofScopes: scopes) as! BridgeBase
            state.addClient(bridge)
            let value = try await bridge.get(keypath: "secret", requester: guest)
            if scenario == .correct || scenario == .unpinnedAfterPinned {
                XCTAssertEqual(bridge.uuid, ResolverPinnedSurface.identifier, "Description must resolve with the first identity")
                XCTAssertEqual(value, .string("private-" + guest.uuid))
                // The same policy, regardless of list order/duplicates, can reuse its bridge.
                let cached = try await clientResolver.cellAtEndpoint(endpoint: endpoint, requester: guest,
                    identityProofScopes: Array(scopes.reversed()) + scopes)
                XCTAssertTrue((cached as AnyObject) === bridge)
                if scenario == .unpinnedAfterPinned {
                    let unpinned = try await clientResolver.cellAtEndpoint(endpoint: endpoint, requester: guest) as! BridgeBase
                    state.addClient(unpinned)
                    XCTAssertFalse(unpinned === bridge, "An ordinary lookup must not inherit host pins")
                    let denied = try await unpinned.get(keypath: "secret", requester: guest)
                    if case .string(let reason) = denied {
                        XCTAssertTrue(reason.hasPrefix("failure:"), reason)
                    } else { XCTFail("Expected missing-proof denial") }
                }
            } else {
                if case .string(let reason) = value {
                    XCTAssertTrue(reason.hasPrefix("failure:"), reason)
                } else { XCTFail("Wrong scope must fail") }
                if scenario != .nameOnly { XCTAssertNotEqual(bridge.uuid, ResolverPinnedSurface.identifier) }
            }
            await state.close(guest)
            await app.server.shutdown()
            try await app.asyncShutdown()
        } catch {
            await state.close(guest)
            await app.server.shutdown()
            try? await app.asyncShutdown()
            throw error
        }
    }
}

private final class ResolverPinnedSurface: GeneralCell {
    static let identifier = UUID().uuidString
    static let domain = "resolver-pinned-proof-tests"
    required init(owner: Identity) async {
        await super.init(owner: owner)
        uuid = Self.identifier
        identityDomain = Self.domain
        await addInterceptForGet(requester: owner, key: "secret") { _, _ in .string("private-" + owner.uuid) }
    }
    required init(from decoder: Decoder) throws { try super.init(from: decoder) }
}

private final class ResolverPinnedSocketState: @unchecked Sendable {
    private let lock = NSLock()
    private var base = ""
    private var gates: [BridgeChannelTransport] = []
    private var clients: [BridgeBase] = []
    var baseURL: String {
        get { lock.withLock { base } }
        set { lock.withLock { base = newValue } }
    }
    func add(_ gate: BridgeChannelTransport) { lock.withLock { gates.append(gate) } }
    func addClient(_ bridge: BridgeBase) { lock.withLock { clients.append(bridge) } }
    func close(_ owner: Identity) async {
        let snapshot = lock.withLock { (gates, clients) }
        for bridge in snapshot.1 { bridge.close(requester: owner) }
        for gate in snapshot.0 { await gate.close() }
    }
}
#endif
