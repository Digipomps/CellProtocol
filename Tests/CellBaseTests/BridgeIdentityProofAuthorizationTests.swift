// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class BridgeIdentityProofAuthorizationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let scope = BridgeIdentityProofScope(domain: "expected-domain", resource: "expected-cell")

    func testActiveOperationRejectsWrongPrincipalDomainResourceActionAndAudience() async throws {
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "local", makeNewIfNotFound: true)!
        let other = await vault.identity(for: "other-local", makeNewIfNotFound: true)!
        let authorization = BridgeIdentityProofAuthorization(owner: owner, scopes: [scope])
        authorization.begin(command(owner), now: now)
        let expected = challenge(owner)
        XCTAssertNotNil(authorization.permit(for: expected, identity: owner, now: now))
        XCTAssertNil(authorization.permit(for: challenge(other), identity: other, now: now))
        for field in [\IdentitySigningChallenge.domain, \.resource, \.action, \.audience] {
            var wrong = expected
            wrong[keyPath: field] = "different"
            XCTAssertNil(authorization.permit(for: wrong, identity: owner, now: now))
        }
    }

    func testProofAuthorityEndsOnResponseTimeoutOrTransportReset() async throws {
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "local", makeNewIfNotFound: true)!
        let authorization = BridgeIdentityProofAuthorization(owner: owner, scopes: [scope])
        authorization.begin(command(owner), now: now)
        let proof = challenge(owner)
        let permit = try XCTUnwrap(authorization.permit(for: proof, identity: owner, now: now))
        authorization.complete(1)
        XCTAssertNil(authorization.permit(for: proof, identity: owner, now: now))
        XCTAssertFalse(authorization.isCurrent(permit, now: now))
        authorization.begin(command(owner), now: now)
        XCTAssertNil(authorization.permit(for: proof, identity: owner, now: now.addingTimeInterval(5)))
        authorization.begin(command(owner), now: now)
        authorization.reset()
        XCTAssertNil(authorization.permit(for: proof, identity: owner, now: now))
        XCTAssertFalse(authorization.isCurrent(permit, now: now))
    }

    func testRemoteDescriptorCannotCreateLocalProofAuthority() async throws {
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "local", makeNewIfNotFound: true)!
        let authorization = BridgeIdentityProofAuthorization(owner: owner, scopes: [scope])
        let remote = owner.publicIdentitySnapshot()
        authorization.begin(command(remote), now: now)
        XCTAssertNil(authorization.permit(for: challenge(owner), identity: owner, now: now))
        remote.identityVault = BridgeIdentityVault(cloudBridge: nil)
        authorization.begin(command(remote), now: now)
        XCTAssertNil(authorization.permit(for: challenge(owner), identity: owner, now: now))
    }

    func testDiscoveryCannotOverridePinnedScopeOrAuthorizeWithoutLocalOperation() async throws {
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "local", makeNewIfNotFound: true)!
        let authorization = BridgeIdentityProofAuthorization(owner: owner, scopes: [scope])
        authorization.discovered(domain: "hostile", resource: "other-cell")
        XCTAssertNil(authorization.permit(for: challenge(owner), identity: owner, now: now))
        authorization.begin(command(owner), now: now)
        XCTAssertNotNil(authorization.permit(for: challenge(owner), identity: owner, now: now))
        var wrong = challenge(owner)
        wrong.domain = "hostile"
        wrong.resource = "other-cell"
        XCTAssertNil(authorization.permit(for: wrong, identity: owner, now: now))
    }

    private func command(_ identity: Identity) -> BridgeCommand {
        BridgeCommand(cmd: Command.get.rawValue, identity: identity, payload: .string("value"), cid: 1)
    }

    private func challenge(_ identity: Identity) -> IdentitySigningChallenge {
        IdentitySigningChallenge(identityUUID: identity.uuid,
                                 publicKeyFingerprint: identity.signingPublicKeyFingerprint,
                                 domain: scope.domain, resource: scope.resource,
                                 action: "checkIdentityOrigin", audience: "GeneralCell",
                                 nonce: Data(repeating: 1, count: 32), issuedAt: now)
    }
}
