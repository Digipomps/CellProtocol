// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import CellBase

final class BridgeConnectSigningContextTests: XCTestCase {
    func testLegacyDefaultDispatchAndHolderAttachmentNeverSerialize() async throws {
        let source = MockIdentityVault()
        let local = await source.identity(for: "legacy", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(local)
        let holder = BridgeConnectHolderCapability().holderIdentity(identity)
        let endpoint = try BridgeChannelAuthentication.Endpoint(url: XCTUnwrap(URL(string: "wss://bridge.example/connect")), domain: "bridge")
        let operation = try BridgeChannelClientOperation(owner: holder, endpoint: endpoint)
        let server = try BridgeChannelSession(endpoint: endpoint)
        let challenge = try server.issueChallenge(operation.hello)
        let proof = try await operation.sign(challenge)
        try server.reserveOpen(proof)
        let calls = await source.signedMessages.count
        XCTAssertEqual(calls, 1)
        let encoded = try JSONEncoder().encode(holder)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("bridgeConnect"))
        XCTAssertFalse(json.contains("Capability"))
        let decoded = try JSONDecoder().decode(Identity.self, from: encoded)
        XCTAssertTrue(decoded.referencesSameSigningIdentity(as: identity))
    }

    func testHolderAuthorityIsAbsentFromPublicSnapshotAndFreshTokenCannotSubstitute() async throws {
        let source = MockIdentityVault()
        let local = await source.identity(for: "bridge", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(local)
        let holder = BridgeConnectHolderCapability()
        let vault = ContextAdmissionVault(holder: holder, source: source)
        identity.identityVault = vault
        let authorized = holder.holderIdentity(identity)
        let endpoint = try BridgeChannelAuthentication.Endpoint(url: XCTUnwrap(URL(string: "wss://bridge.example/connect")), domain: "bridge")
        for principal in [identity, authorized.publicIdentitySnapshot(), BridgeConnectHolderCapability().holderIdentity(identity)] {
            principal.identityVault = vault
            let operation = try BridgeChannelClientOperation(owner: principal, endpoint: endpoint)
            let server = try BridgeChannelSession(endpoint: endpoint)
            let challenge = try server.issueChallenge(operation.hello)
            do { _ = try await operation.sign(challenge); XCTFail("Unapproved holder must fail") } catch {}
        }
        XCTAssertEqual(vault.calls, 0)
        let operation = try BridgeChannelClientOperation(owner: authorized, endpoint: endpoint)
        let server = try BridgeChannelSession(endpoint: endpoint)
        let challenge = try server.issueChallenge(operation.hello)
        let proof = try await operation.sign(challenge)
        try server.reserveOpen(proof)
        XCTAssertEqual(vault.calls, 1)
    }
}

private final class ContextAdmissionVault: IdentityVaultProtocol, @unchecked Sendable {
    let holder: BridgeConnectHolderCapability
    let source: IdentityVaultProtocol
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    init(holder: BridgeConnectHolderCapability, source: IdentityVaultProtocol) { self.holder = holder; self.source = source }
    func initialize() async -> IdentityVaultProtocol { self }
    func addIdentity(identity: inout Identity, for identityContext: String) async {}
    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? { nil }
    func identityExistInVault(_ identity: Identity) async -> Bool { await source.identityExistInVault(identity) }
    func saveIdentity(_ identity: Identity) async {}
    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data { throw IdentityVaultError.signingFailed }
    func signMessageForIdentity(messageData: Data, identity: Identity, bridgeConnectContext: BridgeConnectSigningContext) async throws -> Data {
        let challenge = try IdentitySigningChallenge.validateSigningData(messageData, for: identity)
        let endpoint = try BridgeChannelAuthentication.Endpoint(url: URL(string: challenge.audience)!, domain: challenge.domain)
        try bridgeConnectContext.validate(holder: holder, messageData: messageData, identity: identity, endpoint: endpoint)
        try bridgeConnectContext.consume(messageData: messageData, identity: identity)
        lock.withLock { count += 1 }
        return try await source.signMessageForIdentity(messageData: messageData, identity: identity)
    }
    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool { false }
    func randomBytes64() async -> Data? { nil }
    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) { throw IdentityVaultError.noKey }
}
