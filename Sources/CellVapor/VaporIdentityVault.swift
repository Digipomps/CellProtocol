// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CellBase
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(Linux)
@_silgen_name("flistxattr")
private func haven_flistxattr(
    _ fileDescriptor: Int32,
    _ nameBuffer: UnsafeMutablePointer<CChar>?,
    _ size: Int
) -> Int

@_silgen_name("llistxattr")
private func haven_llistxattr(
    _ path: UnsafePointer<CChar>,
    _ nameBuffer: UnsafeMutablePointer<CChar>?,
    _ size: Int
) -> Int
#endif
#if canImport(Combine)
@preconcurrency import Combine
import CryptoKit
#else
import OpenCombine
import Crypto
#endif

/// A sanitized, content-bound revision of the persisted Vapor identity vault.
/// `fileDigest` is the lowercase SHA-256 of the exact encrypted file bytes.
public struct VaporIdentityVaultRevision: Codable, Equatable, Sendable {
    public static let schema = "haven.vapor-identity-vault.revision.v1"

    public let schema: String
    public let fileVersion: UInt64
    public let fileDigest: String?

    public init(
        schema: String = Self.schema,
        fileVersion: UInt64,
        fileDigest: String?
    ) {
        self.schema = schema
        self.fileVersion = fileVersion
        self.fileDigest = fileDigest
    }

    public static let missing = VaporIdentityVaultRevision(fileVersion: 0, fileDigest: nil)
}

/// Operationally sensitive identity-binding metadata. It contains no private
/// key material, but UUID/context/fingerprint tuples can correlate domains and
/// must not be exposed on a public route or written to unsanitized logs.
public struct VaporIdentityVaultBindingSummary: Codable, Equatable, Sendable {
    public let uuid: String
    public let context: String
    public let signingKeyFingerprint: String

    public init(uuid: String, context: String, signingKeyFingerprint: String) {
        self.uuid = uuid
        self.context = context
        self.signingKeyFingerprint = signingKeyFingerprint
    }
}

/// A deliberately bounded, requested-only projection of persisted identity
/// bindings. UUID/context/fingerprint tuples remain operationally sensitive:
/// callers must keep this offline and must not expose it on a public route.
public struct VaporIdentityVaultRequestedBindingInventory: Codable, Equatable, Sendable {
    public static let schema = "haven.vapor-identity-vault.requested-binding-inventory.v1"
    public static let maximumRequestedContextCount = 256
    public static let maximumContextUTF8Length = 1_024

    public let schema: String
    public let revision: VaporIdentityVaultRevision
    public let bindings: [VaporIdentityVaultBindingSummary]

    public init(
        schema: String = Self.schema,
        revision: VaporIdentityVaultRevision,
        bindings: [VaporIdentityVaultBindingSummary]
    ) {
        self.schema = schema
        self.revision = revision
        self.bindings = bindings
    }
}

public struct VaporIdentityVaultStrictLoadResult: Codable, Equatable, Sendable {
    public static let schema = "haven.vapor-identity-vault.strict-load.v1"

    public let schema: String
    public let revision: VaporIdentityVaultRevision
    public let bindingCount: Int

    public init(
        schema: String = Self.schema,
        revision: VaporIdentityVaultRevision,
        bindingCount: Int
    ) {
        self.schema = schema
        self.revision = revision
        self.bindingCount = bindingCount
    }
}

public struct VaporIdentityProvisioningRequest: Codable, Equatable, Sendable {
    public let uuid: String
    public let context: String
    public let displayName: String

    public init(uuid: String, context: String, displayName: String) {
        self.uuid = uuid
        self.context = context
        self.displayName = displayName
    }
}

public enum VaporIdentityProvisioningAction: String, Codable, Equatable, Sendable {
    case keep
    case create
    case conflict
}

public struct VaporIdentityProvisioningPlanItem: Codable, Equatable, Sendable {
    public let request: VaporIdentityProvisioningRequest
    public let action: VaporIdentityProvisioningAction
    public let reasonCode: String

    public init(
        request: VaporIdentityProvisioningRequest,
        action: VaporIdentityProvisioningAction,
        reasonCode: String
    ) {
        self.request = request
        self.action = action
        self.reasonCode = reasonCode
    }
}

public struct VaporIdentityProvisioningInspection: Codable, Equatable, Sendable {
    public static let schema = "haven.vapor-identity-vault.provisioning-inspection.v1"

    public let schema: String
    public let revision: VaporIdentityVaultRevision
    public let items: [VaporIdentityProvisioningPlanItem]

    public init(
        schema: String = Self.schema,
        revision: VaporIdentityVaultRevision,
        items: [VaporIdentityProvisioningPlanItem]
    ) {
        self.schema = schema
        self.revision = revision
        self.items = items
    }

    public var hasConflicts: Bool {
        items.contains { $0.action == .conflict }
    }
}

public struct VaporIdentityVaultProvisioningResult: Codable, Equatable, Sendable {
    public static let schema = "haven.vapor-identity-vault.provisioning-result.v1"

    public let schema: String
    public let previousRevision: VaporIdentityVaultRevision
    public let revision: VaporIdentityVaultRevision
    public let createdUUIDs: [String]
    public let keptUUIDs: [String]
    public let bindings: [VaporIdentityVaultBindingSummary]

    public init(
        schema: String = Self.schema,
        previousRevision: VaporIdentityVaultRevision,
        revision: VaporIdentityVaultRevision,
        createdUUIDs: [String],
        keptUUIDs: [String],
        bindings: [VaporIdentityVaultBindingSummary]
    ) {
        self.schema = schema
        self.previousRevision = previousRevision
        self.revision = revision
        self.createdUUIDs = createdUUIDs
        self.keptUUIDs = keptUUIDs
        self.bindings = bindings
    }
}

/// Stable, sanitized failures for strict vault reads and provisioning. Associated
/// paths, key bytes, ciphertext, and identity material are deliberately omitted.
public enum VaporIdentityVaultStrictError: Error, Equatable, Sendable {
    case vaultMissing
    case masterKeyMissing
    case invalidMasterKey
    case unsafeVaultMetadata
    case unsafeMasterKeyMetadata
    case vaultTooLarge
    case tooManyIdentities
    case authenticationFailed
    case legacyPlaintextRejected
    case malformedVault
    case unsupportedVaultSchema
    case duplicateUUID
    case duplicateContext
    case invalidIdentityDescriptor
    case requestedContextSetEmpty
    case requestedContextLimitExceeded
    case requestedContextInvalid
    case requestedContextDuplicate
    case requestedInventoryOfflineRequired
    case incompleteKeyMaterial
    case inconsistentKeyMaterial
    case identityNotFound
    case identityBindingConflict
    case provisioningConflict
    case staleRevision
    case lockUnavailable
    case lockCleanupRequired
    case strictRuntimeRootDrift
    case strictRuntimeWriteProhibited
    case strictRuntimeBackingStoreDrift
    case strictMasterKeyChanged
    case persistenceFailed
    case persistenceVerificationFailed
    case persistenceOutcomeUnknown

    public var reasonCode: String {
        switch self {
        case .vaultMissing: return "identity_vault_missing"
        case .masterKeyMissing: return "identity_vault_master_key_missing"
        case .invalidMasterKey: return "identity_vault_master_key_invalid"
        case .unsafeVaultMetadata: return "identity_vault_metadata_unsafe"
        case .unsafeMasterKeyMetadata: return "identity_vault_master_key_metadata_unsafe"
        case .vaultTooLarge: return "identity_vault_file_too_large"
        case .tooManyIdentities: return "identity_vault_identity_limit_exceeded"
        case .authenticationFailed: return "identity_vault_authentication_failed"
        case .legacyPlaintextRejected: return "identity_vault_plaintext_rejected"
        case .malformedVault: return "identity_vault_malformed"
        case .unsupportedVaultSchema: return "identity_vault_schema_unsupported"
        case .duplicateUUID: return "identity_vault_duplicate_uuid"
        case .duplicateContext: return "identity_vault_duplicate_context"
        case .invalidIdentityDescriptor: return "identity_vault_descriptor_invalid"
        case .requestedContextSetEmpty: return "identity_vault_requested_context_set_empty"
        case .requestedContextLimitExceeded: return "identity_vault_requested_context_limit_exceeded"
        case .requestedContextInvalid: return "identity_vault_requested_context_invalid"
        case .requestedContextDuplicate: return "identity_vault_requested_context_duplicate"
        case .requestedInventoryOfflineRequired: return "identity_vault_requested_inventory_offline_required"
        case .incompleteKeyMaterial: return "identity_vault_key_material_incomplete"
        case .inconsistentKeyMaterial: return "identity_vault_key_material_inconsistent"
        case .identityNotFound: return "identity_vault_identity_missing"
        case .identityBindingConflict: return "identity_vault_binding_conflict"
        case .provisioningConflict: return "identity_vault_provisioning_conflict"
        case .staleRevision: return "identity_vault_revision_stale"
        case .lockUnavailable: return "identity_vault_lock_unavailable"
        case .lockCleanupRequired: return "identity_vault_lock_cleanup_required"
        case .strictRuntimeRootDrift: return "identity_vault_strict_runtime_root_drift"
        case .strictRuntimeWriteProhibited: return "identity_vault_strict_runtime_write_prohibited"
        case .strictRuntimeBackingStoreDrift: return "identity_vault_strict_runtime_backing_store_drift"
        case .strictMasterKeyChanged: return "identity_vault_master_key_changed"
        case .persistenceFailed: return "identity_vault_persistence_failed"
        case .persistenceVerificationFailed: return "identity_vault_persistence_verification_failed"
        case .persistenceOutcomeUnknown: return "identity_vault_persistence_outcome_unknown"
        }
    }
}



//@available(iOS 15.0.0, *)
public actor VaporIdentityVault: IdentityVaultProtocol, ScopedSecretProviderProtocol, IdentityKeyRoleProviderProtocol {
    private var initialized = false
    private var loadedDocumentRootPath: String?
    private var identitiesDictionary = [String : String]()
    private var visitingIdentitiesDictionary = [String : Identity]()
    private var identitiesUUIDDictionary = [String : VaultIdentity]()
    private var persistedFileVersion: UInt64 = 0
    /// Once set, production code cannot unset or replace this path. This keeps
    /// every legacy runtime entry point bound to the vault that was strictly
    /// validated at process startup.
    private var strictRuntimeDocumentRootPath: String?
    private var strictRuntimeRevision: VaporIdentityVaultRevision?
    private var strictRuntimeMasterKeySnapshot: StrictMasterKeySnapshot?
    private var strictRuntimeBackingStoreReady = false
#if DEBUG
    private var strictWriteFailureForTesting = false
    private var strictDirectorySyncFailureForTesting = false
    private var strictLockCleanupFailureForTesting = false
#endif
    static let identitiesFileName = "OrganisationIdentities.crypt"
    private static let encryptedVaultMagic = Data("CVLT1".utf8)
    private static let nonceLength = 12
    private static let tagLength = 16
    private static let keyEnvName = "CELL_VAULT_MASTER_KEY_B64"
    private static let keyPathEnvName = "CELL_VAULT_MASTER_KEY_PATH"
    private static let allowDevKeygenEnvName = "CELL_VAULT_ALLOW_DEV_KEYGEN"
    private static let documentRootEnvName = "CELL_VAULT_DOCUMENT_ROOT"
    private static let defaultMasterKeyFilename = "vault-master.key"
    private static let maxVaultFileBytes: UInt64 = 64 * 1024 * 1024
    private static let maxPersistedIdentityCount = 100_000
    private static let strictVaultSchema = "haven.vapor-identity-vault.v2"
    private static let strictLockFilename = ".OrganisationIdentities.lock"
#if os(Linux)
    static let documentRoot = "/app/CellsContainer/" // We should move this to a more secret place
#else
    static let documentRoot = "/Users/Shared/"
#endif
    
    public static let shared = VaporIdentityVault()
    
    public func identityVaultReference() async -> String? {
        guard strictRuntimeRootIsCurrent else {
            return nil
        }
        return currentVaultReference()
    }

    public func initialize() async -> IdentityVaultProtocol {
        let currentDocumentRootPath = configuredDocumentRootURL().standardizedFileURL.path
        if let strictRuntimeDocumentRootPath {
            guard currentDocumentRootPath == strictRuntimeDocumentRootPath else {
                logStrictRuntimeRejection(.strictRuntimeRootDrift)
                return self
            }
            return self
        }
        if initialized, loadedDocumentRootPath == currentDocumentRootPath {
            return self
        }

        initialized = true
        loadedDocumentRootPath = currentDocumentRootPath
        identitiesDictionary.removeAll(keepingCapacity: true)
        visitingIdentitiesDictionary.removeAll(keepingCapacity: true)
        identitiesUUIDDictionary.removeAll(keepingCapacity: true)
        persistedFileVersion = 0

        do {
            try ensureVaultDirectoryExists()
            let identities = await loadIdentities()
            if let identities = identities {
                for identity in identities {
                    if let identityContext = identity.identityContext,
                       identityContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        identitiesDictionary[identityContext] = identity.uuid
                    }
                    identitiesUUIDDictionary[identity.uuid] = identity // Also add with uuid for uuid lookups
                }

                CellBase.diagnosticLog(
                    "VaporIdentityVault loaded \(identities.count) identities from \(currentDocumentRootPath)",
                    domain: .identity
                )
            }
        } catch {
            CellBase.diagnosticLog(
                "VaporIdentityVault initialization skipped persisted identities from \(currentDocumentRootPath): \(error)",
                domain: .identity
            )
        }
        return self
    }
    
    public func setPostAuthenticationInitializer(initializer: @escaping () -> ()) async {
        CellBase.diagnosticLog("VaporIdentityVault post-auth initializer is not implemented", domain: .identity)
    }

    @discardableResult
    private func ensureInitializedForCurrentDocumentRoot() async -> Bool {
        let currentDocumentRootPath = configuredDocumentRootURL().standardizedFileURL.path
        if let strictRuntimeDocumentRootPath {
            guard currentDocumentRootPath == strictRuntimeDocumentRootPath,
                  strictRuntimeBackingStoreReady,
                  initialized,
                  loadedDocumentRootPath == strictRuntimeDocumentRootPath else {
                logStrictRuntimeRejection(strictRuntimeAccessError() ?? .strictRuntimeRootDrift)
                return false
            }
            return true
        }
        guard initialized, loadedDocumentRootPath == currentDocumentRootPath else {
            _ = await initialize()
            return initialized && loadedDocumentRootPath == currentDocumentRootPath
        }
        return true
    }

    private var strictRuntimeRootIsCurrent: Bool {
        guard let strictRuntimeDocumentRootPath else {
            return true
        }
        return configuredDocumentRootURL().standardizedFileURL.path == strictRuntimeDocumentRootPath
    }

    private func requireStrictRuntimeRootIfActive() throws {
        guard strictRuntimeRootIsCurrent else {
            throw VaporIdentityVaultStrictError.strictRuntimeRootDrift
        }
    }

    private func strictRuntimeAccessError() -> VaporIdentityVaultStrictError? {
        guard strictRuntimeDocumentRootPath != nil else {
            return nil
        }
        guard strictRuntimeRootIsCurrent else {
            return .strictRuntimeRootDrift
        }
        guard strictRuntimeBackingStoreReady else {
            return .strictRuntimeBackingStoreDrift
        }
        return nil
    }

    private func logStrictRuntimeRejection(_ error: VaporIdentityVaultStrictError) {
        CellBase.diagnosticLog(
            "VaporIdentityVault rejected operation: \(error.reasonCode)",
            domain: .identity
        )
    }
    
    
    
    public func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        throw IdentityVaultError.notImplemented
//        return (key: "", iv: "")
    }

    public func scopedSecretData(tag: String, minimumLength: Int) async throws -> Data {
        try requireStrictRuntimeRootIfActive()
        let masterKeyData: Data
        if strictRuntimeDocumentRootPath == nil {
            masterKeyData = try loadOrCreateMasterKeyData()
        } else {
            guard let strictRuntimeMasterKeySnapshot else {
                throw VaporIdentityVaultStrictError.invalidMasterKey
            }
            masterKeyData = strictRuntimeMasterKeySnapshot.data
        }
        let masterKey = SymmetricKey(data: masterKeyData)
        let length = max(minimumLength, 32)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Data("CellVaporScopedSecretSalt.v1".utf8),
            info: Data(tag.utf8),
            outputByteCount: length
        )
        return derived.withUnsafeBytes { Data($0) }
    }
    
    
    
  
    
    private init() {}

    private enum StorageError: Error, CustomStringConvertible {
        case vaultFileTooLarge(bytes: UInt64, maxBytes: UInt64)
        case tooManyPersistedIdentities(count: Int, maxCount: Int)

        var description: String {
            switch self {
            case .vaultFileTooLarge(let bytes, let maxBytes):
                return "vault file too large: \(bytes) bytes exceeds \(maxBytes)"
            case .tooManyPersistedIdentities(let count, let maxCount):
                return "too many persisted identities: \(count) exceeds \(maxCount)"
            }
        }
    }

    private struct StrictVaultIdentityRecord: Codable {
        let uuid: String
        let displayName: String
        let identityContext: String
        let publicKey: Data
        let privateKey: Data
        let keyAgreementPublicKey: Data
        let keyAgreementPrivateKey: Data
        let publicSecureKey: SecureKey
        let privateSecureKey: SecureKey
        let publicKeyAgreementSecureKey: SecureKey
        let privateKeyAgreementSecureKey: SecureKey
        let properties: [String: ValueType]?
        let privateProperties: [String: ValueType]?

        init(_ vaultIdentity: VaultIdentity) throws {
            guard let identityContext = vaultIdentity.identityContext,
                  let publicSecureKey = vaultIdentity.publicSecureKey,
                  let privateSecureKey = vaultIdentity.privateSecureKey,
                  let publicKeyAgreementSecureKey = vaultIdentity.publicKeyAgreementSecureKey,
                  let privateKeyAgreementSecureKey = vaultIdentity.privateKeyAgreementSecureKey else {
                throw VaporIdentityVaultStrictError.incompleteKeyMaterial
            }
            uuid = vaultIdentity.uuid
            displayName = vaultIdentity.displayName
            self.identityContext = identityContext
            publicKey = vaultIdentity.publicKey
            privateKey = vaultIdentity.privateKey
            keyAgreementPublicKey = vaultIdentity.keyAgreementPublicKey
            keyAgreementPrivateKey = vaultIdentity.keyAgreementPrivateKey
            self.publicSecureKey = publicSecureKey
            self.privateSecureKey = privateSecureKey
            self.publicKeyAgreementSecureKey = publicKeyAgreementSecureKey
            self.privateKeyAgreementSecureKey = privateKeyAgreementSecureKey
            properties = vaultIdentity.properties
            privateProperties = vaultIdentity.privateProperties
        }

        var vaultIdentity: VaultIdentity {
            var identity = VaultIdentity()
            identity.uuid = uuid
            identity.displayName = displayName
            identity.identityContext = identityContext
            identity.publicKey = publicKey
            identity.privateKey = privateKey
            identity.keyAgreementPublicKey = keyAgreementPublicKey
            identity.keyAgreementPrivateKey = keyAgreementPrivateKey
            identity.publicSecureKey = publicSecureKey
            identity.privateSecureKey = privateSecureKey
            identity.publicKeyAgreementSecureKey = publicKeyAgreementSecureKey
            identity.privateKeyAgreementSecureKey = privateKeyAgreementSecureKey
            identity.properties = properties
            identity.privateProperties = privateProperties
            return identity
        }
    }

    private struct StrictPersistedVaultDocument: Codable {
        let schema: String
        let fileVersion: UInt64
        let identities: [StrictVaultIdentityRecord]
    }

    private struct StrictParsedVault {
        let identities: [VaultIdentity]
        let revision: VaporIdentityVaultRevision
        let documentRootPath: String
    }

    private struct StrictFileSnapshot {
        let data: Data
        let device: UInt64
        let inode: UInt64
    }

    private struct StrictMasterKeySnapshot {
        let data: Data
        let sourcePath: String?
        let device: UInt64?
        let inode: UInt64?
        let digest: String

        func hasSameSourceAndContent(as other: StrictMasterKeySnapshot) -> Bool {
            sourcePath == other.sourcePath
                && device == other.device
                && inode == other.inode
                && digest == other.digest
        }
    }

    private enum StrictFileKind {
        case regular0600
        case regularPrivateKey
        case privateDirectory
    }

    // Strict metadata assumes a local POSIX filesystem. Same-UID hostile
    // processes and mutable ancestors outside the private document root remain
    // outside the in-process threat boundary; deployment must provide a private
    // mount and stop the service while provisioning. Final components reject
    // symlinks/hardlinks and unexpected extended attributes (including POSIX
    // ACL xattrs); macOS's non-authority `com.apple.provenance` marker is allowed.

    private func configuredDocumentRootURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[VaporIdentityVault.documentRootEnvName]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           override.isEmpty == false {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        if let documentRootPath = CellBase.documentRootPath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           documentRootPath.isEmpty == false {
            return URL(fileURLWithPath: documentRootPath, isDirectory: true)
        }

        return URL(fileURLWithPath: VaporIdentityVault.documentRoot, isDirectory: true)
    }

    private func currentVaultReference() -> String {
        let path = strictRuntimeDocumentRootPath
            ?? configuredDocumentRootURL().standardizedFileURL.path
        return "vapor:\(path)"
    }

    private func vaultFileURL() -> URL {
        return configuredDocumentRootURL().appendingPathComponent(VaporIdentityVault.identitiesFileName)
    }

    private func defaultMasterKeyURL() -> URL {
        return configuredDocumentRootURL()
            .appendingPathComponent(".secrets")
            .appendingPathComponent(VaporIdentityVault.defaultMasterKeyFilename)
    }

    private func ensureVaultDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: configuredDocumentRootURL(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func boolEnv(_ key: String) -> Bool? {
        guard let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        switch value {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func isProduction() -> Bool {
        let env = ProcessInfo.processInfo.environment["VAPOR_ENV"]?.lowercased() ?? ""
        return env == "production"
    }

    private func keyData(fromRawOrBase64 data: Data) -> Data? {
        if data.count == 32 {
            return data
        }
        if let asString = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let decoded = Data(base64Encoded: asString),
           decoded.count == 32 {
            return decoded
        }
        return nil
    }

    private func loadOrCreateMasterKeyData() throws -> Data {
        let env = ProcessInfo.processInfo.environment

        if let base64 = env[VaporIdentityVault.keyEnvName],
           let keyData = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
           keyData.count == 32 {
            return keyData
        }

        let keyFilePath = env[VaporIdentityVault.keyPathEnvName] ?? defaultMasterKeyURL().path
        let keyFileURL = URL(fileURLWithPath: keyFilePath)
        if FileManager.default.fileExists(atPath: keyFileURL.path) {
            let storedData = try Data(contentsOf: keyFileURL)
            if let keyData = keyData(fromRawOrBase64: storedData) {
                return keyData
            }
            throw IdentityVaultError.noKey
        }

        let allowDevKeygen = boolEnv(VaporIdentityVault.allowDevKeygenEnvName) ?? !isProduction()
        if !allowDevKeygen {
            throw IdentityVaultError.noKey
        }

        let generatedKey = SymmetricKey(size: .bits256)
        let keyData = generatedKey.withUnsafeBytes { Data($0) }
        let keyString = keyData.base64EncodedString()

        let keyDirURL = keyFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: keyDirURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try keyString.data(using: .utf8)?.write(
            to: keyFileURL,
            options: [.atomic]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
        return keyData
    }

    private func vaultKey(scope: String) throws -> SymmetricKey {
        let masterKeyData = try loadOrCreateMasterKeyData()
        let masterKey = SymmetricKey(data: masterKeyData)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Data("CellScaffoldVaultSalt.v1".utf8),
            info: Data(scope.utf8),
            outputByteCount: 32
        )
    }

    private func encryptVaultData(_ plaintext: Data, scope: String) throws -> Data {
        let key = try vaultKey(scope: scope)
        let aad = Data("cell-vault-v1:\(scope)".utf8)
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key, authenticating: aad)
        let nonceData = sealedBox.nonce.withUnsafeBytes { Data($0) }

        var output = Data()
        output.append(VaporIdentityVault.encryptedVaultMagic)
        output.append(nonceData)
        output.append(sealedBox.ciphertext)
        output.append(sealedBox.tag)
        return output
    }

    private func decryptVaultData(_ encryptedData: Data, scope: String) throws -> (payload: Data, needsMigration: Bool) {
        let headerSize = VaporIdentityVault.encryptedVaultMagic.count
        if encryptedData.count >= headerSize + VaporIdentityVault.nonceLength + VaporIdentityVault.tagLength,
           encryptedData.prefix(headerSize) == VaporIdentityVault.encryptedVaultMagic {
            let nonceStart = headerSize
            let nonceEnd = nonceStart + VaporIdentityVault.nonceLength
            let tagStart = encryptedData.count - VaporIdentityVault.tagLength
            let nonceData = encryptedData.subdata(in: nonceStart..<nonceEnd)
            let ciphertext = encryptedData.subdata(in: nonceEnd..<tagStart)
            let tag = encryptedData.subdata(in: tagStart..<encryptedData.count)
            let nonce = try ChaChaPoly.Nonce(data: nonceData)
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let key = try vaultKey(scope: scope)
            let aad = Data("cell-vault-v1:\(scope)".utf8)
            return (try ChaChaPoly.open(box, using: key, authenticating: aad), false)
        }

        if let legacyData = try? VaultLegacyPayloadDecoder.decrypt(encryptedData) {
            return (legacyData, true)
        }
        return (encryptedData, true)
    }

    private func strictMasterKeyData(documentRootURL: URL? = nil) throws -> Data {
        try strictMasterKeySnapshot(documentRootURL: documentRootURL).data
    }

    private func strictMasterKeySnapshot(
        documentRootURL: URL? = nil
    ) throws -> StrictMasterKeySnapshot {
        let environment = ProcessInfo.processInfo.environment
        if let configuredValue = environment[VaporIdentityVault.keyEnvName] {
            guard let keyData = Data(
                base64Encoded: configuredValue.trimmingCharacters(in: .whitespacesAndNewlines)
            ), keyData.count == 32 else {
                throw VaporIdentityVaultStrictError.invalidMasterKey
            }
            return StrictMasterKeySnapshot(
                data: keyData,
                sourcePath: nil,
                device: nil,
                inode: nil,
                digest: sha256Hex(keyData)
            )
        }

        let capturedRoot = (documentRootURL ?? configuredDocumentRootURL()).standardizedFileURL
        let defaultKeyURL = capturedRoot
            .appendingPathComponent(".secrets", isDirectory: true)
            .appendingPathComponent(VaporIdentityVault.defaultMasterKeyFilename, isDirectory: false)
        let keyFilePath = environment[VaporIdentityVault.keyPathEnvName] ?? defaultKeyURL.path
        let keyFileURL = URL(fileURLWithPath: keyFilePath, isDirectory: false)
        guard strictPathExists(keyFileURL) else {
            throw VaporIdentityVaultStrictError.masterKeyMissing
        }
        do {
            let storedFile = try readStrictRegularFile(
                at: keyFileURL,
                kind: .regularPrivateKey,
                maximumBytes: 4_096,
                metadataError: .unsafeMasterKeyMetadata,
                sizeError: .invalidMasterKey,
                readError: .invalidMasterKey
            )
            guard let keyData = keyData(fromRawOrBase64: storedFile.data) else {
                throw VaporIdentityVaultStrictError.invalidMasterKey
            }
            return StrictMasterKeySnapshot(
                data: keyData,
                sourcePath: keyFileURL.standardizedFileURL.path,
                device: storedFile.device,
                inode: storedFile.inode,
                digest: sha256Hex(keyData)
            )
        } catch let strictError as VaporIdentityVaultStrictError {
            throw strictError
        } catch {
            throw VaporIdentityVaultStrictError.invalidMasterKey
        }
    }

    private func strictVaultKey(
        scope: String,
        documentRootURL: URL,
        masterKeySnapshot: StrictMasterKeySnapshot? = nil
    ) throws -> SymmetricKey {
        let keyData = try masterKeySnapshot?.data
            ?? strictMasterKeyData(documentRootURL: documentRootURL)
        let masterKey = SymmetricKey(data: keyData)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Data("CellScaffoldVaultSalt.v1".utf8),
            info: Data(scope.utf8),
            outputByteCount: 32
        )
    }

    private func decryptVaultDataStrict(
        _ encryptedData: Data,
        scope: String,
        documentRootURL: URL,
        masterKeySnapshot: StrictMasterKeySnapshot? = nil
    ) throws -> Data {
        let headerSize = VaporIdentityVault.encryptedVaultMagic.count
        guard encryptedData.count >= headerSize + VaporIdentityVault.nonceLength + VaporIdentityVault.tagLength else {
            throw VaporIdentityVaultStrictError.legacyPlaintextRejected
        }
        guard encryptedData.prefix(headerSize) == VaporIdentityVault.encryptedVaultMagic else {
            throw VaporIdentityVaultStrictError.legacyPlaintextRejected
        }

        do {
            let nonceStart = headerSize
            let nonceEnd = nonceStart + VaporIdentityVault.nonceLength
            let tagStart = encryptedData.count - VaporIdentityVault.tagLength
            let nonce = try ChaChaPoly.Nonce(data: encryptedData.subdata(in: nonceStart..<nonceEnd))
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: encryptedData.subdata(in: nonceEnd..<tagStart),
                tag: encryptedData.subdata(in: tagStart..<encryptedData.count)
            )
            return try ChaChaPoly.open(
                box,
                using: strictVaultKey(
                    scope: scope,
                    documentRootURL: documentRootURL,
                    masterKeySnapshot: masterKeySnapshot
                ),
                authenticating: Data("cell-vault-v1:\(scope)".utf8)
            )
        } catch let strictError as VaporIdentityVaultStrictError {
            throw strictError
        } catch {
            throw VaporIdentityVaultStrictError.authenticationFailed
        }
    }

    private func encryptVaultDataStrict(
        _ plaintext: Data,
        scope: String,
        documentRootURL: URL,
        masterKeySnapshot: StrictMasterKeySnapshot? = nil
    ) throws -> Data {
        do {
            let sealedBox = try ChaChaPoly.seal(
                plaintext,
                using: strictVaultKey(
                    scope: scope,
                    documentRootURL: documentRootURL,
                    masterKeySnapshot: masterKeySnapshot
                ),
                authenticating: Data("cell-vault-v1:\(scope)".utf8)
            )
            var output = Data()
            output.append(VaporIdentityVault.encryptedVaultMagic)
            output.append(sealedBox.nonce.withUnsafeBytes { Data($0) })
            output.append(sealedBox.ciphertext)
            output.append(sealedBox.tag)
            return output
        } catch let strictError as VaporIdentityVaultStrictError {
            throw strictError
        } catch {
            throw VaporIdentityVaultStrictError.persistenceFailed
        }
    }

    private func strictPathExists(_ url: URL) -> Bool {
        var info = stat()
#if canImport(Darwin)
        let result = Darwin.lstat(url.path, &info)
#elseif canImport(Glibc)
        let result = Glibc.lstat(url.path, &info)
#else
        let result = -1
#endif
        return result == 0
    }

    private func validateStrictMetadata(
        at url: URL,
        kind: StrictFileKind,
        error: VaporIdentityVaultStrictError
    ) throws {
        var info = stat()
#if canImport(Darwin)
        let status = Darwin.lstat(url.path, &info)
#elseif canImport(Glibc)
        let status = Glibc.lstat(url.path, &info)
#else
        let status = -1
#endif
        guard status == 0 else {
            throw error
        }
        try validateNoExtendedAttributes(at: url, error: error)

        let fileType = info.st_mode & mode_t(S_IFMT)
        let permissions = info.st_mode & mode_t(0o777)
        guard info.st_uid == geteuid() else {
            throw error
        }
        switch kind {
        case .regular0600:
            guard fileType == mode_t(S_IFREG),
                  permissions == mode_t(0o600),
                  info.st_nlink == 1 else {
                throw error
            }
        case .regularPrivateKey:
            guard fileType == mode_t(S_IFREG),
                  permissions == mode_t(0o400) || permissions == mode_t(0o600),
                  info.st_nlink == 1 else {
                throw error
            }
        case .privateDirectory:
            guard fileType == mode_t(S_IFDIR),
                  permissions & mode_t(0o022) == 0 else {
                throw error
            }
        }
    }

    private func validateNoExtendedAttributes(
        at url: URL,
        error: VaporIdentityVaultStrictError
    ) throws {
        let count: Int
#if canImport(Darwin)
        count = Darwin.listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
#elseif os(Linux)
        count = url.path.withCString { haven_llistxattr($0, nil, 0) }
#else
        count = -1
#endif
        guard count >= 0 else {
            throw error
        }
        guard count > 0 else { return }
        var buffer = [CChar](repeating: 0, count: count)
        let readCount: Int
#if canImport(Darwin)
        readCount = buffer.withUnsafeMutableBufferPointer {
            Darwin.listxattr(url.path, $0.baseAddress, $0.count, XATTR_NOFOLLOW)
        }
#elseif os(Linux)
        readCount = buffer.withUnsafeMutableBufferPointer { pointer in
            url.path.withCString { haven_llistxattr($0, pointer.baseAddress, pointer.count) }
        }
#else
        readCount = -1
#endif
        guard readCount == count,
              extendedAttributeNames(in: buffer).isSubset(of: allowedStrictExtendedAttributes) else {
            throw error
        }
    }

    private func validateNoExtendedAttributes(
        fileDescriptor: Int32,
        error: VaporIdentityVaultStrictError
    ) throws {
        let count: Int
#if canImport(Darwin)
        count = Darwin.flistxattr(fileDescriptor, nil, 0, 0)
#elseif os(Linux)
        count = haven_flistxattr(fileDescriptor, nil, 0)
#else
        count = -1
#endif
        guard count >= 0 else {
            throw error
        }
        guard count > 0 else { return }
        var buffer = [CChar](repeating: 0, count: count)
        let readCount: Int
#if canImport(Darwin)
        readCount = buffer.withUnsafeMutableBufferPointer {
            Darwin.flistxattr(fileDescriptor, $0.baseAddress, $0.count, 0)
        }
#elseif os(Linux)
        readCount = buffer.withUnsafeMutableBufferPointer {
            haven_flistxattr(fileDescriptor, $0.baseAddress, $0.count)
        }
#else
        readCount = -1
#endif
        guard readCount == count,
              extendedAttributeNames(in: buffer).isSubset(of: allowedStrictExtendedAttributes) else {
            throw error
        }
    }

    private var allowedStrictExtendedAttributes: Set<String> {
#if canImport(Darwin)
        // macOS attaches this immutable provenance marker to locally created
        // files/directories. It carries no ACL or alternate file contents.
        return ["com.apple.provenance"]
#else
        return []
#endif
    }

    private func extendedAttributeNames(in buffer: [CChar]) -> Set<String> {
        let bytes = buffer.map { UInt8(bitPattern: $0) }
        return Set(bytes.split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) })
    }

    /// Opens the final path without following a symlink, validates metadata on
    /// that exact descriptor, and performs a bounded read from the same inode.
    /// This prevents a path swap between metadata validation and reading.
    private func readStrictRegularFile(
        at url: URL,
        kind: StrictFileKind,
        maximumBytes: Int,
        metadataError: VaporIdentityVaultStrictError,
        sizeError: VaporIdentityVaultStrictError,
        readError: VaporIdentityVaultStrictError
    ) throws -> StrictFileSnapshot {
        let descriptor: Int32
#if canImport(Darwin)
        descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
#elseif canImport(Glibc)
        descriptor = Glibc.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
#else
        descriptor = -1
#endif
        guard descriptor >= 0 else {
            throw metadataError
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
#if canImport(Darwin)
        let status = Darwin.fstat(descriptor, &info)
#elseif canImport(Glibc)
        let status = Glibc.fstat(descriptor, &info)
#else
        let status = -1
#endif
        guard status == 0,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_size >= 0 else {
            throw metadataError
        }
        try validateNoExtendedAttributes(fileDescriptor: descriptor, error: metadataError)
        guard UInt64(info.st_size) <= UInt64(maximumBytes) else {
            throw sizeError
        }

        let fileType = info.st_mode & mode_t(S_IFMT)
        let permissions = info.st_mode & mode_t(0o777)
        guard fileType == mode_t(S_IFREG) else {
            throw metadataError
        }
        switch kind {
        case .regular0600:
            guard permissions == mode_t(0o600) else {
                throw metadataError
            }
        case .regularPrivateKey:
            guard permissions == mode_t(0o400) || permissions == mode_t(0o600) else {
                throw metadataError
            }
        case .privateDirectory:
            throw metadataError
        }

        do {
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else {
                throw readError
            }
            let trailingByte = try handle.read(upToCount: 1) ?? Data()
            guard trailingByte.isEmpty else {
                throw readError
            }
            return StrictFileSnapshot(
                data: data,
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino)
            )
        } catch let strictError as VaporIdentityVaultStrictError {
            throw strictError
        } catch {
            throw readError
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validateStrictIdentity(_ vaultIdentity: VaultIdentity) throws {
        guard let context = vaultIdentity.identityContext,
              isValidIdentityField(vaultIdentity.uuid, maximumUTF8Length: 512),
              isValidIdentityField(context, maximumUTF8Length: 1_024),
              isValidIdentityField(vaultIdentity.displayName, maximumUTF8Length: 1_024) else {
            throw VaporIdentityVaultStrictError.invalidIdentityDescriptor
        }
        guard vaultIdentity.publicKey.count == 32,
              vaultIdentity.privateKey.count == 32,
              vaultIdentity.keyAgreementPublicKey.count == 32,
              vaultIdentity.keyAgreementPrivateKey.count == 32,
              let publicSecureKey = vaultIdentity.publicSecureKey,
              let privateSecureKey = vaultIdentity.privateSecureKey,
              let publicKeyAgreementSecureKey = vaultIdentity.publicKeyAgreementSecureKey,
              let privateKeyAgreementSecureKey = vaultIdentity.privateKeyAgreementSecureKey else {
            throw VaporIdentityVaultStrictError.incompleteKeyMaterial
        }

        guard publicSecureKey.privateKey == false,
              publicSecureKey.use == .signature,
              publicSecureKey.algorithm == .EdDSA,
              publicSecureKey.size == 256,
              publicSecureKey.curveType == .Curve25519,
              publicSecureKey.compressedKey == vaultIdentity.publicKey,
              privateSecureKey.privateKey,
              privateSecureKey.use == .signature,
              privateSecureKey.algorithm == .EdDSA,
              privateSecureKey.size == 256,
              privateSecureKey.curveType == .Curve25519,
              privateSecureKey.compressedKey == vaultIdentity.privateKey,
              publicKeyAgreementSecureKey.privateKey == false,
              publicKeyAgreementSecureKey.use == .keyAgreement,
              publicKeyAgreementSecureKey.algorithm == .X25519,
              publicKeyAgreementSecureKey.size == 256,
              publicKeyAgreementSecureKey.curveType == .Curve25519,
              publicKeyAgreementSecureKey.compressedKey == vaultIdentity.keyAgreementPublicKey,
              privateKeyAgreementSecureKey.privateKey,
              privateKeyAgreementSecureKey.use == .keyAgreement,
              privateKeyAgreementSecureKey.algorithm == .X25519,
              privateKeyAgreementSecureKey.size == 256,
              privateKeyAgreementSecureKey.curveType == .Curve25519,
              privateKeyAgreementSecureKey.compressedKey == vaultIdentity.keyAgreementPrivateKey else {
            throw VaporIdentityVaultStrictError.inconsistentKeyMaterial
        }

        do {
            let signingPrivateKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: vaultIdentity.privateKey
            )
            let agreementPrivateKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: vaultIdentity.keyAgreementPrivateKey
            )
            guard signingPrivateKey.publicKey.rawRepresentation == vaultIdentity.publicKey,
                  agreementPrivateKey.publicKey.rawRepresentation == vaultIdentity.keyAgreementPublicKey else {
                throw VaporIdentityVaultStrictError.inconsistentKeyMaterial
            }
        } catch let strictError as VaporIdentityVaultStrictError {
            throw strictError
        } catch {
            throw VaporIdentityVaultStrictError.inconsistentKeyMaterial
        }
    }

    private func isValidIdentityField(_ value: String, maximumUTF8Length: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed
            && value.isEmpty == false
            && value.utf8.count <= maximumUTF8Length
            && value.contains("\0") == false
    }

    private func decodeStrictPayload(_ plaintext: Data) throws -> (identities: [VaultIdentity], fileVersion: UInt64) {
        let decoder = JSONDecoder()
        guard let firstByte = plaintext.first(where: {
            $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09
        }) else {
            throw VaporIdentityVaultStrictError.malformedVault
        }
        do {
            if firstByte == 0x7B {
                let document = try decoder.decode(StrictPersistedVaultDocument.self, from: plaintext)
                guard document.schema == VaporIdentityVault.strictVaultSchema,
                      document.fileVersion > 0 else {
                    throw VaporIdentityVaultStrictError.unsupportedVaultSchema
                }
                return (document.identities.map(\.vaultIdentity), document.fileVersion)
            }
            if firstByte == 0x5B {
                let legacyRecords = try decoder.decode([StrictVaultIdentityRecord].self, from: plaintext)
                return (legacyRecords.map(\.vaultIdentity), 0)
            }
        } catch let strictError as VaporIdentityVaultStrictError {
            throw strictError
        } catch let decodingError as Swift.DecodingError {
            if decodingErrorIndicatesIncompleteKeyMaterial(decodingError) {
                throw VaporIdentityVaultStrictError.incompleteKeyMaterial
            }
            throw VaporIdentityVaultStrictError.malformedVault
        } catch {
            throw VaporIdentityVaultStrictError.malformedVault
        }
        throw VaporIdentityVaultStrictError.malformedVault
    }

    private func decodingErrorIndicatesIncompleteKeyMaterial(_ error: Swift.DecodingError) -> Bool {
        let keyNames: Set<String> = [
            "publicKey",
            "privateKey",
            "keyAgreementPublicKey",
            "keyAgreementPrivateKey",
            "publicSecureKey",
            "privateSecureKey",
            "publicKeyAgreementSecureKey",
            "privateKeyAgreementSecureKey"
        ]
        switch error {
        case .keyNotFound(let key, _):
            return keyNames.contains(key.stringValue)
        case .valueNotFound(_, let context), .typeMismatch(_, let context):
            return context.codingPath.last.map { keyNames.contains($0.stringValue) } ?? false
        case .dataCorrupted:
            return false
        @unknown default:
            return false
        }
    }

    private func strictReadVault(
        allowMissing: Bool,
        documentRootURL: URL? = nil,
        masterKeySnapshot: StrictMasterKeySnapshot? = nil
    ) throws -> StrictParsedVault {
        let capturedRoot = (documentRootURL ?? configuredDocumentRootURL()).standardizedFileURL
        let fileURL = capturedRoot.appendingPathComponent(
            VaporIdentityVault.identitiesFileName,
            isDirectory: false
        )
        guard strictPathExists(fileURL) else {
            if allowMissing {
                return StrictParsedVault(
                    identities: [],
                    revision: .missing,
                    documentRootPath: capturedRoot.path
                )
            }
            throw VaporIdentityVaultStrictError.vaultMissing
        }

        try validateStrictMetadata(
            at: capturedRoot,
            kind: .privateDirectory,
            error: .unsafeVaultMetadata
        )
        let encryptedData: Data
        do {
            encryptedData = try readStrictRegularFile(
                at: fileURL,
            kind: .regular0600,
                maximumBytes: Int(VaporIdentityVault.maxVaultFileBytes),
                metadataError: .unsafeVaultMetadata,
                sizeError: .vaultTooLarge,
                readError: .malformedVault
            ).data
        } catch let strictError as VaporIdentityVaultStrictError {
            throw strictError
        } catch {
            throw VaporIdentityVaultStrictError.malformedVault
        }

        let plaintext = try decryptVaultDataStrict(
            encryptedData,
            scope: VaporIdentityVault.identitiesFileName,
            documentRootURL: capturedRoot,
            masterKeySnapshot: masterKeySnapshot
        )
        let decoded = try decodeStrictPayload(plaintext)
        guard decoded.identities.count <= VaporIdentityVault.maxPersistedIdentityCount else {
            throw VaporIdentityVaultStrictError.tooManyIdentities
        }

        var seenUUIDs = Set<String>()
        var seenContexts = Set<String>()
        for identity in decoded.identities {
            guard seenUUIDs.insert(identity.uuid).inserted else {
                throw VaporIdentityVaultStrictError.duplicateUUID
            }
            guard let context = identity.identityContext,
                  seenContexts.insert(context).inserted else {
                throw VaporIdentityVaultStrictError.duplicateContext
            }
            try validateStrictIdentity(identity)
        }

        return StrictParsedVault(
            identities: decoded.identities,
            revision: VaporIdentityVaultRevision(
                fileVersion: decoded.fileVersion,
                fileDigest: sha256Hex(encryptedData)
            ),
            documentRootPath: capturedRoot.path
        )
    }

    private func publishStrictVault(_ parsedVault: StrictParsedVault) {
        identitiesDictionary.removeAll(keepingCapacity: true)
        identitiesUUIDDictionary.removeAll(keepingCapacity: true)
        for vaultIdentity in parsedVault.identities {
            guard let context = vaultIdentity.identityContext else { continue }
            identitiesDictionary[context] = vaultIdentity.uuid
            identitiesUUIDDictionary[vaultIdentity.uuid] = vaultIdentity
        }
        initialized = true
        loadedDocumentRootPath = parsedVault.documentRootPath
        persistedFileVersion = parsedVault.revision.fileVersion
    }

    /// Strictly validates and publishes the persisted vault, then permanently
    /// latches this actor to the exact standardized document root for the
    /// remainder of the production process. While active, legacy runtime APIs
    /// may read and sign with validated persisted identities, but cannot
    /// generate, heal, migrate, add, update, or persist them.
    @discardableResult
    public func activateStrictRuntimeMode() async throws -> VaporIdentityVaultStrictLoadResult {
        let documentRootPath = configuredDocumentRootURL().standardizedFileURL.path
        if let strictRuntimeDocumentRootPath,
           strictRuntimeDocumentRootPath != documentRootPath {
            throw VaporIdentityVaultStrictError.strictRuntimeRootDrift
        }

        if strictRuntimeDocumentRootPath != nil {
            return strictLoadResult(for: try strictRuntimeParsedVault())
        }

        let capturedRoot = URL(fileURLWithPath: documentRootPath, isDirectory: true)
        let masterKeySnapshot = try strictMasterKeySnapshot(documentRootURL: capturedRoot)
        let parsedVault = try strictReadVault(
            allowMissing: false,
            documentRootURL: capturedRoot,
            masterKeySnapshot: masterKeySnapshot
        )
        guard configuredDocumentRootURL().standardizedFileURL.path == documentRootPath else {
            throw VaporIdentityVaultStrictError.strictRuntimeRootDrift
        }
        publishStrictVault(parsedVault)
        visitingIdentitiesDictionary.removeAll(keepingCapacity: true)
        strictRuntimeDocumentRootPath = documentRootPath
        strictRuntimeRevision = parsedVault.revision
        strictRuntimeMasterKeySnapshot = masterKeySnapshot
        strictRuntimeBackingStoreReady = true
        return strictLoadResult(for: parsedVault)
    }

    /// Verifies that the latched vault and master-key backing files still match
    /// the exact revision, inode, and key digest activated at startup. It never
    /// publishes replacement authority or writes to disk. On failure, future
    /// identity reads and private-key operations fail closed until this exact
    /// backing state verifies again or the process restarts. Work already in
    /// flight cannot be revoked by this actor; readiness integration must stop
    /// new traffic and drain or terminate the process according to policy.
    @discardableResult
    public func verifyStrictRuntimeBackingStore() async throws -> VaporIdentityVaultStrictLoadResult {
        do {
            try requireStrictRuntimeRootIfActive()
            guard let documentRootPath = strictRuntimeDocumentRootPath,
                  let expectedRevision = strictRuntimeRevision,
                  let expectedMasterKey = strictRuntimeMasterKeySnapshot else {
                throw VaporIdentityVaultStrictError.strictRuntimeBackingStoreDrift
            }
            let documentRootURL = URL(fileURLWithPath: documentRootPath, isDirectory: true)
            try validateMasterKeySnapshotUnchanged(
                expectedMasterKey,
                documentRootURL: documentRootURL
            )
            let persistedVault = try strictReadVault(
                allowMissing: false,
                documentRootURL: documentRootURL,
                masterKeySnapshot: expectedMasterKey
            )
            guard persistedVault.revision == expectedRevision else {
                throw VaporIdentityVaultStrictError.strictRuntimeBackingStoreDrift
            }
            strictRuntimeBackingStoreReady = true
            return strictLoadResult(for: persistedVault)
        } catch let strictError as VaporIdentityVaultStrictError {
            strictRuntimeBackingStoreReady = false
            throw strictError
        } catch {
            strictRuntimeBackingStoreReady = false
            throw VaporIdentityVaultStrictError.strictRuntimeBackingStoreDrift
        }
    }

    private func strictRuntimeParsedVault() throws -> StrictParsedVault {
        try requireStrictRuntimeRootIfActive()
        guard let documentRootPath = strictRuntimeDocumentRootPath,
              let revision = strictRuntimeRevision,
              strictRuntimeMasterKeySnapshot != nil,
              strictRuntimeBackingStoreReady,
              initialized,
              loadedDocumentRootPath == documentRootPath else {
            throw VaporIdentityVaultStrictError.strictRuntimeRootDrift
        }
        let identities = identitiesUUIDDictionary.values.sorted {
            let leftContext = $0.identityContext ?? ""
            let rightContext = $1.identityContext ?? ""
            return leftContext == rightContext ? $0.uuid < $1.uuid : leftContext < rightContext
        }
        return StrictParsedVault(
            identities: identities,
            revision: revision,
            documentRootPath: documentRootPath
        )
    }

    /// Loads and validates the complete persisted vault without creating a
    /// directory, master key, vault file, identity, migration, or metadata fix.
    /// Only the actor's in-memory indexes are replaced after full validation.
    public func loadStrict() async throws -> VaporIdentityVaultStrictLoadResult {
        try requireStrictRuntimeRootIfActive()
        if strictRuntimeDocumentRootPath != nil {
            return strictLoadResult(for: try strictRuntimeParsedVault())
        }
        let parsedVault = try strictReadVault(allowMissing: strictRuntimeDocumentRootPath == nil)
        publishStrictVault(parsedVault)
        return strictLoadResult(for: parsedVault)
    }

    /// Offline-only inspection of the existing bindings for an exact, bounded
    /// set of requested contexts. The complete vault is still authenticated and
    /// validated before projection, but no unrequested binding, private key,
    /// display name, or private property is returned. A serving process with an
    /// activated strict runtime is rejected; runtime binding checks must instead
    /// use `requireIdentity(expectedUUID:for:)`. This method never creates,
    /// heals, migrates, publishes, or writes vault state.
    public func inspectExistingBindings(
        forRequestedContexts requestedContexts: [String]
    ) async throws -> VaporIdentityVaultRequestedBindingInventory {
        guard requestedContexts.isEmpty == false else {
            throw VaporIdentityVaultStrictError.requestedContextSetEmpty
        }
        guard requestedContexts.count
                <= VaporIdentityVaultRequestedBindingInventory.maximumRequestedContextCount else {
            throw VaporIdentityVaultStrictError.requestedContextLimitExceeded
        }

        var uniqueContexts = Set<String>()
        for context in requestedContexts {
            guard isValidIdentityField(
                context,
                maximumUTF8Length: VaporIdentityVaultRequestedBindingInventory.maximumContextUTF8Length
            ) else {
                throw VaporIdentityVaultStrictError.requestedContextInvalid
            }
            guard uniqueContexts.insert(context).inserted else {
                throw VaporIdentityVaultStrictError.requestedContextDuplicate
            }
        }

        guard strictRuntimeDocumentRootPath == nil else {
            throw VaporIdentityVaultStrictError.requestedInventoryOfflineRequired
        }
        let parsedVault = try strictReadVault(allowMissing: false)

        let requested = uniqueContexts
        let bindings = try parsedVault.identities.compactMap {
            vaultIdentity -> VaporIdentityVaultBindingSummary? in
            guard let context = vaultIdentity.identityContext,
                  requested.contains(context) else {
                return nil
            }
            guard let fingerprint = vaultIdentity.identity.signingPublicKeyFingerprint,
                  fingerprint.isEmpty == false else {
                throw VaporIdentityVaultStrictError.inconsistentKeyMaterial
            }
            return VaporIdentityVaultBindingSummary(
                uuid: vaultIdentity.uuid,
                context: context,
                signingKeyFingerprint: fingerprint
            )
        }.sorted {
            if $0.context == $1.context {
                return $0.uuid.utf8.lexicographicallyPrecedes($1.uuid.utf8)
            }
            return $0.context.utf8.lexicographicallyPrecedes($1.context.utf8)
        }

        return VaporIdentityVaultRequestedBindingInventory(
            revision: parsedVault.revision,
            bindings: bindings
        )
    }

    /// Requires one exact UUID/context binding from a strictly validated vault.
    /// It never heals, aliases, migrates, provisions, or writes.
    public func requireIdentity(expectedUUID: String, for context: String) async throws -> Identity {
        try requireStrictRuntimeRootIfActive()
        guard isValidIdentityField(expectedUUID, maximumUTF8Length: 512),
              isValidIdentityField(context, maximumUTF8Length: 1_024) else {
            throw VaporIdentityVaultStrictError.invalidIdentityDescriptor
        }
        let parsedVault = try strictRuntimeDocumentRootPath == nil
            ? strictReadVault(allowMissing: false)
            : strictRuntimeParsedVault()
        let identityByUUID = parsedVault.identities.first { $0.uuid == expectedUUID }
        let identityByContext = parsedVault.identities.first { $0.identityContext == context }
        guard let exactIdentity = identityByUUID,
              identityByContext?.uuid == expectedUUID,
              exactIdentity.identityContext == context else {
            if identityByUUID != nil || identityByContext != nil {
                throw VaporIdentityVaultStrictError.identityBindingConflict
            }
            throw VaporIdentityVaultStrictError.identityNotFound
        }

        let identity = exactIdentity.identity
        guard identity.uuid == expectedUUID,
              let fingerprint = identity.signingPublicKeyFingerprint,
              fingerprint.isEmpty == false else {
            throw VaporIdentityVaultStrictError.inconsistentKeyMaterial
        }
        if strictRuntimeDocumentRootPath == nil {
            publishStrictVault(parsedVault)
        }
        identity.identityVault = self
        identity.homeVaultReference = currentVaultReference()
        guard identity.signingPublicKeyFingerprint == fingerprint else {
            throw VaporIdentityVaultStrictError.inconsistentKeyMaterial
        }
        return identity
    }

    /// Produces a write-free provisioning plan. No key material is generated.
    public func inspectProvisioning(
        _ requests: [VaporIdentityProvisioningRequest]
    ) async throws -> VaporIdentityProvisioningInspection {
        try requireStrictRuntimeRootIfActive()
        let parsedVault = try strictRuntimeDocumentRootPath == nil
            ? strictReadVault(allowMissing: true)
            : strictRuntimeParsedVault()
        return provisioningInspection(for: requests, parsedVault: parsedVault)
    }

    /// Provisions all missing bindings with one content/version CAS and one
    /// atomic replacement. Any error leaves the actor's previously published
    /// in-memory state unchanged. An error before rename preserves old bytes;
    /// an fsync/read-back error after rename means the new file may be present
    /// but is deliberately not published until an explicit strict reload.
    ///
    /// This is an offline provisioning primitive, not a general writer lock:
    /// the service must be stopped and the caller must hold the deployment or
    /// volume lock. The on-volume mkdir lock coordinates only strict writers;
    /// an older process using a legacy writer does not participate in its CAS.
    public func provisionIdentities(
        _ requests: [VaporIdentityProvisioningRequest],
        expectedRevision: VaporIdentityVaultRevision
    ) async throws -> VaporIdentityVaultProvisioningResult {
        try requireStrictRuntimeRootIfActive()
        guard strictRuntimeDocumentRootPath == nil else {
            throw VaporIdentityVaultStrictError.strictRuntimeWriteProhibited
        }
        let documentRootURL = configuredDocumentRootURL().standardizedFileURL
        let masterKeySnapshot = try strictMasterKeySnapshot(documentRootURL: documentRootURL)
        guard expectedRevision.schema == VaporIdentityVaultRevision.schema else {
            throw VaporIdentityVaultStrictError.staleRevision
        }
        try validateStrictMetadata(
            at: documentRootURL,
            kind: .privateDirectory,
            error: .unsafeVaultMetadata
        )

        return try withStrictVaultLock(at: documentRootURL) {
            let currentVault = try strictReadVault(
                allowMissing: true,
                documentRootURL: documentRootURL,
                masterKeySnapshot: masterKeySnapshot
            )
            guard currentVault.revision == expectedRevision else {
                throw VaporIdentityVaultStrictError.staleRevision
            }
            let inspection = provisioningInspection(for: requests, parsedVault: currentVault)
            guard inspection.hasConflicts == false else {
                throw VaporIdentityVaultStrictError.provisioningConflict
            }

            let keptUUIDs = inspection.items
                .filter { $0.action == .keep }
                .map { $0.request.uuid }
            let createRequests = inspection.items
                .filter { $0.action == .create }
                .map(\.request)
            guard createRequests.isEmpty == false else {
                publishStrictVault(currentVault)
                return VaporIdentityVaultProvisioningResult(
                    previousRevision: currentVault.revision,
                    revision: currentVault.revision,
                    createdUUIDs: [],
                    keptUUIDs: keptUUIDs,
                    bindings: requestedBindingSummaries(
                        for: currentVault,
                        requests: requests
                    )
                )
            }
            guard currentVault.identities.count + createRequests.count
                    <= VaporIdentityVault.maxPersistedIdentityCount,
                  currentVault.revision.fileVersion < UInt64.max else {
                throw VaporIdentityVaultStrictError.tooManyIdentities
            }

            var nextIdentities = currentVault.identities
            for request in createRequests {
                var identity = Identity(
                    request.uuid,
                    displayName: request.displayName,
                    identityVault: self
                )
                identity.homeVaultReference = "vapor:\(documentRootURL.path)"
                var vaultIdentity = VaultIdentity(identity: &identity)
                vaultIdentity.identityContext = request.context
                try validateStrictIdentity(vaultIdentity)
                nextIdentities.append(vaultIdentity)
            }
            nextIdentities.sort {
                let leftContext = $0.identityContext ?? ""
                let rightContext = $1.identityContext ?? ""
                return leftContext == rightContext ? $0.uuid < $1.uuid : leftContext < rightContext
            }

            let nextFileVersion = currentVault.revision.fileVersion + 1
            let document = StrictPersistedVaultDocument(
                schema: VaporIdentityVault.strictVaultSchema,
                fileVersion: nextFileVersion,
                identities: try nextIdentities.map(StrictVaultIdentityRecord.init)
            )
            let plaintext: Data
            do {
                plaintext = try JSONEncoder().encode(document)
            } catch let strictError as VaporIdentityVaultStrictError {
                throw strictError
            } catch {
                throw VaporIdentityVaultStrictError.persistenceFailed
            }
            let encryptedData = try encryptVaultDataStrict(
                plaintext,
                scope: VaporIdentityVault.identitiesFileName,
                documentRootURL: documentRootURL,
                masterKeySnapshot: masterKeySnapshot
            )
            guard encryptedData.count <= Int(VaporIdentityVault.maxVaultFileBytes) else {
                throw VaporIdentityVaultStrictError.vaultTooLarge
            }
            let expectedNewRevision = VaporIdentityVaultRevision(
                fileVersion: nextFileVersion,
                fileDigest: sha256Hex(encryptedData)
            )

            try writeStrictVaultAtomically(
                encryptedData,
                expectedCurrentRevision: currentVault.revision,
                documentRootURL: documentRootURL,
                masterKeySnapshot: masterKeySnapshot
            )
            let persistedVault: StrictParsedVault
            do {
                try validateMasterKeySnapshotUnchanged(
                    masterKeySnapshot,
                    documentRootURL: documentRootURL
                )
                persistedVault = try strictReadVault(
                    allowMissing: false,
                    documentRootURL: documentRootURL,
                    masterKeySnapshot: masterKeySnapshot
                )
            } catch {
                throw VaporIdentityVaultStrictError.persistenceOutcomeUnknown
            }
            guard persistedVault.revision == expectedNewRevision,
                  persistedVault.identities.count == nextIdentities.count else {
                throw VaporIdentityVaultStrictError.persistenceOutcomeUnknown
            }
            publishStrictVault(persistedVault)
            return VaporIdentityVaultProvisioningResult(
                previousRevision: currentVault.revision,
                revision: persistedVault.revision,
                createdUUIDs: createRequests.map(\.uuid),
                keptUUIDs: keptUUIDs,
                bindings: requestedBindingSummaries(
                    for: persistedVault,
                    requests: requests
                )
            )
        }
    }

#if DEBUG
    func setStrictWriteFailureForTesting(_ enabled: Bool) {
        strictWriteFailureForTesting = enabled
    }

    func setStrictDirectorySyncFailureForTesting(_ enabled: Bool) {
        strictDirectorySyncFailureForTesting = enabled
    }

    func setStrictLockCleanupFailureForTesting(_ enabled: Bool) {
        strictLockCleanupFailureForTesting = enabled
    }

    /// Test-only escape hatch. Production builds have no API that can disable
    /// or retarget strict runtime mode after activation.
    @_spi(Testing)
    public func resetStrictRuntimeModeForTesting() {
        strictRuntimeDocumentRootPath = nil
        strictRuntimeRevision = nil
        strictRuntimeMasterKeySnapshot = nil
        strictRuntimeBackingStoreReady = false
        initialized = false
        loadedDocumentRootPath = nil
        identitiesDictionary.removeAll(keepingCapacity: true)
        visitingIdentitiesDictionary.removeAll(keepingCapacity: true)
        identitiesUUIDDictionary.removeAll(keepingCapacity: true)
        persistedFileVersion = 0
    }
#endif

    private func strictLoadResult(for parsedVault: StrictParsedVault) -> VaporIdentityVaultStrictLoadResult {
        VaporIdentityVaultStrictLoadResult(
            revision: parsedVault.revision,
            bindingCount: parsedVault.identities.count
        )
    }

    private func bindingSummaries(for parsedVault: StrictParsedVault) -> [VaporIdentityVaultBindingSummary] {
        parsedVault.identities.compactMap { vaultIdentity -> VaporIdentityVaultBindingSummary? in
            guard let context = vaultIdentity.identityContext,
                  let fingerprint = vaultIdentity.identity.signingPublicKeyFingerprint else {
                return nil
            }
            return VaporIdentityVaultBindingSummary(
                uuid: vaultIdentity.uuid,
                context: context,
                signingKeyFingerprint: fingerprint
            )
        }.sorted {
            $0.context == $1.context ? $0.uuid < $1.uuid : $0.context < $1.context
        }
    }

    private func requestedBindingSummaries(
        for parsedVault: StrictParsedVault,
        requests: [VaporIdentityProvisioningRequest]
    ) -> [VaporIdentityVaultBindingSummary] {
        let requestedBindings = Set(requests.map { "\($0.uuid)\u{0}\($0.context)" })
        return bindingSummaries(for: parsedVault).filter {
            requestedBindings.contains("\($0.uuid)\u{0}\($0.context)")
        }
    }

    private func provisioningInspection(
        for requests: [VaporIdentityProvisioningRequest],
        parsedVault: StrictParsedVault
    ) -> VaporIdentityProvisioningInspection {
        let uuidCounts = Dictionary(grouping: requests, by: \.uuid).mapValues(\.count)
        let contextCounts = Dictionary(grouping: requests, by: \.context).mapValues(\.count)
        let byUUID = Dictionary(uniqueKeysWithValues: parsedVault.identities.map { ($0.uuid, $0) })
        let byContext: [String: VaultIdentity] = Dictionary(
            uniqueKeysWithValues: parsedVault.identities.compactMap { identity -> (String, VaultIdentity)? in
                guard let context = identity.identityContext else { return nil }
                return (context, identity)
            }
        )

        let items = requests.map { request -> VaporIdentityProvisioningPlanItem in
            guard isValidIdentityField(request.uuid, maximumUTF8Length: 512),
                  isValidIdentityField(request.context, maximumUTF8Length: 1_024),
                  isValidIdentityField(request.displayName, maximumUTF8Length: 1_024) else {
                return VaporIdentityProvisioningPlanItem(
                    request: request,
                    action: .conflict,
                    reasonCode: "descriptor_invalid"
                )
            }
            if uuidCounts[request.uuid, default: 0] > 1 {
                return VaporIdentityProvisioningPlanItem(
                    request: request,
                    action: .conflict,
                    reasonCode: "batch_duplicate_uuid"
                )
            }
            if contextCounts[request.context, default: 0] > 1 {
                return VaporIdentityProvisioningPlanItem(
                    request: request,
                    action: .conflict,
                    reasonCode: "batch_duplicate_context"
                )
            }

            let existingByUUID = byUUID[request.uuid]
            let existingByContext = byContext[request.context]
            if existingByUUID?.identityContext == request.context,
               existingByContext?.uuid == request.uuid {
                return VaporIdentityProvisioningPlanItem(
                    request: request,
                    action: .keep,
                    reasonCode: "binding_exists"
                )
            }
            if existingByUUID == nil, existingByContext == nil {
                return VaporIdentityProvisioningPlanItem(
                    request: request,
                    action: .create,
                    reasonCode: "binding_missing"
                )
            }
            return VaporIdentityProvisioningPlanItem(
                request: request,
                action: .conflict,
                reasonCode: "binding_occupied"
            )
        }
        return VaporIdentityProvisioningInspection(revision: parsedVault.revision, items: items)
    }

    private func withStrictVaultLock<T>(
        at documentRootURL: URL,
        _ operation: () throws -> T
    ) throws -> T {
        let lockURL = documentRootURL
            .appendingPathComponent(VaporIdentityVault.strictLockFilename, isDirectory: false)
        var ownsLock = false
        do {
            try FileManager.default.createDirectory(
                at: lockURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            ownsLock = true
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: lockURL.path
            )
            try validateStrictMetadata(
                at: lockURL,
                kind: .privateDirectory,
                error: .lockUnavailable
            )
        } catch {
            if ownsLock {
                try? FileManager.default.removeItem(at: lockURL)
            }
            throw VaporIdentityVaultStrictError.lockUnavailable
        }
        let outcome: Result<T, Error>
        do {
            outcome = .success(try operation())
        } catch {
            outcome = .failure(error)
        }
        do {
#if DEBUG
            if strictLockCleanupFailureForTesting {
                throw VaporIdentityVaultStrictError.lockCleanupRequired
            }
#endif
            try FileManager.default.removeItem(at: lockURL)
        } catch {
            throw VaporIdentityVaultStrictError.lockCleanupRequired
        }
        return try outcome.get()
    }

    private func writeStrictVaultAtomically(
        _ encryptedData: Data,
        expectedCurrentRevision: VaporIdentityVaultRevision,
        documentRootURL: URL,
        masterKeySnapshot: StrictMasterKeySnapshot
    ) throws {
        guard encryptedData.count <= Int(VaporIdentityVault.maxVaultFileBytes) else {
            throw VaporIdentityVaultStrictError.vaultTooLarge
        }
        let currentBeforeWrite = try strictReadVault(
            allowMissing: true,
            documentRootURL: documentRootURL,
            masterKeySnapshot: masterKeySnapshot
        )
        guard currentBeforeWrite.revision == expectedCurrentRevision else {
            throw VaporIdentityVaultStrictError.staleRevision
        }

        let directoryURL = documentRootURL
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(VaporIdentityVault.identitiesFileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor: Int32
#if canImport(Darwin)
        descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
#elseif canImport(Glibc)
        descriptor = Glibc.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
#else
        descriptor = -1
#endif
        guard descriptor >= 0 else {
            throw VaporIdentityVaultStrictError.persistenceFailed
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        var didRename = false
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
#if DEBUG
            if strictWriteFailureForTesting {
                throw VaporIdentityVaultStrictError.persistenceFailed
            }
#endif
            try handle.write(contentsOf: encryptedData)
            try handle.synchronize()
            try handle.close()
            try validateStrictMetadata(
                at: temporaryURL,
                kind: .regular0600,
                error: .persistenceFailed
            )

            let currentBeforeRename = try strictReadVault(
                allowMissing: true,
                documentRootURL: documentRootURL,
                masterKeySnapshot: masterKeySnapshot
            )
            guard currentBeforeRename.revision == expectedCurrentRevision else {
                throw VaporIdentityVaultStrictError.staleRevision
            }
            try validateMasterKeySnapshotUnchanged(
                masterKeySnapshot,
                documentRootURL: documentRootURL
            )
#if canImport(Darwin)
            let renameStatus = Darwin.rename(
                temporaryURL.path,
                documentRootURL.appendingPathComponent(VaporIdentityVault.identitiesFileName).path
            )
#elseif canImport(Glibc)
            let renameStatus = Glibc.rename(
                temporaryURL.path,
                documentRootURL.appendingPathComponent(VaporIdentityVault.identitiesFileName).path
            )
#else
            let renameStatus = -1
#endif
            guard renameStatus == 0 else {
                throw VaporIdentityVaultStrictError.persistenceFailed
            }
            didRename = true
            shouldRemoveTemporaryFile = false
            try synchronizeStrictDirectory(directoryURL)
        } catch let strictError as VaporIdentityVaultStrictError {
            if didRename {
                throw VaporIdentityVaultStrictError.persistenceOutcomeUnknown
            }
            throw strictError
        } catch {
            if didRename {
                throw VaporIdentityVaultStrictError.persistenceOutcomeUnknown
            }
            throw VaporIdentityVaultStrictError.persistenceFailed
        }
    }

    private func validateMasterKeySnapshotUnchanged(
        _ expected: StrictMasterKeySnapshot,
        documentRootURL: URL
    ) throws {
        let current = try strictMasterKeySnapshot(documentRootURL: documentRootURL)
        guard expected.hasSameSourceAndContent(as: current) else {
            throw VaporIdentityVaultStrictError.strictMasterKeyChanged
        }
    }

    private func synchronizeStrictDirectory(_ directoryURL: URL) throws {
        let descriptor: Int32
#if canImport(Darwin)
        descriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
#elseif canImport(Glibc)
        descriptor = Glibc.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
#else
        descriptor = -1
#endif
        guard descriptor >= 0 else {
            throw VaporIdentityVaultStrictError.persistenceFailed
        }
        defer {
#if canImport(Darwin)
            _ = Darwin.close(descriptor)
#elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
#endif
        }
#if DEBUG
        if strictDirectorySyncFailureForTesting {
            throw VaporIdentityVaultStrictError.persistenceFailed
        }
#endif
#if canImport(Darwin)
        guard Darwin.fsync(descriptor) == 0 else {
            throw VaporIdentityVaultStrictError.persistenceFailed
        }
#elseif canImport(Glibc)
        guard Glibc.fsync(descriptor) == 0 else {
            throw VaporIdentityVaultStrictError.persistenceFailed
        }
#else
        throw VaporIdentityVaultStrictError.persistenceFailed
#endif
    }

    private func hasSigningKeyMaterial(_ vaultIdentity: VaultIdentity) -> Bool {
        guard
            vaultIdentity.publicKey.isEmpty == false,
            vaultIdentity.privateKey.isEmpty == false,
            let publicKey = vaultIdentity.publicSecureKey?.compressedKey,
            publicKey.isEmpty == false,
            let privateKey = vaultIdentity.privateSecureKey?.compressedKey,
            privateKey.isEmpty == false
        else {
            return false
        }
        return true
    }

    private func repairedKeyMetadataIfPossible(_ vaultIdentity: VaultIdentity) -> VaultIdentity {
        guard vaultIdentity.publicKey.isEmpty == false, vaultIdentity.privateKey.isEmpty == false else {
            return vaultIdentity
        }

        var repaired = vaultIdentity
        if repaired.publicSecureKey?.compressedKey?.isEmpty != false {
            repaired.publicSecureKey = SecureKey(
                date: Date(),
                privateKey: false,
                use: .signature,
                algorithm: .EdDSA,
                size: 256,
                curveType: .Curve25519,
                x: nil,
                y: nil,
                compressedKey: repaired.publicKey
            )
        }
        if repaired.privateSecureKey?.compressedKey?.isEmpty != false {
            repaired.privateSecureKey = SecureKey(
                date: Date(),
                privateKey: true,
                use: .signature,
                algorithm: .EdDSA,
                size: 256,
                curveType: .Curve25519,
                x: nil,
                y: nil,
                compressedKey: repaired.privateKey
            )
        }
        if repaired.keyAgreementPublicKey.isEmpty == false,
           repaired.publicKeyAgreementSecureKey?.compressedKey?.isEmpty != false {
            repaired.publicKeyAgreementSecureKey = SecureKey(
                date: Date(),
                privateKey: false,
                use: .keyAgreement,
                algorithm: .X25519,
                size: 256,
                curveType: .Curve25519,
                x: nil,
                y: nil,
                compressedKey: repaired.keyAgreementPublicKey
            )
        }
        if repaired.keyAgreementPrivateKey.isEmpty == false,
           repaired.privateKeyAgreementSecureKey?.compressedKey?.isEmpty != false {
            repaired.privateKeyAgreementSecureKey = SecureKey(
                date: Date(),
                privateKey: true,
                use: .keyAgreement,
                algorithm: .X25519,
                size: 256,
                curveType: .Curve25519,
                x: nil,
                y: nil,
                compressedKey: repaired.keyAgreementPrivateKey
            )
        }
        return repaired
    }

    @discardableResult
    private func healedVaultIdentityIfNeeded(
        _ vaultIdentity: VaultIdentity,
        saveAfterHealing: Bool = true
    ) -> VaultIdentity {
        // Strict activation proves complete key material up front. Any later
        // repair/regeneration would silently replace authority, so even an
        // accidental legacy call must remain read-only.
        guard strictRuntimeDocumentRootPath == nil else {
            return vaultIdentity
        }
        guard hasSigningKeyMaterial(vaultIdentity) == false else {
            return vaultIdentity
        }

        let repairedVaultIdentity = repairedKeyMetadataIfPossible(vaultIdentity)
        if hasSigningKeyMaterial(repairedVaultIdentity) {
            identitiesUUIDDictionary[repairedVaultIdentity.uuid] = repairedVaultIdentity
            if let identityContext = repairedVaultIdentity.identityContext {
                identitiesDictionary[identityContext] = repairedVaultIdentity.uuid
            }
            if saveAfterHealing {
                saveIdentities()
            }
            return repairedVaultIdentity
        }

        var regeneratedIdentity = Identity(
            vaultIdentity.uuid,
            displayName: vaultIdentity.displayName,
            identityVault: self
        )
        regeneratedIdentity.properties = vaultIdentity.properties
        regeneratedIdentity.grants = vaultIdentity.grants

        var healedVaultIdentity = VaultIdentity(identity: &regeneratedIdentity)
        healedVaultIdentity.identityContext = vaultIdentity.identityContext
        healedVaultIdentity.privateProperties = vaultIdentity.privateProperties

        identitiesUUIDDictionary[healedVaultIdentity.uuid] = healedVaultIdentity
        if let identityContext = healedVaultIdentity.identityContext {
            identitiesDictionary[identityContext] = healedVaultIdentity.uuid
        }
        if saveAfterHealing {
            saveIdentities()
        }
        return healedVaultIdentity
    }
    
    public func identity(for identityContext: String, makeNewIfNotFound: Bool = true) async -> Identity? {
        guard await ensureInitializedForCurrentDocumentRoot() else {
            return nil
        }
        if let targetUUid = identitiesDictionary[identityContext] {
            if let currentVaultIdentity =  identitiesUUIDDictionary[targetUUid] {
                let healedVaultIdentity = strictRuntimeDocumentRootPath == nil
                    ? healedVaultIdentityIfNeeded(currentVaultIdentity)
                    : currentVaultIdentity
                // Testing / Playing
                let identity = healedVaultIdentity.identity
                identity.identityVault = self
                identity.homeVaultReference = currentVaultReference()
                return identity
            }
        }
        guard strictRuntimeDocumentRootPath == nil else {
            if makeNewIfNotFound {
                logStrictRuntimeRejection(.strictRuntimeWriteProhibited)
            }
            return nil
        }
        if makeNewIfNotFound {
           var identity = Identity()
           identity.identityVault = self
           identity.homeVaultReference = currentVaultReference()
           await addIdentity(identity: &identity, for: identityContext) // TODO: behaviour will be different than expected, see ActorBasicTests.swift in renderer project for examples
           return identity
       }
        return nil
    }
    
    public func addIdentity(identity: inout Identity, for identityContext: String) async {
        guard await ensureInitializedForCurrentDocumentRoot() else {
            return
        }
        if identity.uuid == identityContext { // visiting identities will have same uuid as identityContext
            visitingIdentitiesDictionary[identity.uuid] = identity // Evaluate whether this should use reference counting
            CellBase.diagnosticLog("VaporIdentityVault added visitor identity uuid=\(identity.uuid)", domain: .identity)
        } else {
            guard strictRuntimeDocumentRootPath == nil else {
                logStrictRuntimeRejection(.strictRuntimeWriteProhibited)
                return
            }
            
            identity.identityVault = self
            identity.homeVaultReference = currentVaultReference()
            if let targetUUid = identitiesDictionary[identityContext] {
                if targetUUid == identity.uuid, var vaultIdentity = identitiesUUIDDictionary[targetUUid] {
                    vaultIdentity = healedVaultIdentityIfNeeded(vaultIdentity, saveAfterHealing: false)
                    vaultIdentity.update(with: identity)
                    vaultIdentity.identityContext = identityContext
                    identitiesUUIDDictionary[targetUUid] = vaultIdentity
                    identity.publicSecureKey = vaultIdentity.publicSecureKey
                    identity.publicKeyAgreementSecureKey = vaultIdentity.publicKeyAgreementSecureKey
                } else if var existingVaultIdentity = identitiesUUIDDictionary[identity.uuid] {
                    existingVaultIdentity = healedVaultIdentityIfNeeded(existingVaultIdentity, saveAfterHealing: false)
                    existingVaultIdentity.update(with: identity)
                    existingVaultIdentity.identityContext = identityContext
                    rebindIdentityContexts(from: targetUUid, to: identity.uuid)
                    identitiesUUIDDictionary[identity.uuid] = existingVaultIdentity
                    identitiesUUIDDictionary.removeValue(forKey: targetUUid)
                    identity.publicSecureKey = existingVaultIdentity.publicSecureKey
                    identity.publicKeyAgreementSecureKey = existingVaultIdentity.publicKeyAgreementSecureKey
                } else if var reboundVaultIdentity = identitiesUUIDDictionary.removeValue(forKey: targetUUid) {
                    reboundVaultIdentity = healedVaultIdentityIfNeeded(reboundVaultIdentity, saveAfterHealing: false)
                    reboundVaultIdentity.uuid = identity.uuid
                    if identity.displayName.isEmpty == false {
                        reboundVaultIdentity.displayName = identity.displayName
                    }
                    reboundVaultIdentity.identityContext = identityContext
                    rebindIdentityContexts(from: targetUUid, to: identity.uuid)
                    identitiesUUIDDictionary[identity.uuid] = reboundVaultIdentity
                    identity.publicSecureKey = reboundVaultIdentity.publicSecureKey
                    identity.publicKeyAgreementSecureKey = reboundVaultIdentity.publicKeyAgreementSecureKey
                } else {
                    var vaultIdentity = VaultIdentity(identity: &identity)
                    vaultIdentity.identityContext = identityContext
                    rebindIdentityContexts(from: targetUUid, to: identity.uuid)
                    identitiesUUIDDictionary[identity.uuid] = vaultIdentity
                }
            } else {
                var vaultIdentity = VaultIdentity(identity: &identity)
                vaultIdentity.identityContext = identityContext
                self.identitiesDictionary[identityContext] = identity.uuid // ????
                self.identitiesUUIDDictionary[identity.uuid] = vaultIdentity // Also add with uuid for uuid lookups
                
            }
            saveIdentities()
        }
    }

    private func rebindIdentityContexts(from previousUUID: String, to newUUID: String) {
        for (context, mappedUUID) in identitiesDictionary where mappedUUID == previousUUID {
            identitiesDictionary[context] = newUUID
        }
    }
    
    public func addVisitingIdentity(identity: Identity) async {
        guard await ensureInitializedForCurrentDocumentRoot() else {
            return
        }
        visitingIdentitiesDictionary[identity.uuid] = identity // Evaluate whether this should use reference counting
        CellBase.diagnosticLog("VaporIdentityVault added visitor identity uuid=\(identity.uuid)", domain: .identity)
    }

    func addVisitingIdentity(snapshot: VaporBridgeIdentitySnapshot) async {
        guard await ensureInitializedForCurrentDocumentRoot() else {
            return
        }
        let identity = snapshot.makeIdentity()
        visitingIdentitiesDictionary[identity.uuid] = identity // Evaluate whether this should use reference counting
        CellBase.diagnosticLog("Visiting identity \(identity.uuid) added to Vapor vault", domain: .bridge)
    }
    
    public func getIdentity(by uuid: String) async -> Identity? {
        guard await ensureInitializedForCurrentDocumentRoot() else {
            return nil
        }
        var identity = visitingIdentitiesDictionary[uuid]
        
        if identity == nil {
            if let currentVaultIdentity =  identitiesUUIDDictionary[uuid] {
                let healedVaultIdentity = strictRuntimeDocumentRootPath == nil
                    ? healedVaultIdentityIfNeeded(currentVaultIdentity)
                    : currentVaultIdentity
                // Testing / Playing
                identity = healedVaultIdentity.identity
                identity?.identityVault = self
                identity?.homeVaultReference = currentVaultReference()
            }
        }
        return identity
    }

    /// Restores an identity that is already persisted in this vault by its
    /// exact UUID. Unlike the legacy context lookup, this path is intentionally
    /// fail-closed: it never accepts a visiting identity and never repairs or
    /// regenerates missing signing material.
    public func identity(forUUID uuid: String) async -> Identity? {
        guard await ensureInitializedForCurrentDocumentRoot() else {
            return nil
        }
        guard let vaultIdentity = identitiesUUIDDictionary[uuid],
              vaultIdentity.uuid == uuid,
              hasSigningKeyMaterial(vaultIdentity) else {
            return nil
        }
        let identity = vaultIdentity.identity
        guard identity.uuid == uuid else {
            return nil
        }
        identity.identityVault = self
        identity.homeVaultReference = currentVaultReference()
        return identity
    }

    func saveIdentities() {
        guard strictRuntimeDocumentRootPath == nil else {
            logStrictRuntimeRejection(.strictRuntimeWriteProhibited)
            return
        }
        let identities = Array(identitiesUUIDDictionary.values).sorted {
            let leftContext = $0.identityContext ?? ""
            let rightContext = $1.identityContext ?? ""
            return leftContext == rightContext ? $0.uuid < $1.uuid : leftContext < rightContext
        }

        do {
            let nextVersion = persistedFileVersion == UInt64.max ? UInt64.max : persistedFileVersion + 1
            let document = StrictPersistedVaultDocument(
                schema: VaporIdentityVault.strictVaultSchema,
                fileVersion: nextVersion,
                identities: try identities.map(StrictVaultIdentityRecord.init)
            )
            let serializedIdentites = try JSONEncoder().encode(document)
            try saveIdentities(jsonData: serializedIdentites)
            persistedFileVersion = nextVersion
        } catch {
            CellBase.diagnosticLog("VaporIdentityVault failed to save identities: \(error)", domain: .identity)
        }
    }
    
    func saveIdentities(jsonData: Data) throws {
        guard strictRuntimeDocumentRootPath == nil else {
            throw VaporIdentityVaultStrictError.strictRuntimeWriteProhibited
        }
        try ensureVaultDirectoryExists()
        let encryptedData = try encryptVaultData(jsonData, scope: VaporIdentityVault.identitiesFileName)
        let encryptedFileUrl = vaultFileURL()
        try encryptedData.write(to: encryptedFileUrl, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: encryptedFileUrl.path
        )
    }
    
    public func saveIdentity(_ identity: Identity) async {
        guard await ensureInitializedForCurrentDocumentRoot() else {
            return
        }
        guard strictRuntimeDocumentRootPath == nil else {
            logStrictRuntimeRejection(.strictRuntimeWriteProhibited)
            return
        }
        if var vaultIdentity = vaultIdentityWithUUID(identity.uuid) {
            vaultIdentity.update(with: identity)
            identitiesUUIDDictionary[identity.uuid] = vaultIdentity
        }
    }
    
    func loadIdentities() async -> [VaultIdentity]? {
        guard strictRuntimeDocumentRootPath == nil else {
            logStrictRuntimeRejection(.strictRuntimeWriteProhibited)
            return nil
        }
        do {
            let encryptedFileURL = vaultFileURL()
            guard FileManager.default.fileExists(atPath: encryptedFileURL.path) else {
                saveIdentities()
                return []
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: encryptedFileURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            if fileSize > VaporIdentityVault.maxVaultFileBytes {
                throw StorageError.vaultFileTooLarge(
                    bytes: fileSize,
                    maxBytes: VaporIdentityVault.maxVaultFileBytes
                )
            }

            let encryptedData = try Data(contentsOf: encryptedFileURL, options: [.uncached])
            let decryptedResult = try decryptVaultData(encryptedData, scope: VaporIdentityVault.identitiesFileName)
            let decryptedData = decryptedResult.payload
//            print("encryptedFileUrl: \(encryptedFileUrl)")
//            
//                print("Decrypted data as string: \(String(describing: String(data: decryptedData, encoding: .utf8)))")
            
            
            
            //    let contents = try String(contentsOf: fileUrl!, encoding: String.Encoding.utf8)
            //        print("\(contents)")
//            let decoder = JSONDecoder()
//            decoder.userInfo[.facilitator] = Facilitator()
            
            
            let decoder = JSONDecoder()
            let decryptedIdentities: [VaultIdentity]
            if let document = try? decoder.decode(StrictPersistedVaultDocument.self, from: decryptedData) {
                guard document.schema == VaporIdentityVault.strictVaultSchema,
                      document.fileVersion > 0 else {
                    throw VaporIdentityVaultStrictError.unsupportedVaultSchema
                }
                persistedFileVersion = document.fileVersion
                decryptedIdentities = document.identities.map(\.vaultIdentity)
            } else {
                persistedFileVersion = 0
                decryptedIdentities = try decoder.decode([VaultIdentity].self, from: decryptedData)
            }
            if decryptedIdentities.count > VaporIdentityVault.maxPersistedIdentityCount {
                throw StorageError.tooManyPersistedIdentities(
                    count: decryptedIdentities.count,
                    maxCount: VaporIdentityVault.maxPersistedIdentityCount
                )
            }
            if decryptedResult.needsMigration {
                try? saveIdentities(jsonData: decryptedData)
            }
            return decryptedIdentities
        } catch {
            CellBase.diagnosticLog("VaporIdentityVault failed to load identities: \(error)", domain: .identity)
            return nil
        }
    }
    
    // This may have to change - should we just check on identityContext?
    public func identityExistInVault(_ identity: Identity) async -> Bool {
        guard await ensureInitializedForCurrentDocumentRoot() else {
            return false
        }
        guard let vaultIdentity = identitiesUUIDDictionary[identity.uuid] else {
            return false
        }
        return signingPublicKeyMatches(requested: identity, stored: vaultIdentity.identity)
    }

    public func identityDomainBinding(for identity: Identity) async -> IdentityDomainBinding? {
        guard await ensureInitializedForCurrentDocumentRoot() else {
            return nil
        }
        guard let vaultIdentity = identitiesUUIDDictionary[identity.uuid],
              signingPublicKeyMatches(requested: identity, stored: vaultIdentity.identity),
              let identityContext = vaultIdentity.identityContext?.trimmingCharacters(in: .whitespacesAndNewlines),
              identityContext.isEmpty == false else {
            return nil
        }
        if let expectedVault = identity.homeVaultReference,
           expectedVault != currentVaultReference() {
            return nil
        }
        return IdentityDomainBinding(domain: identityContext, identity: identity)
    }

    func identityExistsInVault(uuid: String) async -> Bool {
        guard await ensureInitializedForCurrentDocumentRoot() else {
            return false
        }
        return identitiesUUIDDictionary[uuid] != nil
    }
    
    public func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        guard await ensureInitializedForCurrentDocumentRoot() else {
            throw strictRuntimeAccessError() ?? VaporIdentityVaultStrictError.strictRuntimeRootDrift
        }

        if let expectedVault = identity.homeVaultReference,
           expectedVault != currentVaultReference() {
            throw IdentityVaultError.wrongVault
        }
        guard let vaultIdentity = self.vaultIdentityWithUUID(identity.uuid) else {
            CellBase.diagnosticLog("VaporIdentityVault missing identity uuid=\(identity.uuid)", domain: .identity)
            throw IdentityVaultError.noVaultIdentity
        }
        guard signingPublicKeyMatches(requested: identity, stored: vaultIdentity.identity) else {
            throw IdentityVaultError.signingFailed
        }
        let signatureData = try self.signMessageForVaultIdentity(messageData: messageData, vaultIdentity: vaultIdentity)
        return signatureData
    }

    private func signingPublicKeyMatches(requested: Identity, stored: Identity) -> Bool {
        guard
            let requestedFingerprint = requested.signingPublicKeyFingerprint,
            let storedFingerprint = stored.signingPublicKeyFingerprint
        else {
            return false
        }
        return requestedFingerprint == storedFingerprint
    }
    
    
    
    public func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        var valid = false
        if let publicSecureKey = identity.publicSecureKey {
            switch publicSecureKey.curveType {
            case .Curve25519:
//                print("About to verify signature with Curve25519")
                if let compressedKey = publicSecureKey.compressedKey {
                    let key = try Curve25519.Signing.PublicKey(rawRepresentation: compressedKey)
                    valid = key.isValidSignature(signature, for: messageData)
                } else {
                    CellBase.diagnosticLog("VaporIdentityVault missing compressed public key", domain: .identity)
                }
            case .secp256k1, .P256:
                CellBase.diagnosticLog("VaporIdentityVault verifying ECDSA P-256-compatible signature", domain: .identity)
                if let compressedKey = publicSecureKey.compressedKey,
                   let publicKey = try? P256.Signing.PublicKey(x963Representation: compressedKey),
                   let ecdsaSignature = try? P256.Signing.ECDSASignature(derRepresentation: signature) {
                    if publicKey.isValidSignature(ecdsaSignature, for: messageData) {
                        return true
                    }
                }
            }
            
        } else {
            CellBase.diagnosticLog("VaporIdentityVault missing public secure key", domain: .identity)
        }
        return valid
    }

    public func publicSecureKey(for identity: Identity, role: IdentityKeyRole) async throws -> SecureKey? {
        switch role {
        case .signing:
            return identity.publicSecureKey
        case .keyAgreement:
            return identity.publicKeyAgreementSecureKey
        }
    }

    public func privateKeyData(for identity: Identity, role: IdentityKeyRole) async throws -> Data? {
        guard await ensureInitializedForCurrentDocumentRoot() else {
            throw strictRuntimeAccessError() ?? VaporIdentityVaultStrictError.strictRuntimeRootDrift
        }
        guard let vaultIdentity = vaultIdentityWithUUID(identity.uuid),
              signingPublicKeyMatches(requested: identity, stored: vaultIdentity.identity) else {
            return nil
        }

        switch role {
        case .signing:
            return vaultIdentity.privateSecureKey?.compressedKey ?? vaultIdentity.privateKey
        case .keyAgreement:
            return vaultIdentity.privateKeyAgreementSecureKey?.compressedKey ?? vaultIdentity.keyAgreementPrivateKey
        }
    }
    
    public func randomBytes64() async -> Data? {
        return try? SecureRandom.data(count: 64)
    }
    
    private func vaultIdentityWithUUID(_ uuid: String) -> VaultIdentity? {
        if let currentVaultIdentity = identitiesUUIDDictionary[uuid] {
            return currentVaultIdentity
        }
        return nil
    }
    
    func signMessageForVaultIdentity(messageData: Data, vaultIdentity: VaultIdentity) throws -> Data {
        var signature: Data
        if let privateSecureKey = vaultIdentity.privateSecureKey {
            switch privateSecureKey.curveType {
            case .Curve25519:
//                print("About to sign with Curve25519")
                if let compressedKey = privateSecureKey.compressedKey {
                    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: compressedKey)
                    signature = try key.signature(for: messageData)
                } else {
                    CellBase.diagnosticLog("VaporIdentityVault missing compressed private key", domain: .identity)
                    throw IdentityVaultError.noKey
                }
            case .secp256k1, .P256:
//                print("About to sign with secp256k1")
                throw IdentityVaultError.notImplemented
            }
            
        } else {
            throw IdentityVaultError.noKey
        }
        return signature
        
    }
    
    struct VaultIdentity: Codable {
        var uuid: String
        var displayName: String
        
        var identityContext: String?
    //    var services: [Service]?
        var grants = [Grant]()
        
        var publicKey: Data
        var privateKey: Data
        var keyAgreementPublicKey: Data
        var keyAgreementPrivateKey: Data

        var publicSecureKey: SecureKey?
        var privateSecureKey: SecureKey?
        var publicKeyAgreementSecureKey: SecureKey?
        var privateKeyAgreementSecureKey: SecureKey?
        
        var properties: [String: ValueType]?
        var privateProperties: [String: ValueType]?
        
        var identity: Identity {
            get {
                let newIdentity = Identity(self.uuid, displayName: self.displayName, identityVault: nil)
                
                newIdentity.properties = self.properties
                newIdentity.publicSecureKey = self.publicSecureKey ?? {
                    guard self.publicKey.isEmpty == false else { return nil }
                    return SecureKey(
                        date: Date(),
                        privateKey: false,
                        use: .signature,
                        algorithm: .EdDSA,
                        size: 256,
                        curveType: .Curve25519,
                        x: nil,
                        y: nil,
                        compressedKey: self.publicKey
                    )
                }()
                newIdentity.publicKeyAgreementSecureKey = self.publicKeyAgreementSecureKey ?? {
                    guard self.keyAgreementPublicKey.isEmpty == false else { return nil }
                    return SecureKey(
                        date: Date(),
                        privateKey: false,
                        use: .keyAgreement,
                        algorithm: .X25519,
                        size: 256,
                        curveType: .Curve25519,
                        x: nil,
                        y: nil,
                        compressedKey: self.keyAgreementPublicKey
                    )
                }()
                return newIdentity
            }
        }
        
        public static func ==(lhs: VaultIdentity, rhs: VaultIdentity) -> Bool {
            return (lhs.uuid == rhs.uuid)
        }
        //    var serviceProxys: [ProxyUuid]?
        /*
         "services" : [
         { "uuid" : "some service uuid" }
         ]
         */
        
        enum CodingKeys: String, CodingKey
        {
            case uuid
            case displayName
            case identityContext
            case publicKey
            case privateKey
            case keyAgreementPublicKey
            case keyAgreementPrivateKey
            case privateSecureKey
            case publicSecureKey
            case publicKeyAgreementSecureKey
            case privateKeyAgreementSecureKey
            case properties
            case privateProperties
        }
        
        init() {
            self.uuid = UUID().uuidString
            self.displayName = self.uuid
            
            if self.properties == nil {
                self.properties = [String: ValueType]()
            }

            grants.append(Grant(keypath: "identity.displayName", permission: "r---")) // For testing - later check policies
            
            publicKey = Data()
            privateKey = Data()
            keyAgreementPublicKey = Data()
            keyAgreementPrivateKey = Data()
        }
        
        init(uuid: String, displayName: String) {
            self.uuid = uuid
            self.displayName = displayName
            
            if self.properties == nil {
                self.properties = [String: ValueType]()
            }
            grants.append(Grant(nil, keypath: "identity.displayName", permission: "r---"))
            
            let privateCryptoKitKey = Curve25519.Signing.PrivateKey()
            privateKey = privateCryptoKitKey.rawRepresentation
            publicKey = privateCryptoKitKey.publicKey.rawRepresentation
            let keyAgreementKey = Curve25519.KeyAgreement.PrivateKey()
            keyAgreementPrivateKey = keyAgreementKey.rawRepresentation
            keyAgreementPublicKey = keyAgreementKey.publicKey.rawRepresentation
           
            
            self.publicSecureKey = SecureKey(date: Date(), privateKey: false, use: .signature, algorithm: .EdDSA, size: 256, curveType: .Curve25519, x: nil, y: nil, compressedKey: publicKey)
            self.privateSecureKey = SecureKey(date: Date(), privateKey: true, use: .signature, algorithm: .EdDSA, size: 256, curveType: .Curve25519, x: nil, y: nil, compressedKey: privateKey)
            self.publicKeyAgreementSecureKey = SecureKey(date: Date(), privateKey: false, use: .keyAgreement, algorithm: .X25519, size: 256, curveType: .Curve25519, x: nil, y: nil, compressedKey: keyAgreementPublicKey)
            self.privateKeyAgreementSecureKey = SecureKey(date: Date(), privateKey: true, use: .keyAgreement, algorithm: .X25519, size: 256, curveType: .Curve25519, x: nil, y: nil, compressedKey: keyAgreementPrivateKey)
            
        }
        
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            //        print("Decoder.userinfo: \(decoder.userInfo)")
            if values.contains(.uuid) {
                if let suppliedUuid = try? values.decode(String.self, forKey: .uuid) {
                    uuid = suppliedUuid
                } else {
                    uuid = UUID.init().uuidString
                }
            } else {
                uuid = UUID.init().uuidString
            }
            displayName  = try values.decode(String.self, forKey: .displayName)
            
            if values.contains(.identityContext) {
                identityContext  = try? values.decode(String.self, forKey: .identityContext)
            }
            do {
                if let tmpPublicKey  = try values.decodeIfPresent(Data.self, forKey: .publicKey) {
                    publicKey = tmpPublicKey
                } else {
                    publicKey = Data()
                }
                if let tmpPrivateKey = try values.decodeIfPresent(Data.self, forKey: .privateKey) {
                    privateKey  = tmpPrivateKey
                } else {
                    privateKey = Data()
                }
                if let tmpKeyAgreementPublicKey = try values.decodeIfPresent(Data.self, forKey: .keyAgreementPublicKey) {
                    keyAgreementPublicKey = tmpKeyAgreementPublicKey
                } else {
                    keyAgreementPublicKey = Data()
                }
                if let tmpKeyAgreementPrivateKey = try values.decodeIfPresent(Data.self, forKey: .keyAgreementPrivateKey) {
                    keyAgreementPrivateKey = tmpKeyAgreementPrivateKey
                } else {
                    keyAgreementPrivateKey = Data()
                }
            } catch {
                publicKey = Data()
                privateKey = Data()
                keyAgreementPublicKey = Data()
                keyAgreementPrivateKey = Data()
            }
            privateSecureKey = try values.decodeIfPresent(SecureKey.self, forKey: .privateSecureKey)
            publicSecureKey = try values.decodeIfPresent(SecureKey.self, forKey: .publicSecureKey)
            privateKeyAgreementSecureKey = try values.decodeIfPresent(SecureKey.self, forKey: .privateKeyAgreementSecureKey)
            publicKeyAgreementSecureKey = try values.decodeIfPresent(SecureKey.self, forKey: .publicKeyAgreementSecureKey)
            
    //            if let propertiesContainer = try? values.decodeIfPresent(DynamicProperties.self, forKey: .properties) {
    //                self.properties = propertiesContainer.propertyValues
    //            }
            self.properties = try? values.decodeIfPresent(Object.self, forKey: .properties)
            
            if self.properties == nil {
                self.properties = [String: ValueType]()
            }
            
            grants.append(Grant(keypath: "displayName", permission: "r---"))
        }
        
        init(identity: inout Identity) {
            CellBase.diagnosticLog("VaporIdentityVault generating persisted identity uuid=\(identity.uuid)", domain: .identity)
            self.uuid = identity.uuid
            self.displayName = identity.displayName
            self.properties = identity.properties
            self.grants = identity.grants
//            do {
//                let keys = try createKeyPairForDomainv2(domainString: uuid)
//                publicKey = keys.publicKey
//                privateKey = keys.privateKey
            let privateCryptoKitKey = Curve25519.Signing.PrivateKey()
            privateKey = privateCryptoKitKey.rawRepresentation
            publicKey = privateCryptoKitKey.publicKey.rawRepresentation
            let keyAgreementKey = Curve25519.KeyAgreement.PrivateKey()
            keyAgreementPrivateKey = keyAgreementKey.rawRepresentation
            keyAgreementPublicKey = keyAgreementKey.publicKey.rawRepresentation
            
            self.publicSecureKey = SecureKey(date: Date(), privateKey: false, use: .signature, algorithm: .EdDSA, size: 256, curveType: .Curve25519, x: nil, y: nil, compressedKey: publicKey)
            self.privateSecureKey = SecureKey(date: Date(), privateKey: true, use: .signature, algorithm: .EdDSA, size: 256, curveType: .Curve25519, x: nil, y: nil, compressedKey: privateKey)
            self.publicKeyAgreementSecureKey = SecureKey(date: Date(), privateKey: false, use: .keyAgreement, algorithm: .X25519, size: 256, curveType: .Curve25519, x: nil, y: nil, compressedKey: keyAgreementPublicKey)
            self.privateKeyAgreementSecureKey = SecureKey(date: Date(), privateKey: true, use: .keyAgreement, algorithm: .X25519, size: 256, curveType: .Curve25519, x: nil, y: nil, compressedKey: keyAgreementPrivateKey)
           
//            } catch {
//                print("Key generation failed")
//                publicKey = Data()
//                privateKey = Data()
//            }
//            identity.publicKey = publicKey // This may be a little dirty
            identity.publicSecureKey = publicSecureKey
            identity.publicKeyAgreementSecureKey = publicKeyAgreementSecureKey
        }
        
        public func encode(to encoder: Encoder) throws {
            //        print("encoding: \(self)")
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(uuid, forKey: .uuid)
            try container.encodeIfPresent(displayName, forKey: .displayName)
            try container.encodeIfPresent(identityContext, forKey: .identityContext)
            try container.encodeIfPresent(privateKey, forKey: .privateKey)
            try container.encodeIfPresent(publicKey, forKey: .publicKey)
            try container.encodeIfPresent(keyAgreementPrivateKey, forKey: .keyAgreementPrivateKey)
            try container.encodeIfPresent(keyAgreementPublicKey, forKey: .keyAgreementPublicKey)
            try container.encodeIfPresent(properties, forKey: .properties)
            try container.encodeIfPresent(publicSecureKey, forKey: .publicSecureKey)
            try container.encodeIfPresent(privateSecureKey, forKey: .privateSecureKey)
            try container.encodeIfPresent(publicKeyAgreementSecureKey, forKey: .publicKeyAgreementSecureKey)
            try container.encodeIfPresent(privateKeyAgreementSecureKey, forKey: .privateKeyAgreementSecureKey)
            // then ecode other aspects of Identity
        }
        
        func granted(_ grant: Grant) -> Bool {
            // auto grant displaynames should be governed by policies (local)
            return grants.contains(grant)
        }
        
        mutating func addGrant(_ grant: Grant) {
            if !grants.contains(grant) && !(grant.keypath.contains("privateKey") ) {
                grants.append(grant)
            }
            
        }
        
        mutating func removeGrant(_ grant: Grant) {
            grants.removeAll {
                $0 == grant
            }
        }
        
        mutating func update(with identity: Identity) {
            if self.uuid == identity.uuid {
                self.uuid = identity.uuid
                self.displayName = identity.displayName
                self.properties = identity.properties
                self.grants = identity.grants // this will probably be removed
                if let publicSecureKey = identity.publicSecureKey {
                    self.publicSecureKey = publicSecureKey
                    if let compressedKey = publicSecureKey.compressedKey, compressedKey.isEmpty == false {
                        self.publicKey = compressedKey
                    }
                }
                if let publicKeyAgreementSecureKey = identity.publicKeyAgreementSecureKey {
                    self.publicKeyAgreementSecureKey = publicKeyAgreementSecureKey
                    if let compressedKey = publicKeyAgreementSecureKey.compressedKey, compressedKey.isEmpty == false {
                        self.keyAgreementPublicKey = compressedKey
                    }
                }
            }
        }
        
        func valueForKey(key: String, requester: VaultIdentity) -> AnyPublisher<Codable, Error> {
            guard requester == self, let value = self.properties?[key] else {
                // Preserve legacy behavior: unauthorized or missing values stay silent.
                return Empty<Codable, Error>(completeImmediately: false).eraseToAnyPublisher()
            }

            return Just(value as Codable)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        mutating func addProperty(property: ValueType, for key: String) {
            self.properties![key] = property
        }
        
        
        // Not meaningful for VaultIdentity?
        mutating func setValueForKey(key: String, value valuePublisher: AnyPublisher<ValueType, Never>, requester: Identity) {
            CellBase.diagnosticLog("VaporIdentityVault setting value for key=\(key)", domain: .identity)
            var localSelf = self
            _ = valuePublisher.sink(receiveCompletion:{
                CellBase.diagnosticLog("VaporIdentityVault set value completion=\($0)", domain: .identity)
            } , receiveValue: { value in
       
                localSelf.addProperty(property: value, for: key)
               // Feed.sharedInstance.addIdentity(identity: localSelf) // TODO: This needs to be solved in a better way...
            })
        }
    }
}
