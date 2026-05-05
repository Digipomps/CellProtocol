// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  EntityAnchorCell.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 27/05/2025.
//
import CellBase
import Foundation


public class EntityAnchorCell: GeneralCell {
    static let storageFilename = "keypathstorage.json"
    private var storage: Entity
   
    // Should  support set/get keypath and persistance of json
    
    required init(owner: Identity) async {
        self.storage = Entity() // hmmm...
        await super.init(owner: owner)
        await initialLoading()
        
        

        // Read storagejson - we may outsource persistence to a separate CS
        
        
        
        print("Initing Entity Anchor (Apple) cell for owner: \(owner.uuid)")
       
        
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }
    
    private func setupPermissions(owner: Identity) async  {
        self.agreementTemplate.addGrant("rw--", for: "person")
        self.agreementTemplate.addGrant("rw--", for: "purposes") // I think this is the one that should hold realations and Interests too?
        self.agreementTemplate.addGrant("rw--", for: "relations")
        self.agreementTemplate.addGrant("rw--", for: "agreements")
        self.agreementTemplate.addGrant("rw--", for: "signedAgreementEntity")
        self.agreementTemplate.addGrant("rw--", for: "entityRepresentation")
        self.agreementTemplate.addGrant("rw--", for: "chronicle")
        self.agreementTemplate.addGrant("rw--", for: "identityLinks")
        
        // This cell will only be accessed from it's owner so adding ggrants will not be necessary
        
    }
    
    private func setupKeys(owner: Identity) async  {
        
        await addIntercept(requester: owner, intercept: { flowElement, requester in
//                print("Incoming flowElement to Keypath storage (PDS)") ...hmmm?
            return nil
        })

    await addInterceptForGet(requester: owner, key: "person", getValueIntercept: {
        keypath, requester in
        if await self.validateAccess("r---", at: "person", for: requester) {
            return try self.storage.get(keypath: keypath)
            
        } else {
            throw KeypathStorageErrors.denied
        }
    })
        
        await addInterceptForGet(requester: owner, key: "proofs", getValueIntercept: {
            keypath, requester in
            if await self.validateAccess("r---", at: "proofs", for: requester) {
                return try self.storage.get(keypath: keypath)
                
            } else {
                throw KeypathStorageErrors.denied
            }
        })

        await addInterceptForGet(requester: owner, key: "identityLinks", getValueIntercept: {
            keypath, requester in
            if await self.validateAccess("r---", at: "identityLinks", for: requester) {
                return try self.identityLinksValue(for: keypath)
            } else {
                throw KeypathStorageErrors.denied
            }
        })

        await addInterceptForGet(requester: owner, key: "chronicle", getValueIntercept: {
            keypath, requester in
            if await self.validateAccess("r---", at: "chronicle", for: requester) {
                return try self.storage.get(keypath: keypath)
            } else {
                throw KeypathStorageErrors.denied
            }
        })

        await addInterceptForGet(requester: owner, key: "signedAgreementEntity", getValueIntercept: {
            keypath, requester in
            if await self.validateAccess("r---", at: "signedAgreementEntity", for: requester) {
                return try self.storage.get(keypath: keypath)
            } else {
                throw KeypathStorageErrors.denied
            }
        })

        await addInterceptForGet(requester: owner, key: "entityRepresentation", getValueIntercept: {
            keypath, requester in
            if await self.validateAccess("r---", at: "entityRepresentation", for: requester) {
                return try self.storage.get(keypath: keypath)
            } else {
                throw KeypathStorageErrors.denied
            }
        })
    
    await addInterceptForSet(requester: owner, key: "person", setValueIntercept:  { keypath, value, requester in
        if await self.validateAccess("r---", at: "person", for: requester) {
//            print("Entity data set. Keypath: \(keypath) value: \(try value.jsonString())")
            try self.storage.set(keypath: keypath, setValue: value)
            try await self.saveKeypathStorage(entity: self.storage)
            // Send FeedItem notification
            
            let payloadObject:Object = ["keypath" : .string(keypath), "data" : value]
            
            
            let flowElement = FlowElement(title: "PDS update", content: .object(payloadObject), properties: FlowElement.Properties(type: .content, contentType: .object))
        
            
            self.pushFlowElement(flowElement, requester: requester)
        }
        return nil
    })
    
	    await addInterceptForSet(requester: owner, key: "proofs", setValueIntercept:  { keypath, value, requester in
        
            do {
//                print("Entity data set. Keypath: \(keypath) value: \(try value.jsonString())")
                try self.storage.set(keypath: keypath, setValue: value)
                try await self.saveKeypathStorage(entity: self.storage)
                // Send FlowElement notification
                
                let payloadObject:Object = ["keypath" : .string(keypath), "data" : value]
                var flowElement = FlowElement(title: "PDS update", content: .object(payloadObject), properties: FlowElement.Properties(type: .content, contentType: .object))
                
                flowElement.origin = self.uuid
                flowElement.topic = "entity"
                self.pushFlowElement(flowElement, requester: requester)
            } catch {
                print("Set \(keypath) failed with error: \(error)")
            }
    
	        return nil
	    })

        await addInterceptForSet(requester: owner, key: "identityLinks", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return nil }
            return await self.handleIdentityLinksSet(keypath: keypath, value: value, requester: requester)
        })
        for identityLinkAction in [
            "identityLinks.approveEnrollment",
            "identityLinks.completeEnrollment",
            "identityLinks.revoke"
        ] {
            await addInterceptForSet(requester: owner, key: identityLinkAction, setValueIntercept: { [weak self] keypath, value, requester in
                guard let self = self else { return nil }
                return await self.handleIdentityLinksSet(keypath: keypath, value: value, requester: requester)
            })
        }
        
        await addInterceptForSet(requester: owner, key: "relations", setValueIntercept:  {[weak self]  keypath, value, requester in
            guard let self = self else { return nil }
                do {
//                    print("Entity data set. Keypath: \(keypath) value: \(try value.jsonString())")
                    // If keypath points to identities
                    // then check if it exists
                    // if not exists
                    // store identityId and new identity in a new entityId
                    let shortenedKeypath = self.deletePrefix("relations.", from: keypath)
                    let keypathArray = keypath.split(separator: ".")
                    if keypathArray.count > 1 {
                        let subkey = String(keypathArray[1])
                        switch subkey {
                        case "identities":
                            print("Got identities")
                            do {
                                let result = try self.storage.get(keypath: keypath) // Will throw if not found
                                
                            } catch {
                                print("Entity get relations.identities failed with error: \(error)")
                                if case KeyPathError.notFound(let keypathError) = error {
                                    print("Keypath not found KeypathError: \(keypathError)")
                                    let identityUuid = String(keypathArray[keypathArray.count - 1])
                                    let entityUuid = UUID().uuidString
                                    
                                    do {
                                        try self.storage.set(.string(entityUuid), keypath: keypath)
                                        
                                        let entityKeypath = "relations.entities.\(entityUuid).identities.\(identityUuid)"
                                        try self.storage.set(value, keypath: entityKeypath) // We shhould check if it should be merged?
                                    } catch {
                                        print("Setting data in entity failed with error: \(error)")
                                    }
                                }
                            }
                            
                        
                        case "issuers":
                            print("Got issuers")
                            do {
                                let result = try self.storage.get(keypath: keypath) // Will throw if not found
                                
                            } catch  KeyPathError.notFound(let keypathError) {
                                _ = try self.storage.set(value, keypath: keypath)
                            } catch {
                                print("Entity get relations.issuers failed with error: \(error)")
                            }
                            
                        default:
                            print("relations unknown subkey: \(subkey)")
                        }
                        
                    }
                    
                    try await self.saveKeypathStorage(entity: self.storage)
                    // Send FlowElement notification
                    
                    let payloadObject:Object = ["keypath" : .string(keypath), "data" : value]
                    var flowElement = FlowElement(title: "PDS update", content: .object(payloadObject), properties: FlowElement.Properties(type: .content, contentType: .object))
                    
                    flowElement.origin = self.uuid
                    flowElement.topic = "entity"
                    self.pushFlowElement(flowElement, requester: requester)
                } catch {
                    print("Set \(keypath) failed with error: \(error)")
                }
        
            return nil
        })
    // Thhis is just for testing
        await addInterceptForSet(requester: owner, key: "identity", setValueIntercept:  { keypath, value, requester in
            
                do {
//                    print("Entity data set. Keypath: \(keypath) value: \(try value.jsonString())")
                    try await self.storage.set(keypath: keypath, setValue: value)
                    try await self.saveKeypathStorage(entity: self.storage)
                    // Send FlowElement notification
                    
                    let payloadObject:Object = ["keypath" : .string(keypath), "data" : value]
                    var flowElement = FlowElement(title: "PDS update", content: .object(payloadObject), properties: FlowElement.Properties(type: .content, contentType: .object))
                    
                    flowElement.origin = self.uuid
                    flowElement.topic = "entity"
                    self.pushFlowElement(flowElement, requester: requester)
                } catch {
                    print("Set \(keypath) failed with error: \(error)")
                }
        
            return nil
        })
        
    await addIntercept(requester: owner, intercept: {
        flowElement, identity in
        var correlationId: String?
        var operation: String?
        do {
            print("Got flowElement: \(flowElement) with payload: \(try flowElement.content.valueType().jsonString())")
            
            
            guard case let  .object(paramObject) = flowElement.content else {
                throw SetValueError.paramErr
            }
            correlationId = try? paramObject["correlationId"]?.stringValue()
            operation = try? paramObject["operation"]?.stringValue()

            if operation == EntityBatchPersistEnvelope.operation {
                guard let envelopeValue = paramObject["envelope"] else {
                    throw SetValueError.noParamValue("envelope")
                }
                guard case let .object(envelopeObject) = envelopeValue else {
                    throw SetValueError.wrongParamType
                }
                let envelope = try EntityBatchPersistEnvelope(object: envelopeObject)
                let persistedPaths = try await self.persistBatchEnvelope(envelope)

                var payloadObject: Object = [
                    "status": .string("persisted"),
                    "schema": .string(envelope.schema),
                    "persistedPaths": .list(persistedPaths.map { .string($0) })
                ]
                if let correlationId {
                    payloadObject["correlationId"] = .string(correlationId)
                }
                if let operation {
                    payloadObject["operation"] = .string(operation)
                }

                var response = FlowElement(title: "PDS update", content: .object(payloadObject), properties: FlowElement.Properties(type: .content, contentType: .object))
                response.origin = self.uuid
                response.topic = flowElement.topic
                return response
            }

            guard let keypathValue = paramObject["keypath"] else {
                throw SetValueError.noParamValue("keypath")
            }
            guard case let .string(keypath) = keypathValue else {
                throw SetValueError.wrongParamType
            }

            guard let value = paramObject["value"] else {
                throw SetValueError.noParamValue("value")
            }

            try await self.set(keypath: keypath, value: value)
            
            var payloadObject:Object = [
                "keypath" : .string(keypath),
                "data" : value,
                "status": .string("persisted")
            ]
            if let correlationId {
                payloadObject["correlationId"] = .string(correlationId)
            }
            if let operation {
                payloadObject["operation"] = .string(operation)
            }
            
            
            var response = FlowElement(title: "PDS update", content: .object(payloadObject), properties: FlowElement.Properties(type: .content, contentType: .object))
            response.origin = self.uuid
            response.topic = flowElement.topic
            return response
            
            
        } catch {
            print("Feed item handling failed with error: \(error)")
            if correlationId != nil || operation != nil {
                var payloadObject: Object = [
                    "status": .string("failed"),
                    "error": .string(String(describing: error))
                ]
                if let correlationId {
                    payloadObject["correlationId"] = .string(correlationId)
                }
                if let operation {
                    payloadObject["operation"] = .string(operation)
                }
                var response = FlowElement(title: "PDS update", content: .object(payloadObject), properties: FlowElement.Properties(type: .content, contentType: .object))
                response.origin = self.uuid
                response.topic = flowElement.topic
                return response
            }
        }
        return flowElement // This may be good for debugging
    })
    
    await addInterceptForGet(requester: owner, key: "reloadStorage", getValueIntercept: {
        keypath, requester in
        if await self.validateAccess("--x-", at: "reloadStorage", for: requester) {
            try await self.reloadStorage()
            return .string("reloaded")
        } else {
            throw KeypathStorageErrors.denied
        }
    })
        
        
        await addInterceptForGet(requester: owner, key: "proofs", getValueIntercept: {
            [weak self] keypath, requester in
            guard let self = self else { return .string("error")}
            // TODO: fix weak self
                if let value = try await self.get(keypath: keypath) {
                    return value
                }
                throw KeypathStorageErrors.notFound
            
        })
        
        await addInterceptForGet(requester: owner, key: "relations", getValueIntercept: {
            [weak self] keypath, requester in
            guard let self = self else { return .string("error")}
            // TODO: fix weak self
                if let value = try await self.get(keypath: keypath) {
                    return value
                }
                throw KeypathStorageErrors.notFound
            
        })
        print("*********** Finished setup keys in Entity Anchor ***********")
    }
    
    private func initialLoading() async {
        do {
            self.storage = try await self.loadKeypathStorage()
//        } catch {
            
        } catch {
            
            print("Loading entity anchor storage data failed with error: \(error)")
	            let stubsEntity: Object = ["person" : .object(Object()), "relations" : .object(Object()), "proofs" : .object(Object()), "identityLinks" : .object(Object()), "agremments" : .object(Object()),  "chronicle" : .object(Object())]
            do {
                try await self.saveKeypathStorage(entity: stubsEntity)
            } catch {
                print("Could not create and save an entity either. Failed with error: \(error)")
            }
        }
    }
    
    enum CodingKeys: CodingKey {
        case storage
        case cell
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tempStorage = try container.decodeIfPresent(Entity.self, forKey: .storage)
        if let tmpStorage = tempStorage {
            self.storage = tmpStorage
        } else {
            self.storage = Entity()
        }
        try super.init(from: decoder)
        
        // NB! This may not always work and could end up biting us in the butt at some point BEWARE!!!
        Task {
            await initialLoading()
            if let vault = CellBase.defaultIdentityVault,
               let requester = await vault.identity(for: "private", makeNewIfNotFound: true ) { // Mayby fetch the Identity from json - or does that pose a security issue -> yes! Look into that...
                await setupPermissions(owner: requester)
                await setupKeys(owner: requester)
            }
        }
        
    }
    
    public override func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(storage, forKey: .storage)
      try super.encode(to: encoder)
    }

    func loadKeypathStorage() async throws -> Entity {
        let entityJsonData = try await self.getFileDataInCellDirectory(filename: EntityAnchorCell.storageFilename)
        let loadedEntity = try JSONDecoder().decode(Entity.self, from: entityJsonData)
        return loadedEntity
    }
    
    func saveKeypathStorage(entity: Entity) async throws {
        let encoder = JSONEncoder()
        let entityData = try encoder.encode(entity)
        
        try await self.writeFileDataInCellDirectory(fileData: entityData, filename: EntityAnchorCell.storageFilename)
        
    }
    
    func set(keypath: String, value: ValueType) async throws {
        // Validate
        // Check if it is a change
        
        // write to storage
        try self.storage.set(keypath: keypath, setValue: value)
        try await saveKeypathStorage(entity: self.storage)
        
        // Check whether we should post a storage saved notification? (Flow Element)
        
        
        let setDataObject: Object = ["keypath" : .string(keypath), "value" : value, "timestamp" : .float(Date.now.timeIntervalSince1970)]
        let flowElement = FlowElement(title: "Set data", content: .object(setDataObject), properties: FlowElement.Properties(type: .event, contentType: .object))
    }

    private func persistBatchEnvelope(_ envelope: EntityBatchPersistEnvelope) async throws -> [String] {
        var updatedStorage = self.storage
        for mutation in envelope.mutations {
            try updatedStorage.set(keypath: mutation.keypath, setValue: mutation.value)
        }
        self.storage = updatedStorage
        try await saveKeypathStorage(entity: self.storage)
        return envelope.mutations.map(\.keypath)
    }
    
    func get(keypath: String) async throws -> ValueType? {
        try await self.storage.get(keypath: keypath)
    }
    
    func reloadStorage() async throws {
        self.storage = try await self.loadKeypathStorage()
        let setDataObject: Object = ["reload" : .string("reload_persistant_data"), "timestamp" : .float(Date.now.timeIntervalSince1970)]
        var flowElement = FlowElement(title: "Reload", content: .object(setDataObject), properties: FlowElement.Properties(type: .event, contentType: .object))
        flowElement.origin = self.uuid
        
        if let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: true ) {
            self.pushFlowElement(flowElement, requester: requester)
        }
        
    }

    private func identityLinksValue(for keypath: String) throws -> ValueType {
        if keypath == "identityLinks" || keypath == "identityLinks.state" {
            let records = (try? storage.get(keypath: "identityLinks.records")) ?? .object(Object())
            let used = (try? storage.get(keypath: "identityLinks.usedApprovalJTIs")) ?? .object(Object())
            return .object([
                "status": .string("ready"),
                "records": records,
                "usedApprovalJTIs": used,
                "summary": .string("EntityAnchor identityLinks er klar for approveEnrollment, completeEnrollment og revoke.")
            ])
        }
        return try storage.get(keypath: keypath)
    }

    private func handleIdentityLinksSet(keypath: String, value: ValueType, requester: Identity) async -> ValueType? {
        do {
            switch keypath {
            case "identityLinks.approveEnrollment":
                return try await approveIdentityEnrollment(value: value, requester: requester)
            case "identityLinks.completeEnrollment":
                return try await completeIdentityEnrollment(value: value, requester: requester)
            case "identityLinks.revoke":
                return try await revokeIdentityLink(value: value, requester: requester)
            default:
                try storage.set(keypath: keypath, setValue: value)
                try await saveKeypathStorage(entity: storage)
                pushIdentityLinkEvent(keypath: keypath, value: value, requester: requester)
                return .object(["status": .string("stored"), "keypath": .string(keypath)])
            }
        } catch {
            return .object([
                "status": .string("error"),
                "keypath": .string(keypath),
                "message": .string(String(describing: error))
            ])
        }
    }

    private func approveIdentityEnrollment(value: ValueType, requester: Identity) async throws -> ValueType {
        let envelope = try decodeValue(value, as: IdentityLinkApprovalEnvelope.self)
        let package = try await IdentityLinkProtocolService.approveEnrollment(
            envelope,
            issuerIdentity: requester
        )
        let packageValue = try IdentityLinkProtocolService.value(from: package)
        let approvalKey = safeIdentityLinkKey(package.approval.approvalID)
        let keypath = "identityLinks.approvals.\(approvalKey)"
        try storage.set(keypath: keypath, setValue: packageValue)
        try await saveKeypathStorage(entity: storage)
        pushIdentityLinkEvent(keypath: keypath, value: packageValue, requester: requester)
        return .object([
            "status": .string("approved"),
            "approvalID": .string(package.approval.approvalID),
            "approvalPackage": packageValue
        ])
    }

    private func completeIdentityEnrollment(value: ValueType, requester: Identity) async throws -> ValueType {
        let envelope = try decodeValue(value, as: IdentityLinkCompletionEnvelope.self)
        let result = try await IdentityLinkProtocolService.verifyCompletion(
            envelope,
            usedApprovalJTIs: usedApprovalJTIs()
        )
        let recordValue = try IdentityLinkProtocolService.value(from: result.record)
        let recordKey = safeIdentityLinkKey(result.record.linkID)
        let jtiKey = safeIdentityLinkKey(result.approvalJTI)
        let recordKeypath = "identityLinks.records.\(recordKey)"
        let proofKeypath = "proofs.identityLinks.\(recordKey)"
        let replayKeypath = "identityLinks.usedApprovalJTIs.\(jtiKey)"
        let proofValue: ValueType = .object([
            "record": recordValue,
            "requestHash": .data(result.requestHash),
            "approvalJTI": .string(result.approvalJTI),
            "credentialID": .string(result.credentialID),
            "presentationID": .string(result.presentationID),
            "completedAt": .string(result.record.linkedAt)
        ])

        try storage.set(keypath: recordKeypath, setValue: recordValue)
        try storage.set(keypath: proofKeypath, setValue: proofValue)
        try storage.set(keypath: replayKeypath, setValue: .string(result.approvalJTI))
        try await saveKeypathStorage(entity: storage)
        pushIdentityLinkEvent(keypath: recordKeypath, value: recordValue, requester: requester)

        return .object([
            "status": .string("completed"),
            "record": recordValue,
            "recordKeypath": .string(recordKeypath),
            "proofKeypath": .string(proofKeypath),
            "approvalJTI": .string(result.approvalJTI)
        ])
    }

    private func revokeIdentityLink(value: ValueType, requester: Identity) async throws -> ValueType {
        let linkID: String
        if case let .string(rawLinkID) = value {
            linkID = rawLinkID
        } else {
            let object = try decodeValue(value, as: Object.self)
            guard case let .string(rawLinkID)? = object["linkID"] else {
                throw IdentityLinkCompletionError.missingRequiredContext("linkID")
            }
            linkID = rawLinkID
        }

        let recordKey = safeIdentityLinkKey(linkID)
        let recordKeypath = "identityLinks.records.\(recordKey)"
        let recordValue = try storage.get(keypath: recordKeypath)
        let record = try decodeValue(recordValue, as: IdentityLinkRecord.self)
        let revoked = IdentityLinkRecord(
            linkID: record.linkID,
            entityBinding: record.entityBinding,
            linkedIdentity: record.linkedIdentity,
            approvedDomains: record.approvedDomains,
            approvedIdentityContexts: record.approvedIdentityContexts,
            approvedScopes: record.approvedScopes,
            issuerIdentityUUID: record.issuerIdentityUUID,
            issuerType: record.issuerType,
            status: .revoked,
            linkedAt: record.linkedAt,
            lastUsedAt: record.lastUsedAt,
            revokedAt: IdentityLinkProtocolService.iso8601(Date()),
            revocationReference: record.revocationReference
        )
        let revokedValue = try IdentityLinkProtocolService.value(from: revoked)
        try storage.set(keypath: recordKeypath, setValue: revokedValue)
        try storage.set(keypath: "proofs.identityLinks.\(recordKey).record", setValue: revokedValue)
        try await saveKeypathStorage(entity: storage)
        pushIdentityLinkEvent(keypath: recordKeypath, value: revokedValue, requester: requester)
        return .object([
            "status": .string("revoked"),
            "record": revokedValue,
            "recordKeypath": .string(recordKeypath)
        ])
    }

    private func usedApprovalJTIs() -> Set<String> {
        guard let usedValue = try? storage.get(keypath: "identityLinks.usedApprovalJTIs"),
              case let .object(usedObject) = usedValue else {
            return []
        }
        return Set(usedObject.compactMap { key, value in
            if case let .string(jti) = value {
                return jti
            }
            return key
        })
    }

    private func decodeValue<T: Decodable>(_ value: ValueType, as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func safeIdentityLinkKey(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private func pushIdentityLinkEvent(keypath: String, value: ValueType, requester: Identity) {
        let payloadObject: Object = [
            "keypath": .string(keypath),
            "data": value,
            "status": .string("persisted")
        ]
        var flowElement = FlowElement(title: "Identity link update", content: .object(payloadObject), properties: FlowElement.Properties(type: .content, contentType: .object))
        flowElement.origin = self.uuid
        flowElement.topic = "entity.identityLinks"
        self.pushFlowElement(flowElement, requester: requester)
    }

    func deletePrefix(_ prefix: String, from string: String) -> String {
        guard string.hasPrefix(prefix) else { return string }
        return String(string.dropFirst(prefix.count))
    }
    
}
