// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CellBase
#if canImport(Combine)
@preconcurrency import Combine
import CryptoKit
#else
import OpenCombine
import Crypto
#endif



//@available(iOS 15.0.0, *)
public actor VaporIdentityVault: IdentityVaultProtocol, ScopedSecretProviderProtocol, IdentityKeyRoleProviderProtocol {
    private var initialized = false
    private var identitiesDictionary = [String : String]()
    private var visitingIdentitiesDictionary = [String : Identity]()
    private var identitiesUUIDDictionary = [String : VaultIdentity]()
    static let identitiesFileName = "OrganisationIdentities.crypt"
    private static let encryptedVaultMagic = Data("CVLT1".utf8)
    private static let nonceLength = 12
    private static let tagLength = 16
    private static let keyEnvName = "CELL_VAULT_MASTER_KEY_B64"
    private static let keyPathEnvName = "CELL_VAULT_MASTER_KEY_PATH"
    private static let allowDevKeygenEnvName = "CELL_VAULT_ALLOW_DEV_KEYGEN"
    private static let defaultMasterKeyFilename = "vault-master.key"
#if os(Linux)
    static let documentRoot = "/app/CellsContainer/" // We should move this to a more secret place
#else
    static let documentRoot = "/Users/Shared/"
#endif
    
    public static let shared = VaporIdentityVault()
    
    public func initialize() async -> IdentityVaultProtocol {
        if !initialized {
            initialized = true
            
            let identities = await loadIdentities()
            if let identities = identities {
                for identity in identities {
                    identitiesDictionary[identity.identityContext!] = identity.uuid
                    identitiesUUIDDictionary[identity.uuid] = identity // Also add with uuid for uuid lookups
                }
                
                print("Vapor Vault identitiesDictionary: \(identitiesDictionary)")
            }
        }
        return self
    }
    
    public func setPostAuthenticationInitializer(initializer: @escaping () -> ()) async {
        print("Vapor Identity Vault set post auth initializer not implemented")
    }
    
    
    
    public func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        throw IdentityVaultError.notImplemented
//        return (key: "", iv: "")
    }

    public func scopedSecretData(tag: String, minimumLength: Int) async throws -> Data {
        let masterKeyData = try loadOrCreateMasterKeyData()
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

    private func vaultFileURL() -> URL {
        return URL(fileURLWithPath: VaporIdentityVault.documentRoot).appendingPathComponent(VaporIdentityVault.identitiesFileName)
    }

    private func defaultMasterKeyURL() -> URL {
        return URL(fileURLWithPath: VaporIdentityVault.documentRoot)
            .appendingPathComponent(".secrets")
            .appendingPathComponent(VaporIdentityVault.defaultMasterKeyFilename)
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
        if let targetUUid = identitiesDictionary[identityContext] {
            if let currentVaultIdentity =  identitiesUUIDDictionary[targetUUid] {
                let healedVaultIdentity = healedVaultIdentityIfNeeded(currentVaultIdentity)
                // Testing / Playing
                let identity = healedVaultIdentity.identity
                identity.identityVault = self
                return identity
            }
        }
        if makeNewIfNotFound {
           var identity = Identity()
           identity.identityVault = self
           await addIdentity(identity: &identity, for: identityContext) // TODO: behaviour will be different than expected, see ActorBasicTests.swift in renderer project for examples
           return identity
       }
        return nil
    }
    
    public func addIdentity(identity: inout Identity, for identityContext: String) async {
        if identity.uuid == identityContext { // visiting identities will have same uuid as identityContext
            visitingIdentitiesDictionary[identity.uuid] = identity // Evaluate whether this should use reference counting
            print("identity.uuid \(identity.uuid) added as visitor")
        } else {
            
            identity.identityVault = self
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
        visitingIdentitiesDictionary[identity.uuid] = identity // Evaluate whether this should use reference counting
        print("identity.uuid \(identity.uuid) added as visitor")
    }

    func addVisitingIdentity(snapshot: VaporBridgeIdentitySnapshot) async {
        let identity = snapshot.makeIdentity()
        visitingIdentitiesDictionary[identity.uuid] = identity // Evaluate whether this should use reference counting
        CellBase.diagnosticLog("Visiting identity \(identity.uuid) added to Vapor vault", domain: .bridge)
    }
    
    public func getIdentity(by uuid: String) async -> Identity? {
        var identity = visitingIdentitiesDictionary[uuid]
        
        if identity == nil {
            if let currentVaultIdentity =  identitiesUUIDDictionary[uuid] {
                let healedVaultIdentity = healedVaultIdentityIfNeeded(currentVaultIdentity)
                // Testing / Playing
                identity = healedVaultIdentity.identity
//                identity.identityVault = self
            }
        }
        return identity
    }
    func saveIdentities() {
        let identities = Array(identitiesUUIDDictionary.values)
        
        
        let serializedIdentites = try! JSONEncoder().encode(identities )
        
        do {
            
            try saveIdentities(jsonData: serializedIdentites)
        
        } catch { print("Serializing identities failed with error: \(error)") }
    }
    
    func saveIdentities(jsonData: Data) throws {
        let encryptedData = try encryptVaultData(jsonData, scope: VaporIdentityVault.identitiesFileName)
        let encryptedFileUrl = vaultFileURL()
        print("file url: \(encryptedFileUrl)")
        try encryptedData.write(to: encryptedFileUrl)
    }
    
    public func saveIdentity(_ identity: Identity) async {
        if var vaultIdentity = vaultIdentityWithUUID(identity.uuid) {
            vaultIdentity.update(with: identity)
            identitiesUUIDDictionary[identity.uuid] = vaultIdentity
        }
    }
    
    func loadIdentities() async -> [VaultIdentity]? {
        var identities: [VaultIdentity]?
        do {
            let encryptedData = try Data(contentsOf: vaultFileURL())
            let decryptedResult = try decryptVaultData(encryptedData, scope: VaporIdentityVault.identitiesFileName)
            let decryptedData = decryptedResult.payload
//            print("encryptedFileUrl: \(encryptedFileUrl)")
//            
//                print("Decrypted data as string: \(String(describing: String(data: decryptedData, encoding: .utf8)))")
            
            
            
            //    let contents = try String(contentsOf: fileUrl!, encoding: String.Encoding.utf8)
            //        print("\(contents)")
//            let decoder = JSONDecoder()
//            decoder.userInfo[.facilitator] = Facilitator()
            
            
                if let decryptedIdentities = try? JSONDecoder().decode([VaultIdentity].self, from: decryptedData) {
                    identities =  decryptedIdentities
                    if decryptedResult.needsMigration {
                        try? saveIdentities(jsonData: decryptedData)
                    }
                }
        } catch {
            print("Reading Vapor VaultIdentity json failed. Error: \(error)")
        }
 
        if identities == nil {
            saveIdentities() // Just to initialise the file
        }
        return identities
    }
    
    // This may have to change - should we just check on identityContext?
    public func identityExistInVault(_ identity: Identity) async -> Bool {
        if identitiesUUIDDictionary[identity.uuid] != nil {
            return true
        }
        return false
    }

    func identityExistsInVault(uuid: String) async -> Bool {
        identitiesUUIDDictionary[uuid] != nil
    }
    
    public func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {

        guard let vaultIdentity = self.vaultIdentityWithUUID(identity.uuid) else {
            print("Did not find vault identity for \(identity.uuid)")
            throw IdentityVaultError.noVaultIdentity
        }
        let signatureData = try self.signMessageForVaultIdentity(messageData: messageData, vaultIdentity: vaultIdentity)
        return signatureData
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
                    print("No compressed key")
                }
            case .secp256k1, .P256:
                print("About to verify ECDSA P-256-compatible signature")
                if let compressedKey = publicSecureKey.compressedKey,
                   let publicKey = try? P256.Signing.PublicKey(x963Representation: compressedKey),
                   let ecdsaSignature = try? P256.Signing.ECDSASignature(derRepresentation: signature) {
                    if publicKey.isValidSignature(ecdsaSignature, for: messageData) {
                        return true
                    }
                }
            }
            
        } else {
            print("No public secure key vapor")
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
        guard let vaultIdentity = vaultIdentityWithUUID(identity.uuid) else {
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
                    print("No compressed key")
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
                let newIdentity = Identity(self.uuid, displayName: self.displayName, identityVault: CellBase.defaultIdentityVault)
                
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

            grants.append(Grant(keypath: "identity.displayName", permission: "r--")) // For testing - later check policies
            
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
            grants.append(Grant(nil, keypath: "identity.displayName", permission: "r--"))
            
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
            
            grants.append(Grant(keypath: "displayName", permission: "r--"))
        }
        
        init(identity: inout Identity) {
                print("Generating VaultIdentity from Identity...")
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
            print("Setting value for key: \(key)")
            var localSelf = self
            let valueCancellable = valuePublisher.sink(receiveCompletion:{
                print ("Value for key completion: \($0).")
            } , receiveValue: { value in
       
                localSelf.addProperty(property: value, for: key)
               // Feed.sharedInstance.addIdentity(identity: localSelf) // TODO: This needs to be solved in a better way...
            })
        }
    }
}
