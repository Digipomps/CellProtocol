// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  EntityAnchorCell.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 27/05/2025.
//
@_spi(HAVENRuntime) import CellBase
import Foundation


public class EntityAnchorCell: GeneralCell {
    static let storageFilename = "keypathstorage.json"
    static let authorityJournalFilename = "entity-authority-journal.json"
    private var storage: Entity
    private var authorityJournal = EntityAuthorityJournalDocument()
    private var persistenceFailureReason: String?
    private let authorityCommitGate = EntityAuthorityCommitGate()
   
    // Should  support set/get keypath and persistance of json
    
    required init(owner: Identity) async {
        self.storage = Entity() // hmmm...
        await super.init(owner: owner)
        await initialLoading()
        
        

        // Read storagejson - we may outsource persistence to a separate CS
        
        
        
        print("Initing Entity Anchor (Apple) cell for owner: \(owner.uuid)")
       
        
        try? await ensureRuntimeReady()
    }
    
    private func setupPermissions(owner: Identity) async  {
        self.agreementTemplate.ensureGrant("rw--", for: "person")
        self.agreementTemplate.ensureGrant("rw--", for: "purposes") // I think this is the one that should hold realations and Interests too?
        self.agreementTemplate.ensureGrant("rw--", for: "relations")
        self.agreementTemplate.ensureGrant("rw--", for: "agreements")
        self.agreementTemplate.ensureGrant("rw--", for: "signedAgreementEntity")
        self.agreementTemplate.ensureGrant("rw--", for: "entityRepresentation")
        self.agreementTemplate.ensureGrant("rw--", for: "chronicle")
        self.agreementTemplate.ensureGrant("rw--", for: "identityLinks")
        self.agreementTemplate.ensureGrant("r---", for: "entityAuthority")
        
        // This cell will only be accessed from it's owner so adding ggrants will not be necessary
        
    }
    
    private func setupKeys(owner: Identity) async  {
        await registerContracts(requester: owner)
        
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

        await addInterceptForGet(requester: owner, key: "identityLinks.state", getValueIntercept: {
            _, requester in
            if await self.validateAccess("r---", at: "identityLinks", for: requester) {
                return try self.identityLinksValue(for: "identityLinks.state")
            }
            throw KeypathStorageErrors.denied
        })

        await addInterceptForGet(requester: owner, key: "chronicle", getValueIntercept: {
            keypath, requester in
            if await self.validateAccess("r---", at: "chronicle", for: requester) {
                return try self.storage.get(keypath: keypath)
            } else {
                throw KeypathStorageErrors.denied
            }
        })

        await addInterceptForGet(requester: owner, key: "entityAuthority", getValueIntercept: {
            _, requester in
            if await self.validateAccess("r---", at: "entityAuthority", for: requester) {
                return try await self.authorityCommitStateValue()
            }
            throw KeypathStorageErrors.denied
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
        if await self.validateAccess("-w--", at: "person", for: requester) {
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
            guard await self.validateAccess("-w--", at: "proofs", for: requester) else {
                throw KeypathStorageErrors.denied
            }
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
            guard await self.validateAccess("-w--", at: "relations", for: requester) else {
                throw KeypathStorageErrors.denied
            }
                do {
//                    print("Entity data set. Keypath: \(keypath) value: \(try value.jsonString())")
                    // If keypath points to identities
                    // then check if it exists
                    // if not exists
                    // store identityId and new identity in a new entityId
                    let keypathArray = keypath.split(separator: ".")
                    if keypathArray.count > 1 {
                        let subkey = String(keypathArray[1])
                        switch subkey {
                        case "identities":
                            print("Got identities")
                            do {
                                _ = try self.storage.get(keypath: keypath) // Will throw if not found
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
                                _ = try self.storage.get(keypath: keypath) // Will throw if not found
                            } catch  KeyPathError.notFound(_) {
                                _ = try self.storage.set(value, keypath: keypath)
                            } catch {
                                print("Entity get relations.issuers failed with error: \(error)")
                            }
                            
                        default:
                            print("relations unknown subkey: \(subkey)")
                            try self.storage.set(keypath: keypath, setValue: value)
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
    await addIntercept(requester: owner, intercept: {
        flowElement, identity in
        var correlationId: String?
        var operation: String?
        do {
            CellBase.diagnosticLog(
                "EntityAnchor received flowElement title=\(flowElement.title) topic=\(flowElement.topic)",
                domain: .identity
            )

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
                let result = try await self.persistBatchEnvelope(envelope, requester: identity)

                var payloadObject: Object = [
                    "status": .string(result.receipt == nil ? "persisted" : "authority_committed"),
                    "schema": .string(envelope.schema),
                    "persistedPaths": .list(result.persistedPaths.map { .string($0) }),
                    "idempotentReplay": .bool(result.idempotentReplay)
                ]
                if let receipt = result.receipt {
                    payloadObject["commitReceipt"] = try receipt.valueType()
                }
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
                var payloadObject = self.authorityCommitFailurePayload(error)
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

    private func registerContracts(requester: Identity) async {
        let storedValue = Self.storedValueSchema()
        let identityLinkResult = ExploreContract.oneOfSchema(
            options: [ExploreContract.schema(type: "object"), ExploreContract.schema(type: "string")],
            description: "Returns identity-link state/result metadata or an error string."
        )
        let identityLinkEffect = ExploreContract.flowEffect(trigger: .set, topic: "entity.identityLinks", contentType: "object")

        await registerExploreContract(requester: requester, key: "person", method: .set, input: storedValue, returns: .null, permissions: ["-w--"], required: false, description: .string("Stores owner entity person data."))
        await registerExploreContract(requester: requester, key: "person", method: .get, input: .null, returns: storedValue, permissions: ["r---"], required: false, description: .string("Reads owner entity person data."))
        await registerExploreContract(requester: requester, key: "proofs", method: .set, input: storedValue, returns: .null, permissions: [], required: false, description: .string("Stores owner-only proof data."))
        await registerExploreContract(requester: requester, key: "proofs", method: .get, input: .null, returns: storedValue, permissions: [], required: false, description: .string("Reads owner-only proof data."))
        await registerExploreContract(requester: requester, key: "relations", method: .set, input: storedValue, returns: .null, permissions: ["-w--"], required: false, description: .string("Stores owner entity relation data."))
        await registerExploreContract(requester: requester, key: "relations", method: .get, input: .null, returns: storedValue, permissions: ["r---"], required: false, description: .string("Reads owner entity relation data."))
        await registerExploreContract(requester: requester, key: "chronicle", method: .get, input: .null, returns: storedValue, permissions: ["r---"], required: false, description: .string("Reads the owner entity chronicle."))
        await registerExploreContract(requester: requester, key: "entityAuthority", method: .get, input: .null, returns: ExploreContract.schema(type: "object"), permissions: ["r---"], required: false, description: .string("Reads the signed Entity authority epoch, revision, head hash, and declared durability boundary."))
        await registerExploreContract(requester: requester, key: "signedAgreementEntity", method: .get, input: .null, returns: storedValue, permissions: ["r---"], required: false, description: .string("Reads signed Agreement entity data."))
        await registerExploreContract(requester: requester, key: "entityRepresentation", method: .get, input: .null, returns: storedValue, permissions: ["r---"], required: false, description: .string("Reads the owner entity representation."))
        await registerExploreContract(requester: requester, key: "identityLinks", method: .set, input: storedValue, returns: identityLinkResult, permissions: ["-w--"], required: false, flowEffects: [identityLinkEffect], description: .string("Stores identity-link state below the owner entity."))
        await registerExploreContract(requester: requester, key: "identityLinks", method: .get, input: .null, returns: identityLinkResult, permissions: ["r---"], required: false, description: .string("Reads identity-link state below the owner entity."))
        await registerExploreContract(requester: requester, key: "identityLinks.state", method: .get, input: .null, returns: identityLinkResult, permissions: ["r---"], required: false, description: .string("Reads normalized identity-link runtime state."))
        await registerExploreContract(requester: requester, key: "identityLinks.approveEnrollment", method: .set, input: ExploreContract.schema(type: "object"), returns: identityLinkResult, permissions: ["-w--"], required: true, flowEffects: [identityLinkEffect], description: .string("Approves a cryptographically bound identity enrollment."))
        await registerExploreContract(requester: requester, key: "identityLinks.completeEnrollment", method: .set, input: ExploreContract.schema(type: "object"), returns: identityLinkResult, permissions: ["-w--"], required: true, flowEffects: [identityLinkEffect], description: .string("Completes a previously approved identity enrollment."))
        await registerExploreContract(requester: requester, key: "identityLinks.revoke", method: .set, input: ExploreContract.oneOfSchema(options: [ExploreContract.schema(type: "string"), ExploreContract.objectSchema(properties: ["linkID": ExploreContract.schema(type: "string")], requiredKeys: ["linkID"])]), returns: identityLinkResult, permissions: ["-w--"], required: true, flowEffects: [identityLinkEffect], description: .string("Revokes an exact identity link."))
        await registerExploreContract(requester: requester, key: "reloadStorage", method: .get, input: .null, returns: ExploreContract.schema(type: "string"), permissions: [], required: false, description: .string("Legacy owner-only compatibility trigger that reloads persisted storage."))
    }

    private static func storedValueSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                ExploreContract.schema(type: "object"),
                ExploreContract.schema(type: "list"),
                ExploreContract.schema(type: "string"),
                ExploreContract.schema(type: "bool"),
                ExploreContract.schema(type: "integer"),
                ExploreContract.schema(type: "float"),
                ExploreContract.schema(type: "data"),
                ExploreContract.schema(type: "flowElement"),
                ExploreContract.schema(type: "keyValue"),
                ExploreContract.schema(type: "setValueState"),
                ExploreContract.schema(type: "setValueResponse"),
                ExploreContract.schema(type: "cellConfiguration"),
                ExploreContract.schema(type: "cellReference"),
                ExploreContract.schema(type: "verifiableCredential"),
                ExploreContract.schema(type: "identity"),
                ExploreContract.schema(type: "connectContext"),
                ExploreContract.schema(type: "connectState"),
                ExploreContract.schema(type: "contractState"),
                ExploreContract.schema(type: "signData"),
                ExploreContract.schema(type: "signature"),
                ExploreContract.schema(type: "agreementPayload"),
                ExploreContract.schema(type: "description"),
                ExploreContract.schema(type: "cell"),
                .null
            ],
            description: "A supported persisted Entity ValueType."
        )
    }
    
    private func initialLoading() async {
        do {
            let loadedStorage = try await self.loadKeypathStorage()
            let loadedJournal = try await self.loadAuthorityJournalIfPresent()
            try loadedJournal.validateStructure()
            guard try loadedJournal.verifyReceipts(authority: storedOwnerIdentity) else {
                throw EntityAuthorityCommitError.journalCorrupt("authority_receipt_signature")
            }
            let recoveredStorage = try loadedJournal.replay(on: loadedStorage)
            self.authorityJournal = loadedJournal
            self.storage = recoveredStorage
            self.persistenceFailureReason = nil
            if try Self.canonicalEntityData(recoveredStorage) != Self.canonicalEntityData(loadedStorage) {
                try await self.writeKeypathStorage(entity: recoveredStorage)
            }
        } catch {
            if Self.isMissingFile(error) {
                let stubsEntity: Object = ["person" : .object(Object()), "relations" : .object(Object()), "proofs" : .object(Object()), "identityLinks" : .object(Object()), "agremments" : .object(Object()),  "chronicle" : .object(Object())]
                do {
                    let existingJournal = try await self.loadAuthorityJournalIfPresent()
                    try existingJournal.validateStructure()
                    guard try existingJournal.verifyReceipts(authority: storedOwnerIdentity) else {
                        throw EntityAuthorityCommitError.journalCorrupt("authority_receipt_signature")
                    }
                    let recoveredStorage = try existingJournal.replay(on: stubsEntity)
                    try await self.writeKeypathStorage(entity: recoveredStorage)
                    self.authorityJournal = existingJournal
                    self.storage = recoveredStorage
                    self.persistenceFailureReason = nil
                } catch {
                    self.persistenceFailureReason = String(describing: error)
                    CellBase.diagnosticLog("Could not initialize EntityAnchor storage", domain: .identity)
                }
            } else {
                self.persistenceFailureReason = String(describing: error)
                CellBase.diagnosticLog("EntityAnchor storage validation failed; existing files were not overwritten", domain: .identity)
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
        
    }

    public override func installCellRuntimeBindingsForAccess() async throws {
        let bindingOwner = storedOwnerIdentity
        await setupPermissions(owner: bindingOwner)
        await setupKeys(owner: bindingOwner)
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

    private func loadAuthorityJournalIfPresent() async throws -> EntityAuthorityJournalDocument {
        do {
            let data = try await self.getFileDataInCellDirectory(filename: EntityAnchorCell.authorityJournalFilename)
            return try JSONDecoder().decode(EntityAuthorityJournalDocument.self, from: data)
        } catch {
            if Self.isMissingFile(error) {
                return EntityAuthorityJournalDocument()
            }
            throw error
        }
    }

    func saveKeypathStorage(entity: Entity) async throws {
        await authorityCommitGate.acquire()
        do {
            try ensurePersistenceAvailable()
            let recovered = try authorityJournal.replay(on: entity)
            guard try Self.canonicalEntityData(recovered) == Self.canonicalEntityData(entity) else {
                self.storage = recovered
                throw EntityAuthorityCommitError.journalCorrupt("legacy_write_conflicts_with_committed_keypath")
            }
            try await writeKeypathStorage(entity: entity)
            self.storage = entity
            await authorityCommitGate.release()
        } catch {
            await authorityCommitGate.release()
            throw error
        }
    }

    private func writeKeypathStorage(entity: Entity) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entityData = try encoder.encode(entity)
        try await self.writeFileDataInCellDirectory(fileData: entityData, filename: EntityAnchorCell.storageFilename)
    }

    private func writeAuthorityJournal(_ journal: EntityAuthorityJournalDocument) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        try await self.writeFileDataInCellDirectory(fileData: data, filename: EntityAnchorCell.authorityJournalFilename)
    }

    func set(keypath: String, value: ValueType) async throws {
        // Validate
        // Check if it is a change
        
        // write to storage
        try self.storage.set(keypath: keypath, setValue: value)
        try await saveKeypathStorage(entity: self.storage)
        
        // Check whether we should post a storage saved notification? (Flow Element)
        
        
    }

    private func persistBatchEnvelope(
        _ envelope: EntityBatchPersistEnvelope,
        requester: Identity
    ) async throws -> EntityAnchorBatchPersistResult {
        await authorityCommitGate.acquire()
        do {
            try ensurePersistenceAvailable()
            let verificationAuthority = storedOwnerIdentity
            guard try authorityJournal.verifyReceipts(authority: verificationAuthority) else {
                throw EntityAuthorityCommitError.journalCorrupt("authority_receipt_signature")
            }
            guard await requesterProvesOwnership(requester) else {
                throw EntityAuthorityCommitError.requesterMismatch
            }
            // The stored descriptor is intentionally public-only. After an explicit
            // ownership proof, the active requester supplies the vault-backed signer.
            let authority = requester
            let recoveredStorage = try authorityJournal.replay(on: self.storage)
            let result: EntityAnchorBatchPersistResult
            if envelope.commitRequest == nil {
                var updatedStorage = recoveredStorage
                for mutation in envelope.mutations {
                    try updatedStorage.set(keypath: mutation.keypath, setValue: mutation.value)
                }
                try await writeKeypathStorage(entity: updatedStorage)
                self.storage = updatedStorage
                result = EntityAnchorBatchPersistResult(
                    persistedPaths: envelope.mutations.map(\.keypath),
                    receipt: nil,
                    idempotentReplay: false
                )
            } else {
                let outcome = try await authorityJournal.appending(
                    envelope: envelope,
                    to: recoveredStorage,
                    requester: requester,
                    authority: authority,
                    authorityCellUUID: uuid,
                    committedAtEpochMilliseconds: Int(Date().timeIntervalSince1970 * 1_000)
                )
                try await writeAuthorityJournal(outcome.journal)
                self.authorityJournal = outcome.journal
                self.storage = outcome.snapshot
                try await writeKeypathStorage(entity: outcome.snapshot)
                result = EntityAnchorBatchPersistResult(
                    persistedPaths: envelope.mutations.map(\.keypath),
                    receipt: outcome.receipt,
                    idempotentReplay: outcome.idempotentReplay
                )
            }
            await authorityCommitGate.release()
            return result
        } catch {
            await authorityCommitGate.release()
            throw error
        }
    }
    
    func get(keypath: String) async throws -> ValueType? {
        try self.storage.get(keypath: keypath)
    }
    
    func reloadStorage() async throws {
        await authorityCommitGate.acquire()
        do {
            try ensurePersistenceAvailable()
            let loadedStorage = try await self.loadKeypathStorage()
            let loadedJournal = try await self.loadAuthorityJournalIfPresent()
            try loadedJournal.validateStructure()
            guard try loadedJournal.verifyReceipts(authority: storedOwnerIdentity) else {
                throw EntityAuthorityCommitError.journalCorrupt("authority_receipt_signature")
            }
            self.authorityJournal = loadedJournal
            self.storage = try loadedJournal.replay(on: loadedStorage)
            await authorityCommitGate.release()
        } catch {
            await authorityCommitGate.release()
            throw error
        }
        let setDataObject: Object = ["reload" : .string("reload_persistant_data"), "timestamp" : .float(Date.now.timeIntervalSince1970)]
        var flowElement = FlowElement(title: "Reload", content: .object(setDataObject), properties: FlowElement.Properties(type: .event, contentType: .object))
        flowElement.origin = self.uuid
        
        if let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: true ) {
            self.pushFlowElement(flowElement, requester: requester)
        }
        
    }

    private func identityLinksValue(for keypath: String) throws -> ValueType {
        if keypath == "identityLinks" || keypath == "identityLinks.state" || keypath == "state" {
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

    private func authorityCommitStateValue() async throws -> ValueType {
        await authorityCommitGate.acquire()
        do {
            try ensurePersistenceAvailable()
            let value = try authorityJournal.state().valueType()
            await authorityCommitGate.release()
            return value
        } catch {
            await authorityCommitGate.release()
            throw error
        }
    }

    private func ensurePersistenceAvailable() throws {
        if let persistenceFailureReason {
            throw EntityAuthorityCommitError.journalCorrupt(persistenceFailureReason)
        }
    }

    private func authorityCommitFailurePayload(_ error: Error) -> Object {
        guard let commitError = error as? EntityAuthorityCommitError else {
            return [
                "status": .string("failed"),
                "error": .string(String(describing: error))
            ]
        }
        return [
            "status": .string(commitError.isConflict ? "conflict" : "failed"),
            "errorCode": .string(commitError.code),
            "error": .string(commitError.localizedDescription),
            "commitState": (try? authorityJournal.state().valueType()) ?? .null
        ]
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.fileReadNoSuchFile.rawValue
    }

    private static func canonicalEntityData(_ entity: Entity) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(entity)
    }

    func deletePrefix(_ prefix: String, from string: String) -> String {
        guard string.hasPrefix(prefix) else { return string }
        return String(string.dropFirst(prefix.count))
    }
    
}

private struct EntityAnchorBatchPersistResult {
    var persistedPaths: [String]
    var receipt: EntityAuthorityCommitReceipt?
    var idempotentReplay: Bool
}

private actor EntityAuthorityCommitGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if locked == false {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
