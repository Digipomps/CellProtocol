// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@_spi(HAVENRuntime) @testable import CellBase

/// Regression for the 2026-11-11 server crash (exit 139): eight parallel
/// `GET chat/api/state` for one account. Each request opens its own vault
/// object for the same account keys; the resolver rebinds the shared stored
/// owner to that request's vault (`bindStoredOwnerToRuntimeIdentity`) while
/// other requests sign challenges through the owner's vault. Before
/// `Identity` locked its vault binding, the concurrent writes released a vault
/// that another task was calling, which crashed in `randomBytes64`
/// (ThreadSanitizer reports the race deterministically with
/// `swift test --sanitize=thread`).
final class IdentityVaultBindingConcurrencyTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousDebug = false

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousDebug = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.debugValidateAccessForEverything = previousDebug
        super.tearDown()
    }

    func testParallelVaultRebindingAndUseOnOneIdentityIsSafe() async {
        let keys = BindingTestKeyHolder()
        let identity = await keys.makeIdentity(displayName: "shared-owner")
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<512 {
                group.addTask {
                    identity.identityVault = BindingTestRequestVault(keys: keys)
                    identity.homeVaultReference = nil
                    return await identity.identityVault?.randomBytes64()?.count == 64
                }
            }
            for await ok in group {
                XCTAssertTrue(ok)
            }
        }
    }

    func testParallelOwnerRebindingWithPerRequestVaultsKeepsOwnerProof() async throws {
        let keys = BindingTestKeyHolder()
        let owner = await keys.makeIdentity(displayName: "account-owner")
        CellBase.defaultIdentityVault = BindingTestRequestVault(keys: keys)
        let cell = await BindingProbeCell(owner: owner)

        let results = await withTaskGroup(of: (Bool, Bool).self) { group -> [(Bool, Bool)] in
            for _ in 0..<64 {
                group.addTask {
                    // A fresh vault and a fresh requester per request, as
                    // CellScaffold builds them for an authenticated web user.
                    let requester = await keys.requestIdentity(for: owner, vault: BindingTestRequestVault(keys: keys))
                    let bound = await cell.bindStoredOwnerToRuntimeIdentity(requester)
                    let verified = await cell.verifiedRuntimeOwnerIdentity() != nil
                    return (bound, verified)
                }
            }
            var collected: [(Bool, Bool)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        XCTAssertEqual(results.count, 64)
        XCTAssertTrue(results.allSatisfy { $0.0 }, "every proven requester binds the stored owner")
        XCTAssertTrue(results.allSatisfy { $0.1 }, "the owner stays verifiable while other requests rebind it")
        let finalOwner = await cell.verifiedRuntimeOwnerIdentity()
        XCTAssertNotNil(finalOwner)
    }
}

private final class BindingProbeCell: GeneralCell {
    required init(owner: Identity) async { await super.init(owner: owner) }
    required init(from decoder: Decoder) throws { try super.init(from: decoder) }
}

/// The account's key material, shared by every per-request vault (like the
/// vault file every per-request `BrowserClientIdentityVault` loads).
private actor BindingTestKeyHolder {
    private var privateKeys: [String: Curve25519.Signing.PrivateKey] = [:]

    func makeIdentity(displayName: String) -> Identity {
        let privateKey = Curve25519.Signing.PrivateKey()
        let identity = Identity(UUID().uuidString, displayName: displayName, identityVault: nil)
        identity.publicSecureKey = Self.publicKey(privateKey)
        privateKeys[identity.uuid] = privateKey
        identity.identityVault = BindingTestRequestVault(keys: self)
        return identity
    }

    func requestIdentity(for owner: Identity, vault: BindingTestRequestVault) -> Identity {
        let identity = Identity(owner.uuid, displayName: owner.displayName, identityVault: vault)
        identity.publicSecureKey = owner.publicSecureKey
        return identity
    }

    func sign(_ data: Data, uuid: String) throws -> Data {
        guard let key = privateKeys[uuid] else { throw IdentityVaultError.noKey }
        return try key.signature(for: data)
    }

    private static func publicKey(_ privateKey: Curve25519.Signing.PrivateKey) -> SecureKey {
        SecureKey(
            date: Date(),
            privateKey: false,
            use: .signature,
            algorithm: .EdDSA,
            size: 32,
            curveType: .Curve25519,
            x: nil,
            y: nil,
            compressedKey: privateKey.publicKey.rawRepresentation
        )
    }
}

/// One vault object per request, released when the last reference drops.
private actor BindingTestRequestVault: IdentityVaultProtocol {
    let keys: BindingTestKeyHolder
    init(keys: BindingTestKeyHolder) { self.keys = keys }

    func initialize() async -> IdentityVaultProtocol { self }
    func addIdentity(identity: inout Identity, for identityContext: String) async {}
    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? { nil }
    func saveIdentity(_ identity: Identity) async {}
    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        try await keys.sign(messageData, uuid: identity.uuid)
    }
    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: messageData, identity: identity)
    }
    func randomBytes64() async -> Data? { try? SecureRandom.data(count: 64) }
    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) { ("k-\(tag)", "iv-\(tag)") }
}
