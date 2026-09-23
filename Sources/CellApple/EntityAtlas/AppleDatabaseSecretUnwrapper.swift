// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import Security
import CryptoKit
import LocalAuthentication
import CellBase

/// Owner-device software X25519 root protected by Data Protection Keychain and user presence.
/// This is not a Secure Enclave key. The private key exists transiently in this trusted process.
/// No implicit creation, shared access group, synchronisation or server master-key fallback.
public final class AppleDatabaseSecretUnwrapper: SecretUnwrappingProvider, @unchecked Sendable {
    private let service: String
    private let handleID: String
    private let expectedRecipient: SecretRecipient

    public init(service: String = "no.haven.database-secret.wrapping.v1", handleID: String, recipient: SecretRecipient) throws {
        guard !service.isEmpty, UUID(uuidString: handleID) != nil else { throw SecretCredentialError.invalidContract }
        self.service = service; self.handleID = handleID.lowercased(); self.expectedRecipient = recipient
    }

    /// Explicit setup only. A duplicate handle fails; an existing root is never replaced.
    public static func create(service: String = "no.haven.database-secret.wrapping.v1", handleID: String) async throws -> AppleDatabaseSecretUnwrapper {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let recipient = try SecretRecipient(publicKey: key.publicKey.rawRepresentation)
        let provider = try Self(service: service, handleID: handleID, recipient: recipient)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error) else {
            throw SecretCredentialError.unavailable
        }
        var query = provider.baseQuery
        query[kSecAttrAccessControl as String] = access
        query[kSecValueData as String] = key.rawRepresentation
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw status == errSecDuplicateItem ? SecretCredentialError.alreadyExists : SecretCredentialError.unavailable
        }
        return provider
    }

    public func recipient() async throws -> SecretRecipient { expectedRecipient }

    public func open(_ envelope: SealedDatabaseSecret.Envelope, context: DatabaseSecretContext) async throws -> SecretKeyMaterial {
        guard envelope.recipient == expectedRecipient else { throw SecretCredentialError.denied }
        // A fresh authentication context prevents a previous session's consent being silently reused.
        let authentication = LAContext()
        authentication.localizedReason = "Open your private cell database"
        defer { authentication.invalidate() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
        var query = baseQuery
        query[kSecUseAuthenticationContext as String] = authentication
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, var data = item as? Data else {
            if status == errSecItemNotFound { throw SecretCredentialError.missing }
            if status == errSecUserCanceled || status == errSecAuthFailed { throw SecretCredentialError.denied }
            throw SecretCredentialError.unavailable
        }
        defer { data.resetBytes(in: 0..<data.count) }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        guard key.publicKey.rawRepresentation == expectedRecipient.publicKey else { throw SecretCredentialError.integrity }
        try Task.checkCancellation()
        return try DatabaseSecretCrypto.open(envelope, context: context, privateKey: key)
        } onCancel: {
            authentication.invalidate()
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: handleID,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }
}
