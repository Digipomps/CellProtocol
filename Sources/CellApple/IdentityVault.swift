// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
import LocalAuthentication
import CryptoSwift
import CryptoKit // Apple Framework (also available on Linux [mostly])
import CellBase

public enum KeychainError: Error {
    case noPassword
    case unexpectedPasswordData
    case unhandledError(status: OSStatus)
}

public enum IdentityVaultError: Error {
    case publisherGone
    case signingFailed
    case noVaultIdentity
    case notImplemented
    case noKey
}

extension CodingUserInfoKey {
    public static let facilitator = CodingUserInfoKey(rawValue: "Facilitator")!
}

public actor IdentityVault: IdentityVaultProtocol, ScopedSecretProviderProtocol, IdentityKeyRoleProviderProtocol {
    private var identitiesDictionary = [String : String]()
    private var identitiesUUIDDictionary = [String : VaultIdentity]()
    
    
    static let identitiesFileName = "Identities.crypt"
    private static let encryptedVaultMagic = Data("AVLT1".utf8)
    private static let nonceLength = 12
    private static let tagLength = 16
    private static let scopedSecretTagPrefix = "cell.scoped.secret.v1."
    var context = LAContext()
    var identities: [VaultIdentity]?
    private var mainSecret: Data?
    private let tag = "me.entity.key"
    
    private var initializer: (() -> ())?
    
    public static var shared = IdentityVault()
    
    private var initialized = false
    private var initializationTask: Task<Void, Never>?
       
    enum AuthenticationState {
        case loggedin, loggedout
    }
    
    /// The current authentication state.
    var state = AuthenticationState.loggedout {
        
        // Update the UI on a change.
        didSet {
            // loginButton.isHighlighted = state == .loggedin  // The button text changes on highlight.
            //stateView.backgroundColor = state == .loggedin ? .green : .red
            
            // FaceID runs right away on evaluation, so you might want to warn the user.
            //  In this app, show a special Face ID prompt if the user is logged out, but
            //  only if the device supports that kind of authentication.
            //faceIDLabel.isHidden = (state == .loggedin) || (context.biometryType != .faceID)
            
            print("Didset AuthenticationState: \(state)")
        }
    }
    
    
   private init() {}

    private func makeAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.localizedCancelTitle = "Use Passcode"
        context.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration
        return context
    }
    
    public func setPostAuthenticationInitializer(initializer: @escaping () -> ()) async {
        self.initializer = initializer
    }

    public func initialize() async -> IdentityVaultProtocol  {
        if initialized {
            return self
        }
        if let initializationTask {
            await initializationTask.value
            return self
        }

        let task = Task {
            do {
                try await self.authenticatev2()
                await self.finishInitialization()
            } catch {
                print("Authenticate failed with error: \(error)")
                await self.resetInitializationTask()
            }
        }
        initializationTask = task
        await task.value
        return self
    }

    private func finishInitialization() {
        initialized = true
        initializationTask = nil
    }

    private func resetInitializationTask() {
        initializationTask = nil
    }

    private func hasSigningKeyMaterial(_ vaultIdentity: VaultIdentity) -> Bool {
        let hasPublicKey = resolvedSigningPublicKey(for: vaultIdentity)?.isEmpty == false
        guard hasPublicKey else {
            return false
        }

        if let applicationTag = normalizedApplicationTag(vaultIdentity.privateKeyApplicationTag),
           (try? keychainPrivateKey(for: applicationTag)) != nil {
            return true
        }

        if vaultIdentity.privateKey.isEmpty == false {
            return true
        }

        if let legacyPrivateKey = vaultIdentity.privateSecureKey?.compressedKey,
           legacyPrivateKey.isEmpty == false {
            return true
        }

        return false
    }

    private func normalizedApplicationTag(_ applicationTag: String?) -> String? {
        guard let applicationTag else {
            return nil
        }
        let trimmed = applicationTag.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func publicKeyData(for privateKey: SecKey) -> Data? {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return nil
        }
        return publicKeyData
    }

    private func resolvedSigningPublicKey(for vaultIdentity: VaultIdentity) -> Data? {
        if let applicationTag = normalizedApplicationTag(vaultIdentity.privateKeyApplicationTag),
           let keychainPrivateKey = try? keychainPrivateKey(for: applicationTag),
           let publicKeyData = publicKeyData(for: keychainPrivateKey),
           publicKeyData.isEmpty == false {
            return publicKeyData
        }

        if vaultIdentity.privateKey.isEmpty == false,
           let privateKey = try? restorePrivateKeyFromExternalRepresentation(privateKeyData: vaultIdentity.privateKey),
           let publicKeyData = publicKeyData(for: privateKey),
           publicKeyData.isEmpty == false {
            return publicKeyData
        }

        if let publicKey = vaultIdentity.publicSecureKey?.compressedKey,
           publicKey.isEmpty == false {
            return publicKey
        }

        if vaultIdentity.publicKey.isEmpty == false {
            return vaultIdentity.publicKey
        }

        return nil
    }

    @discardableResult
    private func reconcileSigningMetadataIfNeeded(_ vaultIdentity: inout VaultIdentity) -> Bool {
        var updated = false

        if let canonicalPublicKey = resolvedSigningPublicKey(for: vaultIdentity),
           vaultIdentity.publicKey != canonicalPublicKey {
            vaultIdentity.publicKey = canonicalPublicKey
            updated = true
        }

        if vaultIdentity.normalizeAppleSigningMetadata() {
            updated = true
        }

        return updated
    }

    @discardableResult
    private func healedVaultIdentityIfNeeded(
        _ vaultIdentity: VaultIdentity,
        saveAfterHealing: Bool = true
    ) async -> VaultIdentity {
        var reconciledVaultIdentity = vaultIdentity
        let metadataUpdated = reconcileSigningMetadataIfNeeded(&reconciledVaultIdentity)

        guard hasSigningKeyMaterial(reconciledVaultIdentity) == false else {
            if metadataUpdated {
                identitiesUUIDDictionary[reconciledVaultIdentity.uuid] = reconciledVaultIdentity
                if let identityContext = reconciledVaultIdentity.identityContext {
                    identitiesDictionary[identityContext] = reconciledVaultIdentity.uuid
                }
                if saveAfterHealing {
                    await saveIdentities()
                }
            }
            return reconciledVaultIdentity
        }

        var regeneratedIdentity = Identity(
            reconciledVaultIdentity.uuid,
            displayName: reconciledVaultIdentity.displayName,
            identityVault: self
        )
        regeneratedIdentity.properties = reconciledVaultIdentity.properties
        regeneratedIdentity.grants = reconciledVaultIdentity.grants

        var healedVaultIdentity = VaultIdentity(identity: &regeneratedIdentity)
        healedVaultIdentity.identityContext = reconciledVaultIdentity.identityContext
        healedVaultIdentity.privateProperties = reconciledVaultIdentity.privateProperties
        healedVaultIdentity.publicKeyAgreementSecureKey = reconciledVaultIdentity.publicKeyAgreementSecureKey
        healedVaultIdentity.privateKeyAgreementSecureKey = reconciledVaultIdentity.privateKeyAgreementSecureKey

        identitiesUUIDDictionary[healedVaultIdentity.uuid] = healedVaultIdentity
        if let identityContext = healedVaultIdentity.identityContext {
            identitiesDictionary[identityContext] = healedVaultIdentity.uuid
        }
        if saveAfterHealing {
            await saveIdentities()
        }
        return healedVaultIdentity
    }

    
    public func addIdentity(identity: inout Identity, for identityContext: String) async {
        identity.identityVault = self
        if let targetUUid = identitiesDictionary[identityContext] {
            if targetUUid == identity.uuid, var vaultIdentity = identitiesUUIDDictionary[targetUUid] {
                vaultIdentity = await healedVaultIdentityIfNeeded(vaultIdentity, saveAfterHealing: false)
                vaultIdentity.update(with: identity)
                vaultIdentity.identityContext = identityContext
                identitiesUUIDDictionary[targetUUid] = vaultIdentity
                identity.publicSecureKey = vaultIdentity.publicSecureKey
                identity.publicKeyAgreementSecureKey = vaultIdentity.publicKeyAgreementSecureKey
            } else if var existingVaultIdentity = identitiesUUIDDictionary[identity.uuid] {
                existingVaultIdentity = await healedVaultIdentityIfNeeded(existingVaultIdentity, saveAfterHealing: false)
                existingVaultIdentity.update(with: identity)
                existingVaultIdentity.identityContext = identityContext
                rebindIdentityContexts(from: targetUUid, to: identity.uuid)
                identitiesUUIDDictionary[identity.uuid] = existingVaultIdentity
                identitiesUUIDDictionary.removeValue(forKey: targetUUid)
                identity.publicSecureKey = existingVaultIdentity.publicSecureKey
                identity.publicKeyAgreementSecureKey = existingVaultIdentity.publicKeyAgreementSecureKey
            } else if var reboundVaultIdentity = identitiesUUIDDictionary.removeValue(forKey: targetUUid) {
                reboundVaultIdentity = await healedVaultIdentityIfNeeded(reboundVaultIdentity, saveAfterHealing: false)
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
            let (migrated, _) = await migrateLoadedVaultIdentities([vaultIdentity])
            if let migratedIdentity = migrated.first {
                vaultIdentity = migratedIdentity
                identity.publicKeyAgreementSecureKey = migratedIdentity.publicKeyAgreementSecureKey
                identity.publicSecureKey = migratedIdentity.publicSecureKey
            }
            self.identitiesDictionary[identityContext] = identity.uuid
            self.identitiesUUIDDictionary[identity.uuid] = vaultIdentity // Also add with uuid for uuid lookups
            
        }
        await saveIdentities()
    }

    private func rebindIdentityContexts(from previousUUID: String, to newUUID: String) {
        for (context, mappedUUID) in identitiesDictionary where mappedUUID == previousUUID {
            identitiesDictionary[context] = newUUID
        }
    }
    
    func saveIdentities() async {
        let identities = Array(identitiesUUIDDictionary.values)
        
        
        let serializedIdentites = try! JSONEncoder().encode(identities )
        
        do {
            
            try await saveIdentities(jsonData: serializedIdentites)
        
        } catch { print("Serializing identities failed with error: \(error)") }
    }
    
    public func identityExistInVault(_ identity: Identity) async -> Bool {
        if identitiesUUIDDictionary[identity.uuid] != nil {
            return true
        }
        return false
    }

    func identityExistsInVault(uuid: String) async -> Bool {
        identitiesUUIDDictionary[uuid] != nil
    }
    
    public func identity(for identityContext: String, makeNewIfNotFound: Bool = true) async  -> Identity? {
        
        if let targetUUid = identitiesDictionary[identityContext] {
            if let currentVaultIdentity =  identitiesUUIDDictionary[targetUUid] {
                let healedVaultIdentity = await healedVaultIdentityIfNeeded(currentVaultIdentity)
                // Testing / Playing
                let identity = healedVaultIdentity.identity
                identity.identityVault = self
                return identity
            }
        }
        if makeNewIfNotFound {
           var identity = Identity()
           identity.identityVault = self
            await addIdentity(identity: &identity, for: identityContext)
           return identity
       }
        return nil
    }
    
    private func vaultIdentityWithUUID(_ uuid: String) -> VaultIdentity? {
        if let currentVaultIdentity = identitiesUUIDDictionary[uuid] {
            return currentVaultIdentity
        }
        return nil
    }
    
    public func saveIdentity(_ identity: Identity) async {
        if var vaultIdentity = vaultIdentityWithUUID(identity.uuid) {
            vaultIdentity.update(with: identity)
            identitiesUUIDDictionary[identity.uuid] = vaultIdentity
        }
    }

    public func publicSecureKey(for identity: Identity, role: IdentityKeyRole) async throws -> SecureKey? {
        switch role {
        case .signing:
            return identity.publicSecureKey ?? vaultIdentityWithUUID(identity.uuid)?.publicSecureKey
        case .keyAgreement:
            return identity.publicKeyAgreementSecureKey ?? vaultIdentityWithUUID(identity.uuid)?.publicKeyAgreementSecureKey
        }
    }

    public func privateKeyData(for identity: Identity, role: IdentityKeyRole) async throws -> Data? {
        guard let vaultIdentity = vaultIdentityWithUUID(identity.uuid) else {
            return nil
        }

        switch role {
        case .signing:
            if let privateKeyApplicationTag = vaultIdentity.privateKeyApplicationTag,
               let privateKey = try keychainPrivateKey(for: privateKeyApplicationTag),
               let externalRepresentation = SecKeyCopyExternalRepresentation(privateKey, nil) as Data? {
                return externalRepresentation
            }
            if !vaultIdentity.privateKey.isEmpty {
                return vaultIdentity.privateKey
            }
            return vaultIdentity.privateSecureKey?.compressedKey
        case .keyAgreement:
            if let applicationTag = vaultIdentity.keyAgreementPrivateKeyApplicationTag,
               let keyData = try keychainData(for: applicationTag) {
                return keyData
            }
            if !vaultIdentity.keyAgreementPrivateKey.isEmpty {
                return vaultIdentity.keyAgreementPrivateKey
            }
            return vaultIdentity.privateKeyAgreementSecureKey?.compressedKey
        }
    }
    
    func authenticatev2() async throws  {
        let reason = "Authenticate to access your identities"
        var error: NSError?
        let biometricContext = makeAuthenticationContext()

        if biometricContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            do {
                let authenticated = try await biometricContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
                if authenticated {
                    context = biometricContext
                    try await finishAuthentication()
                    return
                }
            } catch let authError as LAError {
                switch authError.code {
                case .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled:
                    break
                default:
                    throw authError
                }
            }
        }

        let fallbackContext = makeAuthenticationContext()
        if fallbackContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            let authenticated = try await fallbackContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if authenticated {
                context = fallbackContext
                try await finishAuthentication()
            }
        } else {
            print(error?.localizedDescription ?? "Can't evaluate policy")
        }
    }

    private func finishAuthentication() async throws {
        mainSecret = try await scopedSecretData(tag: tag, minimumLength: 32)

        do {
            let (loadedIdentities, needsMigration) = try await loadIdentities()
            identities = loadedIdentities
            if needsMigration, let loadedIdentities {
                let serialized = try JSONEncoder().encode(loadedIdentities)
                try await saveIdentities(jsonData: serialized)
            }
        } catch {
            identities = nil
            print("Loading Apple identity vault failed with error: \(error)")
        }

        if let identities = identities {
            for identity in identities {
                identitiesDictionary[identity.identityContext!] = identity.uuid
                identitiesUUIDDictionary[identity.uuid] = identity
            }

            print("Identity Vault identitiesDictionary: \(identitiesDictionary)")
        }

        if self.initializer != nil {
            self.initializer!()
        }
    }
    func authenticatev1()  {
//        testCreatingIdentitiesFile()
        // Get a fresh context for each login. If you use the same context on multiple attempts
        //  (by commenting out the next line), then a previously successful authentication
        //  causes the next policy evaluation to succeed without testing biometry again.
        //  That's usually not what you want.
        context = LAContext()
        
        context.localizedCancelTitle = "Enter Username/Password"
        
        // First check if we have the needed hardware support.
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            
            let reason = "Authenticate your digital self"
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason ) {  /*[self] */ success, error in
                
                if success {
                    
                    // Move to the main thread because a state update triggers UI changes.
//                    DispatchQueue.main.async { [unowned self] in
//                        self.state = .loggedin
//                    }
//                    if let result = try? self.aquireKeyForTag(tag: tag) {
//                        self.mainIv = result.iv
//                        self.mainKey = result.key
//                        identities = loadIdentities()
//                        if let identities = identities {
//                            for identity in identities {
//                                identitiesDictionary[identity.identityContext!] = identity.uuid
//                                identitiesUUIDDictionary[identity.uuid] = identity // Also add with uuid for uuid lookups
//                            }
//
//                            print("identitiesDictionary: \(identitiesDictionary)")
//                        }
//                    }
                } else {
                    print(error?.localizedDescription ?? "Failed to authenticate")
                    
                    // Fall back to a asking for username and password.
                    // ...
                }
            }
        } else {
            print(error?.localizedDescription ?? "Can't evaluate policy")
            
            // Fall back to a asking for username and password.
            // ...
        }
    }
    
    private func keychainData(for applicationTag: String) throws -> Data? {
        let context = self.context
        context.localizedCancelTitle = "Use Passcode"
        context.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration

        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let searchStatus = SecItemCopyMatching(searchQuery as CFDictionary, &item)
        guard searchStatus != errSecItemNotFound else {
            return nil
        }
        guard searchStatus == errSecSuccess else {
            throw KeychainError.unhandledError(status: searchStatus)
        }
        guard let existingItem = item as? [String: Any],
              let data = existingItem[kSecValueData as String] as? Data else {
            throw KeychainError.unexpectedPasswordData
        }
        return data
    }

    private func keychainPrivateKey(for applicationTag: String) throws -> SecKey? {
        let context = self.context
        context.localizedCancelTitle = "Use Passcode"
        context.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration

        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(applicationTag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let searchStatus = SecItemCopyMatching(searchQuery as CFDictionary, &item)
        guard searchStatus != errSecItemNotFound else {
            return nil
        }
        guard searchStatus == errSecSuccess else {
            throw KeychainError.unhandledError(status: searchStatus)
        }
        return (item as! SecKey)
    }

    private func storePrivateKeyReference(_ privateKey: SecKey, applicationTag: String) throws {
        let tagData = Data(applicationTag.utf8)
        let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.userPresence, .privateKeyUsage],
            nil
        )
        let context = self.context
        context.localizedCancelTitle = "Use Passcode"
        context.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration

#if targetEnvironment(simulator)
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecUseAuthenticationContext as String: context,
            kSecValueRef as String: privateKey
        ]
#else
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrAccessControl as String: access as Any,
            kSecUseAuthenticationContext as String: context,
            kSecValueRef as String: privateKey
        ]
#endif

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    private func importPrivateKeyToKeychainIfNeeded(privateKeyData: Data, applicationTag: String) throws {
        if try keychainPrivateKey(for: applicationTag) != nil {
            return
        }
        let privateKey = try restorePrivateKeyFromExternalRepresentation(privateKeyData: privateKeyData)
        try storePrivateKeyReference(privateKey, applicationTag: applicationTag)
    }

    private func importKeyAgreementPrivateKeyToKeychainIfNeeded(privateKeyData: Data, applicationTag: String) throws {
        if try keychainData(for: applicationTag) != nil {
            return
        }
        try storeKeychainData(privateKeyData, for: applicationTag)
    }

    private func storeKeychainData(_ data: Data, for applicationTag: String) throws {
        let access = SecAccessControlCreateWithFlags(nil, // Use the default allocator.
                                                     kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                     .userPresence,
                                                     nil)
        let context = self.context
        context.localizedCancelTitle = "Use Passcode"
        context.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration

#if targetEnvironment(simulator)
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag,
            kSecUseAuthenticationContext as String: context,
            kSecValueData as String: data
        ]
#else
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrAccessControl as String: access as Any,
            kSecUseAuthenticationContext as String: context,
            kSecValueData as String: data
        ]
#endif

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let lookupQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: applicationTag,
                kSecUseAuthenticationContext as String: context
            ]
            let updateFields: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(lookupQuery as CFDictionary, updateFields as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    private func scopedSecretStorageTag(for tag: String) -> String {
        "\(IdentityVault.scopedSecretTagPrefix)\(tag)"
    }

    public func scopedSecretData(tag: String, minimumLength: Int) async throws -> Data {
        let requiredLength = max(minimumLength, 32)
        let storageTag = scopedSecretStorageTag(for: tag)

        if let stored = try keychainData(for: storageTag) {
            guard stored.count >= requiredLength else {
                throw ScopedSecretProviderError.invalidStoredSecret
            }
            return stored
        }

        let generated = try SecureRandom.data(count: requiredLength)
        try storeKeychainData(generated, for: storageTag)
        return generated
    }

    public func aquireKeyForTag(tag: String)  async throws -> (key: String, iv: String)  {
        if let keyAndIvData = try keychainData(for: tag),
           let keyAndIv = String(data: keyAndIvData, encoding: .utf8) {
            let keyAndIvArray = keyAndIv.split(separator: ".", maxSplits: 1)
            if keyAndIvArray.count == 2 {
                return (String(keyAndIvArray[0]), String(keyAndIvArray[1]))
            }
            throw KeychainError.unexpectedPasswordData
        }

        let key = try SecureRandom.alphanumericString(length: 32)
        let iv = try SecureRandom.alphanumericString(length: 16)
        let payload = Data("\(key).\(iv)".utf8)
        try storeKeychainData(payload, for: tag)
        return (key, iv)
    }
    
    
    func saveIdentities(jsonData: Data) async throws {
        if mainSecret == nil {
            mainSecret = try await scopedSecretData(tag: tag, minimumLength: 32)
        }
        let encryptedData = try encryptVaultData(jsonData, scope: tag)
        
        let encryptedFileUrl = getDocumentsDirectory().appendingPathComponent(IdentityVault.identitiesFileName)
        try encryptedData.write(to:encryptedFileUrl)
    }
    
    func getDocumentsDirectory() -> URL {
        // find all possible documents directories for this user
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        
        // just send back the first one, which ought to be the only one
        return paths[0]
    }
    
    private func vaultKey(scope: String) throws -> SymmetricKey {
        guard let mainSecret else {
            throw IdentityVaultError.noKey
        }
        let masterKey = SymmetricKey(data: mainSecret)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Data("CellAppleVaultSalt.v1".utf8),
            info: Data(scope.utf8),
            outputByteCount: 32
        )
    }

    private func encryptVaultData(_ plaintext: Data, scope: String) throws -> Data {
        let key = try vaultKey(scope: scope)
        let aad = Data("cell-apple-vault-v1:\(scope)".utf8)
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key, authenticating: aad)
        let nonceData = sealedBox.nonce.withUnsafeBytes { Data($0) }

        var output = Data()
        output.append(IdentityVault.encryptedVaultMagic)
        output.append(nonceData)
        output.append(sealedBox.ciphertext)
        output.append(sealedBox.tag)
        return output
    }

    private func legacyDecrypt(_ encryptedData: Data) async throws -> Data {
        let result = try await aquireKeyForTag(tag: tag)
        let aes = try AES(key: result.key, iv: result.iv)
        let decryptedBytes = try aes.decrypt(encryptedData.byteArray)
        return Data(decryptedBytes)
    }

    private func decryptVaultData(_ encryptedData: Data, scope: String) async throws -> (payload: Data, needsMigration: Bool) {
        let headerSize = IdentityVault.encryptedVaultMagic.count
        if encryptedData.count >= headerSize + IdentityVault.nonceLength + IdentityVault.tagLength,
           encryptedData.prefix(headerSize) == IdentityVault.encryptedVaultMagic {
            let nonceStart = headerSize
            let nonceEnd = nonceStart + IdentityVault.nonceLength
            let tagStart = encryptedData.count - IdentityVault.tagLength
            let nonceData = encryptedData.subdata(in: nonceStart..<nonceEnd)
            let ciphertext = encryptedData.subdata(in: nonceEnd..<tagStart)
            let tagData = encryptedData.subdata(in: tagStart..<encryptedData.count)
            let nonce = try ChaChaPoly.Nonce(data: nonceData)
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData)
            let key = try vaultKey(scope: scope)
            let aad = Data("cell-apple-vault-v1:\(scope)".utf8)
            return (try ChaChaPoly.open(box, using: key, authenticating: aad), false)
        }

        if let legacyData = try? await legacyDecrypt(encryptedData) {
            return (legacyData, true)
        }
        return (encryptedData, true)
    }

    func migrateLoadedVaultIdentities(_ identities: [VaultIdentity]) async -> ([VaultIdentity], Bool) {
        var migrated = identities
        var needsMigration = false

        for index in migrated.indices {
            var identity = migrated[index]
            var scrubbedIdentity = false
            var metadataUpdated = false

            if identity.keyAgreementPrivateKeyApplicationTag == nil &&
                identity.keyAgreementPublicKey.isEmpty &&
                identity.keyAgreementPrivateKey.isEmpty {
                let keyAgreementMaterial = VaultIdentity.makeKeyAgreementKeyMaterial(for: identity.uuid)
                identity.keyAgreementPublicKey = keyAgreementMaterial.publicKey
                identity.keyAgreementPrivateKey = keyAgreementMaterial.privateKey
                identity.keyAgreementPrivateKeyApplicationTag = keyAgreementMaterial.privateKeyApplicationTag
                identity.publicKeyAgreementSecureKey = keyAgreementMaterial.publicSecureKey
                identity.privateKeyAgreementSecureKey = keyAgreementMaterial.privateSecureKey
                needsMigration = true
            }

            if let existingTag = identity.privateKeyApplicationTag,
               (try? keychainPrivateKey(for: existingTag)) != nil {
                if !identity.privateKey.isEmpty {
                    identity.privateKey = Data()
                    scrubbedIdentity = true
                }
                if let scrubbedPrivateSecureKey = identity.privateSecureKey?.removingPrivateMaterial(),
                   identity.privateSecureKey?.compressedKey != nil {
                    identity.privateSecureKey = scrubbedPrivateSecureKey
                    scrubbedIdentity = true
                }
                metadataUpdated = reconcileSigningMetadataIfNeeded(&identity)
                if scrubbedIdentity || metadataUpdated {
                    migrated[index] = identity
                    needsMigration = true
                }
                continue
            }

            if identity.privateKeyApplicationTag == nil {
                let legacyTag = legacyPrivateKeyApplicationTag(for: identity.uuid)
                if (try? keychainPrivateKey(for: legacyTag)) != nil {
                    identity.privateKeyApplicationTag = legacyTag
                    if !identity.privateKey.isEmpty {
                        identity.privateKey = Data()
                    }
                    identity.privateSecureKey = identity.privateSecureKey?.removingPrivateMaterial()
                    _ = reconcileSigningMetadataIfNeeded(&identity)
                    migrated[index] = identity
                    needsMigration = true
                    continue
                }
            }

            guard !identity.privateKey.isEmpty else {
                continue
            }

            let targetTag = identity.privateKeyApplicationTag ?? managedPrivateKeyApplicationTag(for: identity.uuid)
            do {
                try importPrivateKeyToKeychainIfNeeded(privateKeyData: identity.privateKey, applicationTag: targetTag)
                identity.privateKeyApplicationTag = targetTag
                identity.privateKey = Data()
                identity.privateSecureKey = identity.privateSecureKey?.removingPrivateMaterial()
                _ = reconcileSigningMetadataIfNeeded(&identity)
                migrated[index] = identity
                needsMigration = true
            } catch {
                // Keep legacy embedded private key material if migration failed.
                print("Apple vault private-key migration skipped for \(identity.uuid): \(error)")
            }

            if let applicationTag = identity.keyAgreementPrivateKeyApplicationTag,
               (try? keychainData(for: applicationTag)) != nil {
                if !identity.keyAgreementPrivateKey.isEmpty {
                    identity.keyAgreementPrivateKey = Data()
                    scrubbedIdentity = true
                }
                metadataUpdated = identity.normalizeKeyAgreementMetadata() || metadataUpdated
                if scrubbedIdentity || metadataUpdated {
                    migrated[index] = identity
                    needsMigration = true
                }
                continue
            }

            if !identity.keyAgreementPrivateKey.isEmpty {
                let targetTag = identity.keyAgreementPrivateKeyApplicationTag ?? managedKeyAgreementPrivateKeyApplicationTag(for: identity.uuid)
                do {
                    try importKeyAgreementPrivateKeyToKeychainIfNeeded(
                        privateKeyData: identity.keyAgreementPrivateKey,
                        applicationTag: targetTag
                    )
                    identity.keyAgreementPrivateKeyApplicationTag = targetTag
                    identity.keyAgreementPrivateKey = Data()
                    _ = identity.normalizeKeyAgreementMetadata()
                    migrated[index] = identity
                    needsMigration = true
                } catch {
                    print("Apple vault key-agreement migration skipped for \(identity.uuid): \(error)")
                }
            }
        }

        return (migrated, needsMigration)
    }

    func loadIdentities() async throws -> ([VaultIdentity]?, Bool) {
        let encryptedFileUrl = getDocumentsDirectory().appendingPathComponent(IdentityVault.identitiesFileName)
        guard FileManager.default.fileExists(atPath: encryptedFileUrl.path) else {
            return (nil, false)
        }

        let encryptedData = try Data(contentsOf: encryptedFileUrl)
        let (decryptedData, needsMigration) = try await decryptVaultData(encryptedData, scope: tag)
        let decoder = JSONDecoder()
        decoder.userInfo[.facilitator] = Facilitator(version: nil)
        let identities = try decoder.decode([VaultIdentity].self, from: decryptedData)
        let (migratedIdentities, keyMigrationNeeded) = await migrateLoadedVaultIdentities(identities)
        return (migratedIdentities, needsMigration || keyMigrationNeeded)
    }
    
    func restorePrivateKeyFromExternalRepresentation(privateKeyData: Data) throws -> SecKey  {
//        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        
        let options: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                      kSecAttrKeySizeInBits as String : 256]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(privateKeyData as CFData,
                                             options as CFDictionary,
                                             &error) else {
                                                throw error!.takeRetainedValue() as Error
        }
        return key
    }
    
    func restorePublicKeyFromExternalRepresentation(publicKeyData: Data) throws -> SecKey  {
        let options: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                      kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                                      kSecAttrKeySizeInBits as String : 256]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(publicKeyData as CFData,
                                             options as CFDictionary,
                                             &error) else {
                                                throw error!.takeRetainedValue() as Error
        }
        return key
    }
/*
    func encryptMessage(message: Data, publicKey: Data) -> Data? {
        do {
        let publicSecKey = try restorePublicKeyFromExternalRepresentation(publicKeyData: publicKey)
            
            
         return encryptMessage(message: message, publicKey: publicSecKey)
//            return nil //encryptMessage(message: message, publicKey: publicSecKey)
        } catch {
            print("Encrypting message \(message) failed with error: \(error)")
        }
        return nil
    }

    func encryptMessage(message: Data, publicKey: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let encryptData = SecKeyCreateEncryptedData(
                publicKey,
                SecKeyAlgorithm.eciesEncryptionStandardX963SHA256AESGCM,
                message as CFData,
                &error) else {
            print("Encryption Error")
            return nil// throw?
        }
        return encryptData as Data
    }

    func decryptMessage(message: Data, privateKey: Data) -> Data? {
        do {
        let privateSecKey = try restorePrivateKeyFromExternalRepresentation(privateKeyData: privateKey)
            return decryptMessage(message: message, privateKey: privateSecKey)
        } catch {
            print("Decrypting message \(message) failed with error: \(error)")
        }
        return nil
    }
    
    func decryptMessage(message: Data, privateKey: SecKey) -> Data? {
        guard let decryptData = SecKeyCreateDecryptedData(
                privateKey,
                SecKeyAlgorithm.eciesEncryptionStandardX963SHA256AESGCM,
                message as CFData,
                nil) else {
            print("Decryption Error")
            return nil
        } //2
        let decryptedData = decryptData as Data
        //    guard
        //    let decryptedString = String(data: decryptedData, encoding: String.Encoding.utf8) else {
        //    print("Error retrieving string")
        return decryptedData
        //    }
    }
*/
    public func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        guard let vaultIdentity = self.vaultIdentityWithUUID(identity.uuid) else {
            print("Did not find vault identity for \(identity.uuid)")
            throw IdentityVaultError.noVaultIdentity
        }
        let signatureData = try self.signMessageForVaultIdentity(messageData: messageData, vaultIdentity: vaultIdentity)
        return signatureData
    }
    
    func signMessageForVaultIdentity(messageData: Data, vaultIdentity: VaultIdentity) throws -> Data {
        var error: Unmanaged<CFError>?
        let privateKey: SecKey
        if let privateKeyApplicationTag = vaultIdentity.privateKeyApplicationTag,
           let keychainPrivateKey = try keychainPrivateKey(for: privateKeyApplicationTag) {
            privateKey = keychainPrivateKey
        } else if !vaultIdentity.privateKey.isEmpty {
            privateKey = try restorePrivateKeyFromExternalRepresentation(privateKeyData: vaultIdentity.privateKey)
        } else if let legacyPrivateKeyData = vaultIdentity.privateSecureKey?.compressedKey {
            privateKey = try restorePrivateKeyFromExternalRepresentation(privateKeyData: legacyPrivateKeyData)
        } else {
            throw IdentityVaultError.noKey
        }
        let algorithm: SecKeyAlgorithm = .ecdsaSignatureMessageX962SHA256
        guard let signature = SecKeyCreateSignature(privateKey,
                                                    algorithm,
                                                    messageData as CFData,
                                                    &error) as Data? else {
                                                        throw error!.takeRetainedValue() as Error
        }
        return signature as Data
        
        }
    
    public func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        guard let publicKeyData = identity.publicSecureKey?.compressedKey,
              publicKeyData.isEmpty == false else {
            throw IdentityVaultError.noKey
        }

        let publicKey = try restorePublicKeyFromExternalRepresentation(publicKeyData: publicKeyData)
        var error: Unmanaged<CFError>?
        let algorithm: SecKeyAlgorithm = .ecdsaSignatureMessageX962SHA256
        guard SecKeyVerifySignature(publicKey,
                                    algorithm,
                                    messageData as CFData,
                                    signature as CFData,
                                    &error) else {
            throw error!.takeRetainedValue() as Error
        }

        return true
    }
   
    func randomBytes32() -> Data? {
        var bytes = [Int8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        if status == errSecSuccess { // Always test the status.
            return Data(bytes: &bytes, count: 32)
        }
        return nil
    }
    
    public func randomBytes64() async -> Data? {
        var bytes = [Int8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        if status == errSecSuccess { // Always test the status.
            return Data(bytes: &bytes, count: 64)
        }
        return nil
    }
}

// From Apple example code CryptoKitKeychain
struct SecKeyStore {
    
    /// Stores a CryptoKit key in the keychain as a SecKey instance.
    func storeKey<T: SecKeyConvertible>(_ key: T, label: String) throws {

        // Describe the key.
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                          kSecAttrKeyClass: kSecAttrKeyClassPrivate] as [String: Any]
        
        // Get a SecKey representation.
        guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData,
                                                attributes as CFDictionary,
                                                nil)
            else {
                throw KeyStoreError("Unable to create SecKey representation.")
        }

        // Describe the add operation.
        let query = [kSecClass: kSecClassKey,
                     kSecAttrApplicationLabel: label,
                     kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
                     kSecUseDataProtectionKeychain: true,
                     kSecValueRef: secKey] as [String: Any]
        
        // Add the key to the keychain.
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError("Unable to store item: \(status.message)")
        }
   }
    
    /// Reads a CryptoKit key from the keychain as a SecKey instance.
    func readKey<T: SecKeyConvertible>(label: String) throws -> T? {
        
        // Seek an elliptic-curve key with a given label.
        let query = [kSecClass: kSecClassKey,
                     kSecAttrApplicationLabel: label,
                     kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                     kSecUseDataProtectionKeychain: true,
                     kSecReturnRef: true] as [String: Any]
        
        // Find and cast the result as a SecKey instance.
        var item: CFTypeRef?
        var secKey: SecKey
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess: secKey = item as! SecKey
        case errSecItemNotFound: return nil
        case let status: throw KeyStoreError("Keychain read failed: \(status.message)")
        }

        // Convert the SecKey into a CryptoKit key.
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
            throw KeyStoreError(error.debugDescription)
        }
        let key = try T(x963Representation: data)

        return key
    }

    /// Stores a key in the keychain and then reads it back.
    func roundTrip<T: SecKeyConvertible>(_ key: T) throws -> T {
        // A label for the key in the keychain.
        let label = "com.example.seckey.key"
        
        // Start fresh.
        try deleteKey(label: label)
        
        // Store it and then get it back.
        try storeKey(key, label: label)
        guard let key: T = try readKey(label: label) else {
            throw KeyStoreError("Failed to locate stored key.")
        }
        return key
    }
    
    /// Removes any existing key with the given label.
    func deleteKey(label: String) throws {
        let query = [kSecClass: kSecClassKey,
                     kSecUseDataProtectionKeychain: true,
                     kSecAttrApplicationLabel: label] as [String: Any]
        switch SecItemDelete(query as CFDictionary) {
        case errSecItemNotFound, errSecSuccess: break // Ignore these.
        case let status:
            throw KeyStoreError("Unexpected deletion error: \(status.message)")
        }
    }
}

/// An error we can throw when something goes wrong.
struct KeyStoreError: Error, CustomStringConvertible {
    var message: String
    
    init(_ message: String) {
        self.message = message
    }
    
    public var description: String {
        return message
    }
}

extension OSStatus {
    
    /// A human readable message for the status.
    var message: String {
        return (SecCopyErrorMessageString(self, nil) as String?) ?? String(self)
    }
}

/// The interface needed for SecKey conversion.
protocol SecKeyConvertible: CustomStringConvertible {
    /// Creates a key from an X9.63 representation.
    init<Bytes>(x963Representation: Bytes) throws where Bytes: ContiguousBytes
    
    /// An X9.63 representation of the key.
    var x963Representation: Data { get }
}

extension SecKeyConvertible {
    /// A string version of the key for visual inspection.
    /// IMPORTANT: Never log the actual key data.
    public var description: String {
        return self.x963Representation.withUnsafeBytes { bytes in
            return "Key representation contains \(bytes.count) bytes."
        }
    }
}

// Assert that the NIST keys are convertible.
extension P256.Signing.PrivateKey: SecKeyConvertible {}
extension P256.KeyAgreement.PrivateKey: SecKeyConvertible {}
extension P384.Signing.PrivateKey: SecKeyConvertible {}
extension P384.KeyAgreement.PrivateKey: SecKeyConvertible {}
extension P521.Signing.PrivateKey: SecKeyConvertible {}
extension P521.KeyAgreement.PrivateKey: SecKeyConvertible {}

func legacyPrivateKeyApplicationTag(for domainString: String) -> String {
    domainString + ".keys.privatekey2"
}

func managedPrivateKeyApplicationTag(for domainString: String) -> String {
    domainString + ".keys.signing.privatekey4"
}

func managedKeyAgreementPrivateKeyApplicationTag(for domainString: String) -> String {
    domainString + ".keys.keyagreement.privatekey1"
}




func createKeyPairForDomainv2(domainString: String) throws -> (publicKey: Data, privateKey: Data)  {
    let tagString = legacyPrivateKeyApplicationTag(for: domainString)
    let tag = tagString.data(using: .utf8)!
    let attributes: [String: Any] =
        [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom as String,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String:
            [
                kSecAttrCanDecrypt as String: true,
                kSecAttrCanSign as String: true,
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag
            ]
    ]
    
    var error: Unmanaged<CFError>?
    
    guard let privateKey: SecKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error)  else {
        print("Creating private key failed with error: \(String(describing: error))")
        throw KeyStoreError("Creating private key failed with error: \(String(describing: error))")
    }
    //kSecAttrKeyTypeECSECPrimeRandom // 
//    guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, .ecdhKeyExchangeCofactorX963SHA256) else {
//        throw KeyStoreError("Usupported SecKey Algorithm.")
//    }

    guard SecKeyIsAlgorithmSupported(privateKey, .sign, .ecdsaSignatureMessageX962SHA256) else {
        throw KeyStoreError("Usupported SecKey Algorithm for signing.")
    }

//    //check if the text size is compatible with the key size
//    guard cipherText.count == SecKeyGetBlockSize(privateKey) else {
//        return "Unaligned sizes"
//    }
    
    guard let publicKey = SecKeyCopyPublicKey(privateKey), //1
        let publicKeyExRep = SecKeyCopyExternalRepresentation(publicKey, nil),
        let privateKeyExRep = SecKeyCopyExternalRepresentation(privateKey, nil) else { //2
            throw KeyStoreError("Getting public key external representation failed.")
    }
    // ANSI X9.63
    print("******* Generated Public and Private key Pair *********")
    let publicKeyData = publicKeyExRep as Data
    let privateKeyData = privateKeyExRep as Data
    return (publicKey: publicKeyData, privateKey: privateKeyData)
}

func createKeyPairForDomainv4(domainString: String) throws -> (publicKey: Data, privateKeyApplicationTag: String)  {
    let tagString = managedPrivateKeyApplicationTag(for: domainString)
    let tag = tagString.data(using: .utf8)!
    let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
        [.userPresence, .privateKeyUsage],
        nil
    )

    let privateKeyAttrs: [String: Any]
#if targetEnvironment(simulator)
    privateKeyAttrs = [
        kSecAttrCanSign as String: true,
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: tag
    ]
#else
    privateKeyAttrs = [
        kSecAttrCanSign as String: true,
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: tag,
        kSecAttrAccessControl as String: access as Any
    ]
#endif

    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom as String,
        kSecAttrKeySizeInBits as String: 256,
        kSecPrivateKeyAttrs as String: privateKeyAttrs
    ]

    var error: Unmanaged<CFError>?
    guard let privateKey: SecKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
        throw KeyStoreError("Creating managed private key failed with error: \(String(describing: error))")
    }

    guard SecKeyIsAlgorithmSupported(privateKey, .sign, .ecdsaSignatureMessageX962SHA256) else {
        throw KeyStoreError("Unsupported SecKey Algorithm for managed signing.")
    }

    guard let publicKey = SecKeyCopyPublicKey(privateKey),
          let publicKeyExRep = SecKeyCopyExternalRepresentation(publicKey, nil) else {
        throw KeyStoreError("Getting managed public key external representation failed.")
    }

    return (publicKey: publicKeyExRep as Data, privateKeyApplicationTag: tagString)
}

func createKeyPairForDomainv3(domainString: String) throws -> (publicKey: Data, privateKey: Data)  {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    let privateKeyData = privateKey.rawRepresentation
    let publicKeyData = privateKey.publicKey.rawRepresentation

    
    return (publicKey: publicKeyData, privateKey: privateKeyData)
}

/*
 
 
 */

struct VaultIdentity: Codable {
    var uuid: String
    var displayName: String
    
    var identityContext: String?
//    var services: [Service]?
    var grants = [Grant]()
    
    var publicKey: Data
    var privateKey: Data
    var privateKeyApplicationTag: String?
    var keyAgreementPublicKey: Data
    var keyAgreementPrivateKey: Data
    var keyAgreementPrivateKeyApplicationTag: String?

    var publicSecureKey: SecureKey?
    var privateSecureKey: SecureKey?
    var publicKeyAgreementSecureKey: SecureKey?
    var privateKeyAgreementSecureKey: SecureKey?
    
    var properties: [String: ValueType]?
    var privateProperties: [String: ValueType]?
    
    var entityAnchorReference: String
    
    var identity: Identity {
        get {
            let newIdentity = Identity(self.uuid, displayName: self.displayName, identityVault: CellBase.defaultIdentityVault)
            
            newIdentity.properties = self.properties
            newIdentity.publicSecureKey = self.publicSecureKey ?? {
                guard self.publicKey.isEmpty == false else { return nil }
                return Self.appleSigningPublicSecureKey(publicKey: self.publicKey)
            }()
            newIdentity.publicKeyAgreementSecureKey = self.publicKeyAgreementSecureKey ?? {
                guard self.keyAgreementPublicKey.isEmpty == false else { return nil }
                return Self.appleKeyAgreementPublicSecureKey(publicKey: self.keyAgreementPublicKey)
            }()

            return newIdentity
        }
    }
    
    public static func ==(lhs: VaultIdentity, rhs: VaultIdentity) -> Bool {
        return (lhs.uuid == rhs.uuid)
    }

    
    enum CodingKeys: String, CodingKey
    {
        case uuid
        case displayName
        case identityContext
        case publicKey
        case privateKey
        case privateKeyApplicationTag
        case keyAgreementPublicKey
        case keyAgreementPrivateKey
        case keyAgreementPrivateKeyApplicationTag
        case properties
        case privateProperties
        case publicSecureKey
        case privateSecureKey
        case publicKeyAgreementSecureKey
        case privateKeyAgreementSecureKey
        case entityAnchorReference
    }
    
    init() {
        self.uuid = UUID().uuidString
        self.displayName = self.uuid
        
        if self.properties == nil {
            self.properties = [String: ValueType]()
        }

        grants.append(Grant(keypath: "displayName", permission: "r--")) // For testing - later check policies
        
        publicKey = Data()
        privateKey = Data()
        privateKeyApplicationTag = nil
        keyAgreementPublicKey = Data()
        keyAgreementPrivateKey = Data()
        keyAgreementPrivateKeyApplicationTag = nil
        
        entityAnchorReference = "cell:///EntityAnchor"
    }
    
    init(uuid: String, displayName: String) {
        self.uuid = uuid
        self.displayName = displayName
        
        if self.properties == nil {
            self.properties = [String: ValueType]()
        }
        grants.append(Grant(nil, keypath: "displayName", permission: "r--"))
        
        let keyMaterial = Self.makeSigningKeyMaterial(for: uuid)
        publicKey = keyMaterial.publicKey
        privateKey = keyMaterial.privateKey
        privateKeyApplicationTag = keyMaterial.privateKeyApplicationTag
        self.publicSecureKey = keyMaterial.publicSecureKey
        self.privateSecureKey = keyMaterial.privateSecureKey
        let keyAgreementMaterial = Self.makeKeyAgreementKeyMaterial(for: uuid)
        keyAgreementPublicKey = keyAgreementMaterial.publicKey
        keyAgreementPrivateKey = keyAgreementMaterial.privateKey
        keyAgreementPrivateKeyApplicationTag = keyAgreementMaterial.privateKeyApplicationTag
        self.publicKeyAgreementSecureKey = keyAgreementMaterial.publicSecureKey
        self.privateKeyAgreementSecureKey = keyAgreementMaterial.privateSecureKey
        entityAnchorReference = "cell:///EntityAnchor"
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
            privateKeyApplicationTag = try values.decodeIfPresent(String.self, forKey: .privateKeyApplicationTag)
            keyAgreementPublicKey = try values.decodeIfPresent(Data.self, forKey: .keyAgreementPublicKey) ?? Data()
            keyAgreementPrivateKey = try values.decodeIfPresent(Data.self, forKey: .keyAgreementPrivateKey) ?? Data()
            keyAgreementPrivateKeyApplicationTag = try values.decodeIfPresent(String.self, forKey: .keyAgreementPrivateKeyApplicationTag)
        } catch {
            publicKey = Data()
            privateKey = Data()
            privateKeyApplicationTag = nil
            keyAgreementPublicKey = Data()
            keyAgreementPrivateKey = Data()
            keyAgreementPrivateKeyApplicationTag = nil
        }
        self.publicSecureKey = try values.decodeIfPresent(SecureKey.self, forKey: .publicSecureKey)
        self.privateSecureKey = try values.decodeIfPresent(SecureKey.self, forKey: .privateSecureKey)
        self.publicKeyAgreementSecureKey = try values.decodeIfPresent(SecureKey.self, forKey: .publicKeyAgreementSecureKey)
        self.privateKeyAgreementSecureKey = try values.decodeIfPresent(SecureKey.self, forKey: .privateKeyAgreementSecureKey)
//            if let propertiesContainer = try? values.decodeIfPresent(DynamicProperties.self, forKey: .properties) {
//                self.properties = propertiesContainer.propertyValues
//            }
        if let anchor = try values.decodeIfPresent(String.self, forKey: .entityAnchorReference) {
            entityAnchorReference = anchor
        } else {
            entityAnchorReference = "cell:///EntityAnchor"
        }
        
        if self.properties == nil {
            self.properties = [String: ValueType]()
        }
        
        grants.append(Grant(keypath: "displayName", permission: "r--"))
    }
    
    init(identity: inout Identity) {
            self.uuid = identity.uuid
            self.displayName = identity.displayName
            self.properties = identity.properties
            self.grants = identity.grants
            self.entityAnchorReference = identity.entityAnchorReference
        let keyMaterial = Self.makeSigningKeyMaterial(for: uuid)
        publicKey = keyMaterial.publicKey
        privateKey = keyMaterial.privateKey
        privateKeyApplicationTag = keyMaterial.privateKeyApplicationTag
        self.publicSecureKey = keyMaterial.publicSecureKey
        self.privateSecureKey = keyMaterial.privateSecureKey
        let keyAgreementMaterial = Self.makeKeyAgreementKeyMaterial(for: uuid)
        keyAgreementPublicKey = keyAgreementMaterial.publicKey
        keyAgreementPrivateKey = keyAgreementMaterial.privateKey
        keyAgreementPrivateKeyApplicationTag = keyAgreementMaterial.privateKeyApplicationTag
        self.publicKeyAgreementSecureKey = keyAgreementMaterial.publicSecureKey
        self.privateKeyAgreementSecureKey = keyAgreementMaterial.privateSecureKey
//        identity.publicKey = publicKey // This may be a little dirty
        identity.publicSecureKey = publicSecureKey
        identity.publicKeyAgreementSecureKey = publicKeyAgreementSecureKey

    }
    
    public func encode(to encoder: Encoder) throws {
        //        print("encoding: \(self)")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(identityContext, forKey: .identityContext)
        try container.encodeIfPresent(privateKey.isEmpty ? nil : privateKey, forKey: .privateKey)
        try container.encodeIfPresent(privateKeyApplicationTag, forKey: .privateKeyApplicationTag)
        try container.encodeIfPresent(publicKey, forKey: .publicKey)
        try container.encodeIfPresent(keyAgreementPrivateKey.isEmpty ? nil : keyAgreementPrivateKey, forKey: .keyAgreementPrivateKey)
        try container.encodeIfPresent(keyAgreementPrivateKeyApplicationTag, forKey: .keyAgreementPrivateKeyApplicationTag)
        try container.encodeIfPresent(keyAgreementPublicKey, forKey: .keyAgreementPublicKey)
        try container.encodeIfPresent(properties, forKey: .properties)
        try container.encodeIfPresent(publicSecureKey, forKey: .publicSecureKey)
        try container.encodeIfPresent(privateSecureKey, forKey: .privateSecureKey)
        try container.encodeIfPresent(publicKeyAgreementSecureKey, forKey: .publicKeyAgreementSecureKey)
        try container.encodeIfPresent(privateKeyAgreementSecureKey, forKey: .privateKeyAgreementSecureKey)
        try container.encodeIfPresent(entityAnchorReference, forKey: .entityAnchorReference)
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
        print("Setting value for key: \(key)")
        var localSelf = self
        let valueCancellable = valuePublisher.sink(receiveCompletion:{
            print ("Value for key completion: \($0).")
        } , receiveValue: { value in
   
            localSelf.addProperty(property: value, for: key)
           // Feed.sharedInstance.addIdentity(identity: localSelf) // TODO: This needs to be solved in a better way...
        })
    }

    private static func makeSigningKeyMaterial(for uuid: String) -> (
        publicKey: Data,
        privateKey: Data,
        privateKeyApplicationTag: String?,
        publicSecureKey: SecureKey?,
        privateSecureKey: SecureKey?
    ) {
        do {
            let keys = try createKeyPairForDomainv4(domainString: uuid)
            let publicSecureKey = Self.appleSigningPublicSecureKey(publicKey: keys.publicKey)
            let privateSecureKey = Self.appleSigningPrivateSecureKey()
            return (
                publicKey: keys.publicKey,
                privateKey: Data(),
                privateKeyApplicationTag: keys.privateKeyApplicationTag,
                publicSecureKey: publicSecureKey,
                privateSecureKey: privateSecureKey
            )
        } catch {
            do {
                let keys = try createKeyPairForDomainv2(domainString: uuid)
                let publicSecureKey = Self.appleSigningPublicSecureKey(publicKey: keys.publicKey)
                let privateSecureKey = Self.appleSigningPrivateSecureKey()
                return (
                    publicKey: keys.publicKey,
                    privateKey: Data(),
                    privateKeyApplicationTag: legacyPrivateKeyApplicationTag(for: uuid),
                    publicSecureKey: publicSecureKey,
                    privateSecureKey: privateSecureKey
                )
            } catch {
                print("Key generation failed")
                return (
                    publicKey: Data(),
                    privateKey: Data(),
                    privateKeyApplicationTag: nil,
                    publicSecureKey: nil,
                    privateSecureKey: nil
                )
            }
        }
    }

    private static func appleSigningPublicSecureKey(publicKey: Data) -> SecureKey {
        SecureKey(
            date: Date(),
            privateKey: false,
            use: .signature,
            algorithm: .ECDSA,
            size: 256,
            curveType: .P256,
            x: nil,
            y: nil,
            compressedKey: publicKey
        )
    }

    private static func appleSigningPrivateSecureKey() -> SecureKey {
        SecureKey(
            date: Date(),
            privateKey: true,
            use: .signature,
            algorithm: .ECDSA,
            size: 256,
            curveType: .P256,
            x: nil,
            y: nil,
            compressedKey: nil
        )
    }

    fileprivate static func makeKeyAgreementKeyMaterial(for uuid: String) -> (
        publicKey: Data,
        privateKey: Data,
        privateKeyApplicationTag: String?,
        publicSecureKey: SecureKey?,
        privateSecureKey: SecureKey?
    ) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        return (
            publicKey: publicKey,
            privateKey: privateKey.rawRepresentation,
            privateKeyApplicationTag: managedKeyAgreementPrivateKeyApplicationTag(for: uuid),
            publicSecureKey: appleKeyAgreementPublicSecureKey(publicKey: publicKey),
            privateSecureKey: appleKeyAgreementPrivateSecureKey()
        )
    }

    private static func appleKeyAgreementPublicSecureKey(publicKey: Data) -> SecureKey {
        SecureKey(
            date: Date(),
            privateKey: false,
            use: .keyAgreement,
            algorithm: .X25519,
            size: 256,
            curveType: .Curve25519,
            x: nil,
            y: nil,
            compressedKey: publicKey
        )
    }

    private static func appleKeyAgreementPrivateSecureKey() -> SecureKey {
        SecureKey(
            date: Date(),
            privateKey: true,
            use: .keyAgreement,
            algorithm: .X25519,
            size: 256,
            curveType: .Curve25519,
            x: nil,
            y: nil,
            compressedKey: nil
        )
    }

    mutating func normalizeAppleSigningMetadata() -> Bool {
        var updated = false
        if !publicKey.isEmpty {
            let normalizedPublicKey = Self.appleSigningPublicSecureKey(publicKey: publicKey)
            if publicSecureKey?.algorithm != normalizedPublicKey.algorithm ||
                publicSecureKey?.curveType != normalizedPublicKey.curveType ||
                publicSecureKey?.compressedKey != normalizedPublicKey.compressedKey {
                publicSecureKey = normalizedPublicKey
                updated = true
            }
        }

        let normalizedPrivateKey = Self.appleSigningPrivateSecureKey()
        if privateSecureKey?.algorithm != normalizedPrivateKey.algorithm ||
            privateSecureKey?.curveType != normalizedPrivateKey.curveType ||
            privateSecureKey?.compressedKey != nil {
            privateSecureKey = normalizedPrivateKey
            updated = true
        }
        return updated
    }

    mutating func normalizeKeyAgreementMetadata() -> Bool {
        var updated = false
        if !keyAgreementPublicKey.isEmpty {
            let normalizedPublicKey = Self.appleKeyAgreementPublicSecureKey(publicKey: keyAgreementPublicKey)
            if publicKeyAgreementSecureKey?.algorithm != normalizedPublicKey.algorithm ||
                publicKeyAgreementSecureKey?.curveType != normalizedPublicKey.curveType ||
                publicKeyAgreementSecureKey?.compressedKey != normalizedPublicKey.compressedKey {
                publicKeyAgreementSecureKey = normalizedPublicKey
                updated = true
            }
        }

        let normalizedPrivateKey = Self.appleKeyAgreementPrivateSecureKey()
        if privateKeyAgreementSecureKey?.algorithm != normalizedPrivateKey.algorithm ||
            privateKeyAgreementSecureKey?.curveType != normalizedPrivateKey.curveType ||
            privateKeyAgreementSecureKey?.compressedKey != nil {
            privateKeyAgreementSecureKey = normalizedPrivateKey
            updated = true
        }
        return updated
    }
}

private extension SecureKey {
    func removingPrivateMaterial() -> SecureKey {
        SecureKey(
            date: Date(),
            privateKey: privateKey,
            use: use,
            algorithm: algorithm,
            size: size,
            curveType: curveType,
            x: x,
            y: y,
            compressedKey: privateKey ? nil : compressedKey
        )
    }
}


/*
 Move to crypto-kit based AES-GCM encryption instead of CryptoSwift
 https://dev.to/craftzdog/how-to-encrypt-decrypt-with-aes-gcm-using-cryptokit-in-swift-24h1
 public extension Data {
     init?(hexString: String) {
       let len = hexString.count / 2
       var data = Data(capacity: len)
       var i = hexString.startIndex
       for _ in 0..<len {
         let j = hexString.index(i, offsetBy: 2)
         let bytes = hexString[i..<j]
         if var num = UInt8(bytes, radix: 16) {
           data.append(&num, count: 1)
         } else {
           return nil
         }
         i = j
       }
       self = data
     }
     /// Hexadecimal string representation of `Data` object.
     var hexadecimal: String {
         return map { String(format: "%02x", $0) }
             .joined()
     }
 }
 
 Load Key:
 import CryptoKit

 let keyStr = "d5a423f64b607ea7c65b311d855dc48f36114b227bd0c7a3d403f6158a9e4412"
 let key = SymmetricKey(data: Data(hexString:keyStr)!)

 Decrypt:
 let ciphertext = Data(base64Encoded: "LzpSalRKfL47H5rUhqvA")
 let nonce = Data(hexString: "131348c0987c7eece60fc0bc") // = initialization vector
 let tag = Data(hexString: "5baa85ff3e7eda3204744ec74b71d523")
 let sealedBox = try! AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce!),
                                        ciphertext: ciphertext!,
                                        tag: tag!)

 let decryptedData = try! AES.GCM.open(sealedBox, using: key)
 print(String(decoding: decryptedData, as: UTF8.self))
 
 Encrypt
 let plainData = "This is a plain text".data(using: .utf8)
 let sealedData = try! AES.GCM.seal(plainData!, using: key, nonce: AES.GCM.Nonce(data:nonce!))
 let encryptedContent = try! sealedData.combined!
 print("Nonce: \(sealedData.nonce.withUnsafeBytes { Data(Array($0)).hexadecimal })")
 print("Tag: \(sealedData.tag.hexadecimal)")
 print("Data: \(sealedData.ciphertext.base64EncodedString())")
 
 */
