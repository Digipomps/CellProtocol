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

    func testFeedPermitSurvivesSetCompletionAcrossCommandIDs() async throws {
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "local", makeNewIfNotFound: true)!
        for iteration in 0..<256 {
            let authority = BridgeIdentityProofAuthorization(owner: owner, scopes: [scope])
            let feedID = iteration * 2 + 2
            let setID = feedID + 1
            authority.begin(operation(owner, .feed, feedID), now: now, monotonic: 100)
            authority.begin(operation(owner, .set, setID), now: now, monotonic: 100)
            let permit = try XCTUnwrap(authority.permit(for: challenge(owner), identity: owner, now: now, monotonic: 100))
            XCTAssertEqual(permit.commandID, feedID)
            authority.complete(setID)
            XCTAssertTrue(authority.isCurrent(permit, now: now, monotonic: 100))
            authority.complete(feedID)
            XCTAssertFalse(authority.isCurrent(permit, now: now, monotonic: 100))
        }
    }

    func testSetPermitSelectsLatestDeadline() async throws {
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "local", makeNewIfNotFound: true)!
        let authority = BridgeIdentityProofAuthorization(owner: owner, scopes: [scope])
        for id in 1...32 {
            authority.begin(operation(owner, .set, id), now: now.addingTimeInterval(Double(id) / 100), monotonic: 100 + Double(id) / 100)
        }
        let permit = try XCTUnwrap(authority.permit(for: challenge(owner), identity: owner, now: now.addingTimeInterval(1), monotonic: 101))
        XCTAssertEqual(permit.commandID, 32)
        authority.complete(1)
        XCTAssertTrue(authority.isCurrent(permit, now: now.addingTimeInterval(1), monotonic: 101))
    }

    func testCompletedAndExpiredLeasesAreNeverSelected() async throws {
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "local", makeNewIfNotFound: true)!
        let authority = BridgeIdentityProofAuthorization(owner: owner, scopes: [scope])
        authority.begin(operation(owner, .feed, 1), now: now, monotonic: 100)
        authority.complete(1)
        authority.begin(operation(owner, .set, 2), now: now, monotonic: 100)
        authority.begin(operation(owner, .set, 3), now: now.addingTimeInterval(1), monotonic: 101)
        let permit = try XCTUnwrap(authority.permit(for: challenge(owner), identity: owner, now: now.addingTimeInterval(5), monotonic: 105))
        XCTAssertEqual(permit.commandID, 3)
        XCTAssertNil(authority.permit(for: challenge(owner), identity: owner, now: now.addingTimeInterval(6), monotonic: 106))
        XCTAssertFalse(authority.isCurrent(permit, now: now.addingTimeInterval(6), monotonic: 106))
    }

    func testEqualDeadlinesAndFeedsChooseLowestCommandIDAndResetInvalidates() async throws {
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "local", makeNewIfNotFound: true)!
        for kind in [Command.set, .feed] {
            let authority = BridgeIdentityProofAuthorization(owner: owner, scopes: [scope])
            for id in (1...32).reversed() {
                authority.begin(operation(owner, kind, id), now: now, monotonic: 100)
            }
            let permit = try XCTUnwrap(authority.permit(for: challenge(owner), identity: owner, now: now, monotonic: 100))
            XCTAssertEqual(permit.commandID, 1)
            authority.reset()
            authority.begin(operation(owner, kind, 1), now: now, monotonic: 100)
            XCTAssertFalse(authority.isCurrent(permit, now: now, monotonic: 100))
            XCTAssertNotNil(authority.permit(for: challenge(owner), identity: owner, now: now, monotonic: 100))
        }
    }

    private func operation(_ identity: Identity, _ kind: Command, _ id: Int) -> BridgeCommand {
        BridgeCommand(cmd: kind.rawValue, identity: identity, payload: nil, cid: id)
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
