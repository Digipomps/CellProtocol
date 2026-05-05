// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

// Identity is intentionally still a mutable reference type for public API compatibility.
// Vaults and cells own synchronization around cross-actor use.
final public class Identity: Codable, Grantable, Meddle, Equatable, @unchecked Sendable {

    

    public let uuid: String
    public var displayName: String
//    public var publicKey: Data?
    
    public var publicSecureKey: SecureKey?
    public var publicKeyAgreementSecureKey: SecureKey?
    
//    var services: [Service]?
    public var grants = [Grant]()
    
    public var properties: [String: ValueType]?

    public var entityAnchorReference = "cell:///EntityAnchor" // each scaffold should have a identity unique cell act as the anchor to the - should it only be the VaultIdentity? At least don't leak this to others
    
    public var identityVault: IdentityVaultProtocol?
    
    var valueCancellable: AnyCancellable?
    
    private var signCancellables = [Int: AnyCancellable]()
    private var signInc = 0
    let dispatchQueue = DispatchQueue.init(label: "Identity dispatch queue")
    
    public static func ==(lhs: Identity, rhs: Identity) -> Bool {
        return (lhs.uuid == rhs.uuid)
    }

    
    enum CodingKeys: String, CodingKey
    {
        case uuid
        case displayName
        case publicKey
        case properties
        case publicSecureKey
        case publicKeyAgreementSecureKey
    }
    
    public init() {
        self.uuid = UUID().uuidString
        self.displayName = self.uuid
        
        if self.properties == nil {
            self.properties = [String: ValueType]()
        }
        grants.append(Grant(nil, keypath: "displayName", permission: "r--")) // For testing - later check policies
    }
    
    public init(_ uuid: String = UUID().uuidString, displayName: String, identityVault: IdentityVaultProtocol?) {
        self.uuid = uuid
        self.displayName = displayName
        
        if self.properties == nil {
            self.properties = [String: ValueType]()
        }
        grants.append(Grant(nil, keypath: "displayName", permission: "r--"))
        self.identityVault = identityVault
    }
    
    required public init(from decoder: Decoder) throws {
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
//        publicKey  = try? values.decodeIfPresent(Data.self, forKey: .publicKey)
        publicSecureKey = try values.decodeIfPresent(SecureKey.self, forKey: .publicSecureKey)
        publicKeyAgreementSecureKey = try values.decodeIfPresent(SecureKey.self, forKey: .publicKeyAgreementSecureKey)
//        if let propertiesContainer = try? values.decodeIfPresent(DynamicProperties.self, forKey: .properties) {
//            self.properties = propertiesContainer.propertyValues
//        }
        
        self.properties = try? values.decodeIfPresent(Object.self, forKey: .properties)
        if self.properties == nil {
            self.properties = [String: ValueType]()
        }
        
        grants.append(Grant(keypath: "displayName", permission: "r--"))
        
        self.identityVault = CellBase.defaultIdentityVault
    }
    
    public func encode(to encoder: Encoder) throws {
        //        print("encoding: \(self)")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encodeIfPresent(displayName, forKey: .displayName)
//        try container.encodeIfPresent(publicKey, forKey: .publicKey)
        try container.encodeIfPresent(properties, forKey: .properties)
        try container.encodeIfPresent(publicSecureKey, forKey: .publicSecureKey)
        try container.encodeIfPresent(publicKeyAgreementSecureKey, forKey: .publicKeyAgreementSecureKey)
        // then ecode other aspects of Identity
    }
    
//    deinit {
//        print("Identity deinited! uuid: \(self.uuid)")
//    }
    
    public func granted(_ grant: Grant) -> Bool {
        // auto grant displaynames should be governed by policies (local)
        return grants.contains(grant)
    }
    
    public func addGrant(_ grant: Grant) {
        if !grants.contains(grant) && !(grant.keypath.contains("privateKey") ) {
            grants.append(grant)
        }
        
    }
    
    public func removeGrant(_ grant: Grant) {
        grants.removeAll {
            $0 == grant
        }
    }
    
//    public func valueForKey(key: String, requester: Identity) -> AnyPublisher<ValueType, Error> {
//        let subject = PassthroughSubject<ValueType, Error>()
//        DispatchQueue.global().async {
//            // Validate that identity has access
//            if requester == self {
//                if let value = self.properties?[key] {
//                    subject.send(value)
//                }
//            }
//        }
//        
//        return subject.eraseToAnyPublisher()
//    }
    
    public func addProperty(property: ValueType, for key: String) {
        self.properties![key] = property
    }
    
    public func setValueForKey(key: String, value valuePublisher: AnyPublisher<ValueType, Never>, requester: Identity) {
        CellBase.diagnosticLog("Identity.setValueForKey key=\(key)", domain: .identity)
        let localSelf = self
        valueCancellable = valuePublisher.sink(receiveCompletion:{
            CellBase.diagnosticLog("Identity.setValueForKey completion=\($0)", domain: .identity)
        } , receiveValue: { value in
            localSelf.addProperty(property: value, for: key)
                Task {
                    await localSelf.identityVault?.saveIdentity(localSelf)
                }
        })
    }
    
    public func sign(string message: String) async -> Data? {
        if let messageData = message.data(using: .utf8) {
            do {
                return try await sign(data: messageData)
            } catch { print("Signing failed with error: \(error)") }
            
        }
        return nil
    }
    
    public func sign(data messageData: Data) async throws -> Data? {
        var signedData: Data?
        if let currentIdentityVault = self.identityVault {
            signedData =  try await currentIdentityVault.signMessageForIdentity(messageData: messageData, identity: self)
        }
        return signedData
    }
    
    public func verify(signature signatureData: Data, for messageData: Data) async -> Bool {
        if let currentIdentityVault = self.identityVault {
            do {
                return try await currentIdentityVault.verifySignature(signature: signatureData, messageData: messageData, for: self)
            } catch {
                print("Verifing signature for \(uuid) failed with error: \(error)")
            }
    }
     return false
    }
    
    public func get(keypath: String, requester: Identity) async throws -> ValueType {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        let entityAnchorEmit = try await resolver.cellAtEndpoint(endpoint: self.entityAnchorReference, requester: requester)
        
        if let entityAnchorMeddle = entityAnchorEmit as? Meddle {
            let shortenedKeypath = deletePrefix("identity.", from: keypath)
            return try await entityAnchorMeddle.get(keypath: shortenedKeypath, requester: self)
        }
        
        return .string("Something went wrong while get from identity (\(self.uuid)") // Should not reach here
    }
    var entityAnchorEmit: Emit?
    
    public func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        if entityAnchorEmit == nil {
            entityAnchorEmit = try await resolver.cellAtEndpoint(endpoint: self.entityAnchorReference, requester: requester)
        }
        if let entityAnchorMeddle = entityAnchorEmit as? Meddle {
            let shortenedKeypath = deletePrefix("identity.", from: keypath)
            return try await entityAnchorMeddle.set(keypath: shortenedKeypath, value: value, requester: self)
        }
        return nil // Should not reach here
    }
    
    func deletePrefix(_ prefix: String, from string: String) -> String {
        guard string.hasPrefix(prefix) else { return string }
        return String(string.dropFirst(prefix.count))
    }
    
}



public final class  WebIdentity: Sendable {
    public let uuid: String
    public let displayName: String
    public let sessionId: String
    
    public let publicSecureKey: SecureKey
    
    init(uuid: String, displayName: String, publicSecureKey: SecureKey, sessionId: String) {
        self.uuid = uuid
        self.displayName = displayName
        self.publicSecureKey = publicSecureKey
        self.sessionId = sessionId
    }
}
