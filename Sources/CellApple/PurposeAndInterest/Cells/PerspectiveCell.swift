// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  PerspectiveCell.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 13/12/2024.
//
import CellBase
import Foundation


/*
 Cell to handle a scaffold wide individual representation of purposes
 
 Example Purpose - Make new connections Goal -> Increase number of entity representations
 Learn new stuff -> Go to presentations or talks engage in discussions
 
 
 Purpose:
 Make new connections
 identity.entityrepresentations.count > present count
 listen for additions to entity representations
 
 The conference's advertised goal is that here you can expand network, learn something new and educate others
 
 
 Make new connections with entities that have the following interests: Privacy, Digital Rights, Funding, Digital market places
 
 
 */

public class PerspectiveCell: GeneralCell {
    
    
//    var running: Bool = false
    
    
    var context: Perspective
    var publicPurposeDict = ["Test": "Test"]
    let prespectiveFilename = "Perspective.json"
    required init(owner: Identity) async {
        
        self.context = Perspective()
        await super.init(owner: owner)
        
        print("PerspectiveCell init. Owner: \(owner.uuid)")
    
            await setupPermissions(owner: owner)
            await setupKeys(owner: owner)

        
        
        do {
            try await loadPerspective()
        } catch {
            print("Loading perspective data failed with error: \(error)")
        }

    }
    
    enum CodingKeys: CodingKey {
        case storage
        case cell
    }
    
    required init(from decoder: any Decoder) throws {
//        let container = try decoder.container(keyedBy: CodingKeys.self)
//        let tempStorage = try container.decodeIfPresent(Entity.self, forKey: .storage)
        self.context = Perspective()
        try super.init(from: decoder)
        
        // NB! This may not always work and could end up biting us in the butt at some point BEWARE!!!
        Task {
            try? await loadPerspective() // Consider decoding this in this method
            if let vault = CellBase.defaultIdentityVault,
               let requester = await vault.identity(for: "private", makeNewIfNotFound: true ) { // Mayby fetch the Identity from json - or does that pose a security issue -> yes! Look into that...
                await setupPermissions(owner: requester)
                await setupKeys(owner: requester)
            }
        }
    }
    
    deinit {
        print("PespectiveCell Deinit!!!")
    }
    
    private func setupPermissions(owner: Identity) async  {
        self.agreementTemplate.addGrant("rw--", for: "advertisedPurpose")
        self.agreementTemplate.addGrant("rw--", for: "activePurpose")
        self.agreementTemplate.addGrant("rw--", for: "addPurpose")
        self.agreementTemplate.addGrant("rw--", for: "matchPurpose")
        self.agreementTemplate.addGrant("rw--", for: "perspective")
    }
    
    private func setupKeys(owner: Identity) async  {
        await addInterceptForGet(requester: owner, key: "advertisedPurpose", getValueIntercept:  { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "advertisedPurpose", for: requester) {
                return .object(self.getPublicPurposesValue())
            }
            return .string("denied")
        })

        await addInterceptForGet(requester: owner, key: "activePurpose", getValueIntercept:  { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "activePurpose", for: requester) {
                return await self.activePurposesPayload(minPurposeWeight: 0.0, limit: 50, includeInterests: true, referenceMode: .both)
            }
            return .string("denied")
        })

        await addInterceptForGet(requester: owner, key: "perspective.state", getValueIntercept:  { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "perspective", for: requester) {
                return await self.perspectiveStatePayload()
            }
            return .string("denied")
        })
        
        await addInterceptForSet(requester: owner, key: "addPurpose", setValueIntercept:  {
            
            [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("-w--", at: "addPurpose", for: requester) {
                do {
                    let added = try await self.upsertPurposes(from: value)
                    return .object([
                        "status": .string("ok"),
                        "updatedCount": .integer(added)
                    ])
                } catch {
                    return .object([
                        "status": .string("error"),
                        "message": .string("\(error)")
                    ])
                }
            }
            
            return .string("denied")
        })
        
        await addInterceptForSet(requester: owner, key: "matchPurpose", setValueIntercept:  {
            
            [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("-w--", at: "matchPurpose", for: requester) {
                return await self.matchPayload(from: value)
            }
            
            return .string("denied")
        })

        await addInterceptForSet(requester: owner, key: "perspective.query.activePurposes", setValueIntercept:  {
            [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("-w--", at: "perspective", for: requester) {
                return await self.activePurposesPayload(from: value)
            }
            return .string("denied")
        })

        await addInterceptForSet(requester: owner, key: "perspective.query.interestsFromActivePurposes", setValueIntercept:  {
            [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("-w--", at: "perspective", for: requester) {
                return await self.interestsFromActivePurposesPayload(from: value)
            }
            return .string("denied")
        })

        await addInterceptForSet(requester: owner, key: "perspective.query.match", setValueIntercept:  {
            [weak self] _, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("-w--", at: "perspective", for: requester) {
                return await self.matchPayload(from: value)
            }
            return .string("denied")
        })

        await registerContracts(requester: owner)
    }
    
    private func loadPerspective() async throws {
        var perspectiveJsonData: Data
        do {
            perspectiveJsonData = try await self.getFileDataInCellDirectory(filename: "Perspective.json")
        } catch {
       
            let weightedPurposes = generateInitialPerspectiveData()
//            context.
            let encoder = await context.pimpEncoder()
            perspectiveJsonData = try encoder.encode(weightedPurposes)
            print("Loading perspectiveJsonData failed with error: \(error)")
        }
        try await self.context.setPurposeJsonData(data: perspectiveJsonData)
        try await self.persistPerpective()
    }
    
    private func persistPerpective() async throws {
        let perspectiveJsonData = try await self.context.getPurposeJsonData()
        try await self.writeFileDataInCellDirectory(fileData: perspectiveJsonData, filename: "Perspective.json")
        
    }
    
    private func generateInitialPerspectiveData() -> [Weight<Purpose>] {
        let weighted = Weight<Purpose>(
            weight: 1.0,
            value: Self.initialPurposeTemplate(ownerUUID: self.uuid),
            reference: nil
        )
        return [weighted]
    }

    static func initialPurposeTemplate(ownerUUID: String) -> Purpose {
        let initialPurpose = Purpose(
            name: "Initial Purpose",
            description: "Bootstrap the first meaningful purposes for the represented person and confirm that at least one active purpose has been added."
        )

        let helperReference = CellReference(endpoint: "cell:///Purposes", label: "purposes")
        var helperConfiguration = CellConfiguration(name: "Open purpose bootstrap", cellReferences: [helperReference])
        helperConfiguration.description = "Open the purpose editor so the represented person can define and save their first active purposes."
        helperConfiguration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: "cell:///Purposes",
            sourceCellName: "PurposesCell",
            purpose: "perspective.bootstrap.helper",
            purposeDescription: "Guide the person to define the first active purposes for this perspective.",
            interests: ["purpose", "bootstrap", "onboarding"],
            menuSlots: ["upperLeft"]
        )
        initialPurpose.addHelperCell(helperConfiguration)

        var goalCellReference = CellReference(endpoint: "cell:///EventGoal", label: "eventgoal")
        let countMatchValue1: Object = ["key" : .string("count"), "operator" : .string(">"), "match" : .integer(1)]
        let countMatchValue2: Object = ["key" : .string("weight"), "operator" : .string(">="), "match" : .float(1.0)]
        let countMatchValue3: Object = ["key" : .string("origin"), "operator" : .string("="), "match" : .string(ownerUUID)]

        var matchArgumentList = ValueTypeList()
        matchArgumentList.append(.object(countMatchValue1))
        matchArgumentList.append(.object(countMatchValue2))
        matchArgumentList.append(.object(countMatchValue3))

        goalCellReference.addKeyAndValue(KeyValue(key: "addMatchers", value: .list(matchArgumentList)))

        let goalDescription = "Success when EventGoal reports count > 1, weight >= 1.0, and origin equals \(ownerUUID)."
        var goalCellConfiguration = CellConfiguration(name: "Detect first active purpose", cellReferences: [goalCellReference])
        goalCellConfiguration.description = goalDescription
        goalCellConfiguration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: "cell:///EventGoal",
            sourceCellName: "EventGoalCell",
            purpose: "goal.perspective.initial-purpose-ready",
            purposeDescription: goalDescription,
            interests: ["purpose", "bootstrap", "goal"],
            menuSlots: ["upperMid"]
        )

        initialPurpose.setGoal(goalCellConfiguration)
        return initialPurpose
    }

    private enum ReferenceMode: String {
        case local
        case portable
        case both
    }

    private struct InterestSnapshot {
        var name: String
        var localRef: String?
        var portableRef: String?
        var weight: Double
    }

    private struct PurposeSnapshot {
        var name: String
        var localRef: String?
        var portableRef: String?
        var weight: Double
        var interests: [InterestSnapshot]
    }

    private func getPublicPurposesValue() -> Object {
        var purposesObject = Object()
        for (key, value) in publicPurposeDict {
            purposesObject[key] = .string(value)
        }
        return purposesObject
    }

    private func stringValue(_ value: ValueType?) -> String? {
        guard let value else { return nil }
        if case let .string(s) = value { return s }
        if case let .integer(i) = value { return "\(i)" }
        if case let .number(n) = value { return "\(n)" }
        if case let .float(d) = value { return "\(d)" }
        if case let .bool(b) = value { return b ? "true" : "false" }
        return nil
    }

    private func doubleValue(_ value: ValueType?) -> Double? {
        guard let value else { return nil }
        if case let .float(d) = value { return d }
        if case let .integer(i) = value { return Double(i) }
        if case let .number(n) = value { return Double(n) }
        if case let .string(s) = value { return Double(s) }
        return nil
    }

    private func intValue(_ value: ValueType?) -> Int? {
        guard let value else { return nil }
        if case let .integer(i) = value { return i }
        if case let .number(n) = value { return n }
        if case let .float(d) = value { return Int(d) }
        if case let .string(s) = value { return Int(s) }
        return nil
    }

    private func boolValue(_ value: ValueType?) -> Bool? {
        guard let value else { return nil }
        if case let .bool(b) = value { return b }
        if case let .string(s) = value {
            return s.lowercased() == "true" || s == "1"
        }
        if case let .integer(i) = value { return i != 0 }
        if case let .number(n) = value { return n != 0 }
        return nil
    }

    private func referenceMode(_ value: ValueType?) -> ReferenceMode {
        guard let raw = stringValue(value)?.lowercased(),
              let mode = ReferenceMode(rawValue: raw) else {
            return .both
        }
        return mode
    }

    private func slugify(_ raw: String) -> String {
        let folded = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let slug = folded
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "unknown" : slug
    }

    private func portableRef(kind: String, localRef: String?, name: String?) -> String? {
        let candidate = (localRef?.isEmpty == false) ? localRef! : (name ?? "")
        guard !candidate.isEmpty else { return nil }
        if candidate.contains("://") {
            let parts = candidate.components(separatedBy: "://")
            if parts.count == 2 {
                return "\(kind)://\(slugify(parts[1]))"
            }
        }
        return "\(kind)://\(slugify(candidate))"
    }

    private func purposeKey(_ purpose: PurposeSnapshot) -> String {
        return purpose.portableRef
            ?? portableRef(kind: "purpose", localRef: purpose.localRef, name: purpose.name)
            ?? "purpose://\(slugify(purpose.name))"
    }

    private func interestKey(_ interest: InterestSnapshot) -> String {
        return interest.portableRef
            ?? portableRef(kind: "interest", localRef: interest.localRef, name: interest.name)
            ?? "interest://\(slugify(interest.name))"
    }

    private func purposeRefObject(_ purpose: PurposeSnapshot, referenceMode: ReferenceMode) -> Object {
        var object = Object()
        switch referenceMode {
        case .local:
            if let localRef = purpose.localRef { object["purposeRef"] = .string(localRef) }
        case .portable:
            if let portableRef = purpose.portableRef { object["portablePurposeRef"] = .string(portableRef) }
        case .both:
            if let localRef = purpose.localRef { object["purposeRef"] = .string(localRef) }
            if let portableRef = purpose.portableRef { object["portablePurposeRef"] = .string(portableRef) }
        }
        return object
    }

    private func interestRefObject(_ interest: InterestSnapshot, referenceMode: ReferenceMode) -> Object {
        var object = Object()
        switch referenceMode {
        case .local:
            if let localRef = interest.localRef { object["interestRef"] = .string(localRef) }
        case .portable:
            if let portableRef = interest.portableRef { object["portableInterestRef"] = .string(portableRef) }
        case .both:
            if let localRef = interest.localRef { object["interestRef"] = .string(localRef) }
            if let portableRef = interest.portableRef { object["portableInterestRef"] = .string(portableRef) }
        }
        return object
    }

    private func interestObject(_ interest: InterestSnapshot, referenceMode: ReferenceMode) -> Object {
        var object = Object()
        object["interestName"] = .string(interest.name)
        object["interestWeight"] = .float(interest.weight)
        for (key, value) in interestRefObject(interest, referenceMode: referenceMode) {
            object[key] = value
        }
        return object
    }

    private func purposeObject(_ purpose: PurposeSnapshot, includeInterests: Bool, referenceMode: ReferenceMode) -> Object {
        var object = Object()
        object["purposeName"] = .string(purpose.name)
        object["purposeWeight"] = .float(purpose.weight)
        for (key, value) in purposeRefObject(purpose, referenceMode: referenceMode) {
            object[key] = value
        }
        if includeInterests {
            var list = ValueTypeList()
            for interest in purpose.interests {
                list.append(.object(interestObject(interest, referenceMode: referenceMode)))
            }
            object["interests"] = .list(list)
        }
        return object
    }

    private func resolvePurpose(_ weighted: Weight<Purpose>) async -> Purpose? {
        if let purpose = weighted.value as? Purpose {
            return purpose
        }
        if let reference = weighted.reference {
            return await context.findPurposeByReference(reference)
        }
        return nil
    }

    private func resolveInterest(_ weighted: Weight<Interest>) async -> Interest? {
        if let interest = weighted.value as? Interest {
            return interest
        }
        if let reference = weighted.reference {
            return await context.findInterestByReference(reference)
        }
        return nil
    }

    private func purposeSnapshot(from weightedPurpose: Weight<Purpose>, includeInterests: Bool) async -> PurposeSnapshot {
        let purpose = await resolvePurpose(weightedPurpose)
        let localRef = weightedPurpose.reference ?? purpose?.reference
        let name = purpose?.name ?? localRef ?? "Unknown Purpose"
        var interests = [InterestSnapshot]()
        if includeInterests,
           let weightedInterests = purpose?.interests as? [Weight<Interest>] {
            for weightedInterest in weightedInterests {
                let interest = await resolveInterest(weightedInterest)
                let localInterestRef = weightedInterest.reference ?? interest?.reference
                let interestName = interest?.name ?? localInterestRef ?? "Unknown Interest"
                interests.append(
                    InterestSnapshot(
                        name: interestName,
                        localRef: localInterestRef,
                        portableRef: portableRef(kind: "interest", localRef: localInterestRef, name: interestName),
                        weight: weightedInterest.weight
                    )
                )
            }
        }
        return PurposeSnapshot(
            name: name,
            localRef: localRef,
            portableRef: portableRef(kind: "purpose", localRef: localRef, name: name),
            weight: weightedPurpose.weight,
            interests: interests
        )
    }

    private func perspectiveStatePayload() async -> ValueType {
        let activePurposeCount = (await context.getActivePurposes(minWeight: 0.0, limit: Int.max)).count
        let activeInterestCount = (await context.getActiveInterests(minWeight: 0.0, limit: Int.max)).count
        return .object([
            "status": .string("ready"),
            "activePurposeCount": .integer(activePurposeCount),
            "activeInterestCount": .integer(activeInterestCount),
            "activePurposes": await activePurposesPayload(minPurposeWeight: 0.0, limit: 25, includeInterests: true, referenceMode: .both)
        ])
    }

    private func activePurposesPayload(from value: ValueType) async -> ValueType {
        let payload: Object
        if case let .object(obj) = value {
            payload = obj
        } else {
            payload = Object()
        }
        let minPurposeWeight = doubleValue(payload["minPurposeWeight"]) ?? 0.0
        let limit = max(1, intValue(payload["limit"]) ?? 50)
        let includeInterests = boolValue(payload["includeInterests"]) ?? true
        let mode = referenceMode(payload["referenceMode"])
        return await activePurposesPayload(minPurposeWeight: minPurposeWeight,
                                           limit: limit,
                                           includeInterests: includeInterests,
                                           referenceMode: mode)
    }

    private func activePurposesPayload(minPurposeWeight: Double, limit: Int, includeInterests: Bool, referenceMode: ReferenceMode) async -> ValueType {
        let activePurposes = await context.getActivePurposes(minWeight: minPurposeWeight, limit: limit)
        var purposesList = ValueTypeList()
        for weightedPurpose in activePurposes {
            let snapshot = await purposeSnapshot(from: weightedPurpose, includeInterests: includeInterests)
            purposesList.append(.object(purposeObject(snapshot, includeInterests: includeInterests, referenceMode: referenceMode)))
        }

        return .object([
            "purposes": .list(purposesList),
            "count": .integer(purposesList.count),
            "minPurposeWeight": .float(minPurposeWeight),
            "referenceMode": .string(referenceMode.rawValue),
            "referenceStrategy": .string("portableRefs-v1")
        ])
    }

    private func interestsFromActivePurposesPayload(from value: ValueType) async -> ValueType {
        let payload: Object
        if case let .object(obj) = value {
            payload = obj
        } else {
            payload = Object()
        }
        let minPurposeWeight = doubleValue(payload["minPurposeWeight"]) ?? 0.0
        let minInterestWeight = doubleValue(payload["minInterestWeight"]) ?? 0.0
        let limit = max(1, intValue(payload["limit"]) ?? 50)
        let mode = referenceMode(payload["referenceMode"])

        let activePurposes = await context.getActivePurposes(minWeight: minPurposeWeight, limit: Int.max)
        var aggregated = [String: (interest: InterestSnapshot, weight: Double, supportingPurposes: [Object])]()

        for weightedPurpose in activePurposes {
            let purpose = await purposeSnapshot(from: weightedPurpose, includeInterests: true)
            for interest in purpose.interests where interest.weight >= minInterestWeight {
                let key = interestKey(interest)
                let combinedWeight = weightedPurpose.weight * interest.weight

                var support = purposeRefObject(purpose, referenceMode: mode)
                support["purposeName"] = .string(purpose.name)
                support["purposeWeight"] = .float(weightedPurpose.weight)
                support["sourceInterestWeight"] = .float(interest.weight)
                support["combinedWeight"] = .float(combinedWeight)

                if var existing = aggregated[key] {
                    if combinedWeight > existing.weight {
                        existing.weight = combinedWeight
                        existing.interest = interest
                    }
                    existing.supportingPurposes.append(support)
                    aggregated[key] = existing
                } else {
                    aggregated[key] = (interest: interest, weight: combinedWeight, supportingPurposes: [support])
                }
            }
        }

        let sorted = aggregated.values.sorted(by: { $0.weight > $1.weight })
        var interestsList = ValueTypeList()
        for entry in sorted.prefix(limit) {
            var interestObjectValue = interestRefObject(entry.interest, referenceMode: mode)
            interestObjectValue["interestName"] = .string(entry.interest.name)
            interestObjectValue["interestWeight"] = .float(entry.weight)
            interestObjectValue["supportingPurposes"] = .list(entry.supportingPurposes.map { .object($0) })
            interestsList.append(.object(interestObjectValue))
        }

        return .object([
            "interests": .list(interestsList),
            "count": .integer(interestsList.count),
            "minPurposeWeight": .float(minPurposeWeight),
            "minInterestWeight": .float(minInterestWeight),
            "referenceMode": .string(mode.rawValue),
            "referenceStrategy": .string("portableRefs-v1")
        ])
    }

    private func parseTargetInterestSnapshot(from value: ValueType) -> InterestSnapshot? {
        guard case let .object(object) = value else { return nil }
        let localRef = stringValue(object["interestRef"]) ?? stringValue(object["reference"])
        let name = stringValue(object["interestName"]) ?? localRef ?? stringValue(object["portableInterestRef"]) ?? "Unknown Interest"
        let portable = stringValue(object["portableInterestRef"]) ?? portableRef(kind: "interest", localRef: localRef, name: name)
        let weight = doubleValue(object["interestWeight"]) ?? doubleValue(object["weight"]) ?? 1.0
        return InterestSnapshot(name: name, localRef: localRef, portableRef: portable, weight: weight)
    }

    private func parseTargetPurposeSnapshot(from value: ValueType) async -> PurposeSnapshot? {
        if case let .string(name) = value {
            return PurposeSnapshot(
                name: name,
                localRef: nil,
                portableRef: portableRef(kind: "purpose", localRef: nil, name: name),
                weight: 1.0,
                interests: []
            )
        }

        guard case let .object(object) = value else { return nil }

        let hasPortableShape = object["purposeWeight"] != nil || object["purposeRef"] != nil || object["portablePurposeRef"] != nil || object["purposeName"] != nil
        if hasPortableShape {
            let localRef = stringValue(object["purposeRef"]) ?? stringValue(object["reference"])
            let name = stringValue(object["purposeName"]) ?? localRef ?? stringValue(object["portablePurposeRef"]) ?? "Unknown Purpose"
            let portable = stringValue(object["portablePurposeRef"]) ?? portableRef(kind: "purpose", localRef: localRef, name: name)
            let weight = doubleValue(object["purposeWeight"]) ?? doubleValue(object["weight"]) ?? 1.0

            var interests = [InterestSnapshot]()
            if let interestValue = object["interests"], case let .list(interestList) = interestValue {
                for item in interestList {
                    if let parsed = parseTargetInterestSnapshot(from: item) {
                        interests.append(parsed)
                    }
                }
            }
            return PurposeSnapshot(name: name, localRef: localRef, portableRef: portable, weight: weight, interests: interests)
        }

        if let weighted = try? await transformObjectToWeightedPurpose(purpose: object) {
            return await purposeSnapshot(from: weighted, includeInterests: true)
        }

        return nil
    }

    private func extractTargetPurposeList(from payload: Object) -> ValueTypeList {
        if let target = payload["targetPurposes"], case let .list(list) = target { return list }
        if let target = payload["targetActivePurposes"], case let .list(list) = target { return list }
        if let target = payload["purposes"], case let .list(list) = target { return list }

        if let targetPerspective = payload["targetPerspective"], case let .object(targetObject) = targetPerspective {
            if let target = targetObject["purposes"], case let .list(list) = target { return list }
            if let target = targetObject["activePurposes"], case let .list(list) = target { return list }
        }
        return ValueTypeList()
    }

    private func matchPayload(from value: ValueType) async -> ValueType {
        let payload: Object
        if case let .object(obj) = value {
            payload = obj
        } else {
            payload = Object()
        }

        let minPurposeWeight = doubleValue(payload["minPurposeWeight"]) ?? 0.0
        let minInterestWeight = doubleValue(payload["minInterestWeight"]) ?? 0.0
        let minMatchScore = doubleValue(payload["minMatchScore"]) ?? 0.0
        let limit = max(1, intValue(payload["limit"]) ?? 50)
        let allowViaInterests = boolValue(payload["allowViaInterests"]) ?? true
        let mode = referenceMode(payload["referenceMode"])

        let sourceActive = await context.getActivePurposes(minWeight: minPurposeWeight, limit: Int.max)
        var sourcePurposes = [PurposeSnapshot]()
        for weighted in sourceActive {
            sourcePurposes.append(await purposeSnapshot(from: weighted, includeInterests: true))
        }

        let targetValues = extractTargetPurposeList(from: payload)
        var targetPurposes = [PurposeSnapshot]()
        for value in targetValues {
            if let parsed = await parseTargetPurposeSnapshot(from: value), parsed.weight >= minPurposeWeight {
                targetPurposes.append(parsed)
            }
        }

        var directHits = [(Double, Object)]()
        var viaHits = [(Double, Object)]()
        var directDedup = Set<String>()
        var viaDedup = Set<String>()

        for sourcePurpose in sourcePurposes {
            for targetPurpose in targetPurposes {
                let sourceKey = purposeKey(sourcePurpose)
                let targetKey = purposeKey(targetPurpose)

                if sourceKey == targetKey {
                    let score = min(sourcePurpose.weight, targetPurpose.weight)
                    if score >= minMatchScore {
                        let dedupKey = "\(sourceKey)|\(targetKey)"
                        if !directDedup.contains(dedupKey) {
                            var hit: Object = [
                                "route": .string("directPurpose"),
                                "matchScore": .float(score),
                                "sourcePurposeWeight": .float(sourcePurpose.weight),
                                "targetPurposeWeight": .float(targetPurpose.weight),
                                "sourcePurposeName": .string(sourcePurpose.name),
                                "targetPurposeName": .string(targetPurpose.name)
                            ]
                            for (key, value) in purposeRefObject(sourcePurpose, referenceMode: mode) {
                                let mappedKey = "source" + key.prefix(1).uppercased() + String(key.dropFirst())
                                hit[mappedKey] = value
                            }
                            for (key, value) in purposeRefObject(targetPurpose, referenceMode: mode) {
                                let mappedKey = "target" + key.prefix(1).uppercased() + String(key.dropFirst())
                                hit[mappedKey] = value
                            }
                            directHits.append((score, hit))
                            directDedup.insert(dedupKey)
                        }
                    }
                }

                guard allowViaInterests else { continue }

                for sourceInterest in sourcePurpose.interests where sourceInterest.weight >= minInterestWeight {
                    for targetInterest in targetPurpose.interests where targetInterest.weight >= minInterestWeight {
                        let sourceInterestKey = interestKey(sourceInterest)
                        let targetInterestKey = interestKey(targetInterest)
                        guard sourceInterestKey == targetInterestKey else { continue }

                        let score = min(sourcePurpose.weight, targetPurpose.weight) * min(sourceInterest.weight, targetInterest.weight)
                        guard score >= minMatchScore else { continue }

                        let dedupKey = "\(purposeKey(sourcePurpose))|\(purposeKey(targetPurpose))|\(sourceInterestKey)"
                        if !viaDedup.contains(dedupKey) {
                            var hit: Object = [
                                "route": .string("viaInterest"),
                                "matchScore": .float(score),
                                "sourcePurposeWeight": .float(sourcePurpose.weight),
                                "targetPurposeWeight": .float(targetPurpose.weight),
                                "sourceInterestWeight": .float(sourceInterest.weight),
                                "targetInterestWeight": .float(targetInterest.weight),
                                "sourcePurposeName": .string(sourcePurpose.name),
                                "targetPurposeName": .string(targetPurpose.name),
                                "interestName": .string(sourceInterest.name)
                            ]
                            for (key, value) in purposeRefObject(sourcePurpose, referenceMode: mode) {
                                let mappedKey = "source" + key.prefix(1).uppercased() + String(key.dropFirst())
                                hit[mappedKey] = value
                            }
                            for (key, value) in purposeRefObject(targetPurpose, referenceMode: mode) {
                                let mappedKey = "target" + key.prefix(1).uppercased() + String(key.dropFirst())
                                hit[mappedKey] = value
                            }
                            for (key, value) in interestRefObject(sourceInterest, referenceMode: mode) {
                                hit[key] = value
                            }
                            viaHits.append((score, hit))
                            viaDedup.insert(dedupKey)
                        }
                    }
                }
            }
        }

        directHits.sort(by: { $0.0 > $1.0 })
        viaHits.sort(by: { $0.0 > $1.0 })
        let directLimited = Array(directHits.prefix(limit))
        let viaLimited = Array(viaHits.prefix(limit))

        var allHits = directLimited + viaLimited
        allHits.sort(by: { $0.0 > $1.0 })
        allHits = Array(allHits.prefix(limit))

        return .object([
            "directPurposeHits": .list(directLimited.map { .object($0.1) }),
            "viaInterestHits": .list(viaLimited.map { .object($0.1) }),
            "allHits": .list(allHits.map { .object($0.1) }),
            "count": .integer(allHits.count),
            "referenceMode": .string(mode.rawValue),
            "referenceStrategy": .string("portableRefs-v1")
        ])
    }

    private func parseWeightedPurpose(from value: ValueType) async throws -> Weight<Purpose>? {
        switch value {
        case .string(let name):
            let purpose = Purpose(name: name, description: "Added by name")
            return Weight<Purpose>(weight: 0.5, value: purpose, reference: purpose.reference)
        case .object(let object):
            if object["weight"] != nil || object["reference"] != nil || object["value"] != nil {
                return try await transformObjectToWeightedPurpose(purpose: object)
            }

            if let purposeValue = object["purpose"], case let .object(purposeObject) = purposeValue {
                let purpose = try await transformObjectToPurpose(purpose: purposeObject)
                let weight = doubleValue(object["purposeWeight"]) ?? doubleValue(object["weight"]) ?? 0.5
                return Weight<Purpose>(weight: weight, value: purpose, reference: purpose.reference)
            }

            let purpose = try await transformObjectToPurpose(purpose: object)
            let weight = doubleValue(object["purposeWeight"]) ?? doubleValue(object["weight"]) ?? 0.5
            return Weight<Purpose>(weight: weight, value: purpose, reference: purpose.reference)
        default:
            return nil
        }
    }

    private func parseWeightedPurposes(from value: ValueType) async throws -> [Weight<Purpose>] {
        if case let .list(list) = value {
            var result = [Weight<Purpose>]()
            for item in list {
                if let weighted = try await parseWeightedPurpose(from: item) {
                    result.append(weighted)
                }
            }
            return result
        }

        if let weighted = try await parseWeightedPurpose(from: value) {
            return [weighted]
        }
        return []
    }

    private func upsertPurposes(from value: ValueType) async throws -> Int {
        let weightedPurposes = try await parseWeightedPurposes(from: value)
        var updatedCount = 0
        for weightedPurpose in weightedPurposes {
            await context.upsertActivePurpose(weighedPurpose: weightedPurpose)
            updatedCount += 1
        }
        if updatedCount > 0 {
            try await persistPerpective()
        }
        return updatedCount
    }
    
    
    // Add a weighted purpose as an Object with ValueTypes
    public func addPurpose(purpose purposeObject: Object) async throws {
        let purpose = try await transformObjectToPurpose(purpose: purposeObject)
        let weightedPurpose = Weight<Purpose>(weight: 0.5, value: purpose)
        try await self.addPurpose(purpose: weightedPurpose)
    }
    
    // MARK: Transformations
    func transformObjectToWeightedPurpose(purpose purposeObject: Object) async throws -> Weight<Purpose> {
        let encoder = await context.pimpEncoder() // Should the pimp method reside outside of actor?
        let decoder = await context.pimpDecoder()
        let weightedPurposeJsonData = try encoder.encode(purposeObject)
        let weightedPurpose = try decoder.decode(Weight<Purpose>.self, from: weightedPurposeJsonData)
        return weightedPurpose
    }
    
    func transformObjectToPurpose(purpose purposeObject: Object) async throws -> Purpose {
        let encoder = await context.pimpEncoder() // Should the pimp method reside outside of actor?
        let decoder = await context.pimpDecoder()
        let purposeJsonData = try encoder.encode(purposeObject)
        let purpose = try decoder.decode(Purpose.self, from: purposeJsonData)
        return purpose
    }
    
    func transformObjectToWeightedInterest(interest interestObject: Object) async throws -> Weight<Interest> {
        let encoder = await context.pimpEncoder() // Should the pimp method reside outside of actor?
        let decoder = await context.pimpDecoder()
        let weightedInterestJsonData = try encoder.encode(interestObject)
        let weightedInterest = try decoder.decode(Weight<Interest>.self, from: weightedInterestJsonData)
        return weightedInterest
    }
    
    func transformObjectToInterest(interest interestObject: Object) async throws -> Interest {
        let encoder = await context.pimpEncoder() // Should the pimp method reside outside of actor?
        let decoder = await context.pimpDecoder()
        let interestJsonData = try encoder.encode(interestObject)
        let interest = try decoder.decode(Interest.self, from: interestJsonData)
        return interest
    }
    
    func transformObjectToWeightedEntity(entity entityObject: Object) async throws -> Weight<EntityRepresentation> {
        let encoder = await context.pimpEncoder() // Should the pimp method reside outside of actor?
        let decoder = await context.pimpDecoder()
        let weightedEntityJsonData = try encoder.encode(entityObject)
        let weightedEntity = try decoder.decode(Weight<EntityRepresentation>.self, from: weightedEntityJsonData)
        return weightedEntity
    }
    
    func transformObjectToEntity(entity entityObject: Object) async throws -> EntityRepresentation {
        let encoder = await context.pimpEncoder() // Should the pimp method reside outside of actor?
        let decoder = await context.pimpDecoder()
        let entityJsonData = try encoder.encode(entityObject)
        let entity = try decoder.decode(EntityRepresentation.self, from: entityJsonData)
        return entity
    }

    private func registerContracts(requester: Identity) async {
        await registerExploreContract(
            requester: requester,
            key: "advertisedPurpose",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [ExploreContract.schema(type: "object", description: "Dictionary of public purpose labels."), ExploreContract.schema(type: "string")],
                description: "Returns the advertised purpose dictionary or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the public purpose labels currently advertised by the perspective.")
        )

        await registerExploreContract(
            requester: requester,
            key: "activePurpose",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [Self.activePurposesResponseSchema(), ExploreContract.schema(type: "string")],
                description: "Returns active purposes or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the active purposes in portable/local reference form, including weighted interests.")
        )

        await registerExploreContract(
            requester: requester,
            key: "perspective.state",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [Self.perspectiveStateSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the perspective state snapshot or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns perspective status, counts, and the current active-purpose snapshot.")
        )

        await registerExploreContract(
            requester: requester,
            key: "addPurpose",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.schema(type: "string", description: "Shortcut purpose name."),
                    ExploreContract.schema(type: "object", description: "Purpose, weighted purpose, or wrapped purpose payload."),
                    ExploreContract.listSchema(item: ExploreContract.schema(type: "object"), description: "List of purpose payloads.")
                ],
                description: "Accepts one or more purpose payloads and upserts them into the active perspective."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [Self.upsertResponseSchema(), ExploreContract.schema(type: "string")],
                description: "Returns an update summary or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Adds or updates active purposes from raw, weighted, or list-based purpose payloads.")
        )

        await registerExploreContract(
            requester: requester,
            key: "matchPurpose",
            method: .set,
            input: Self.matchRequestSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.matchResponseSchema(), ExploreContract.schema(type: "string")],
                description: "Returns purpose matches or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Matches the current active purposes against target purposes directly or via shared interests.")
        )

        await registerExploreContract(
            requester: requester,
            key: "perspective.query.activePurposes",
            method: .set,
            input: Self.activePurposesQuerySchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.activePurposesResponseSchema(), ExploreContract.schema(type: "string")],
                description: "Returns active purposes or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Queries active purposes with weight thresholds, limits, and reference-mode controls.")
        )

        await registerExploreContract(
            requester: requester,
            key: "perspective.query.interestsFromActivePurposes",
            method: .set,
            input: Self.interestsQuerySchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.interestsResponseSchema(), ExploreContract.schema(type: "string")],
                description: "Returns aggregated interests or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Aggregates interests from the current active purposes and returns weighted supporting-purpose evidence.")
        )

        await registerExploreContract(
            requester: requester,
            key: "perspective.query.match",
            method: .set,
            input: Self.matchRequestSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.matchResponseSchema(), ExploreContract.schema(type: "string")],
                description: "Returns purpose matches or a denial/failure string."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Queries direct purpose matches and via-interest matches using the active perspective as source.")
        )
    }

    private static func activePurposesQuerySchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "minPurposeWeight": ExploreContract.schema(type: "float"),
                "limit": ExploreContract.schema(type: "integer"),
                "includeInterests": ExploreContract.schema(type: "bool"),
                "referenceMode": ExploreContract.schema(type: "string")
            ],
            description: "Active purpose query options."
        )
    }

    private static func interestsQuerySchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "minPurposeWeight": ExploreContract.schema(type: "float"),
                "minInterestWeight": ExploreContract.schema(type: "float"),
                "limit": ExploreContract.schema(type: "integer"),
                "referenceMode": ExploreContract.schema(type: "string")
            ],
            description: "Interest aggregation query options."
        )
    }

    private static func matchRequestSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "minPurposeWeight": ExploreContract.schema(type: "float"),
                "minInterestWeight": ExploreContract.schema(type: "float"),
                "minMatchScore": ExploreContract.schema(type: "float"),
                "limit": ExploreContract.schema(type: "integer"),
                "allowViaInterests": ExploreContract.schema(type: "bool"),
                "referenceMode": ExploreContract.schema(type: "string"),
                "targetPurposes": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
                "targetActivePurposes": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
                "purposes": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
                "targetPerspective": ExploreContract.schema(type: "object")
            ],
            description: "Perspective match query options and target purpose payloads."
        )
    }

    private static func purposeSnapshotSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "purposeName": ExploreContract.schema(type: "string"),
                "purposeWeight": ExploreContract.schema(type: "float"),
                "purposeRef": ExploreContract.schema(type: "string"),
                "portablePurposeRef": ExploreContract.schema(type: "string"),
                "interests": ExploreContract.listSchema(item: interestSnapshotSchema())
            ],
            requiredKeys: ["purposeName", "purposeWeight"],
            description: "Perspective purpose snapshot."
        )
    }

    private static func interestSnapshotSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "interestName": ExploreContract.schema(type: "string"),
                "interestWeight": ExploreContract.schema(type: "float"),
                "interestRef": ExploreContract.schema(type: "string"),
                "portableInterestRef": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["interestName", "interestWeight"],
            description: "Perspective interest snapshot."
        )
    }

    private static func activePurposesResponseSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "purposes": ExploreContract.listSchema(item: purposeSnapshotSchema()),
                "count": ExploreContract.schema(type: "integer"),
                "minPurposeWeight": ExploreContract.schema(type: "float"),
                "referenceMode": ExploreContract.schema(type: "string"),
                "referenceStrategy": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["purposes", "count", "referenceMode"],
            description: "Active purpose query response."
        )
    }

    private static func supportedPurposeSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "purposeName": ExploreContract.schema(type: "string"),
                "purposeWeight": ExploreContract.schema(type: "float"),
                "sourceInterestWeight": ExploreContract.schema(type: "float"),
                "combinedWeight": ExploreContract.schema(type: "float"),
                "purposeRef": ExploreContract.schema(type: "string"),
                "portablePurposeRef": ExploreContract.schema(type: "string")
            ],
            description: "Purpose evidence supporting an aggregated interest."
        )
    }

    private static func interestsResponseSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "interests": ExploreContract.listSchema(
                    item: ExploreContract.objectSchema(
                        properties: [
                            "interestName": ExploreContract.schema(type: "string"),
                            "interestWeight": ExploreContract.schema(type: "float"),
                            "interestRef": ExploreContract.schema(type: "string"),
                            "portableInterestRef": ExploreContract.schema(type: "string"),
                            "supportingPurposes": ExploreContract.listSchema(item: supportedPurposeSchema())
                        ],
                        requiredKeys: ["interestName", "interestWeight", "supportingPurposes"]
                    )
                ),
                "count": ExploreContract.schema(type: "integer"),
                "minPurposeWeight": ExploreContract.schema(type: "float"),
                "minInterestWeight": ExploreContract.schema(type: "float"),
                "referenceMode": ExploreContract.schema(type: "string"),
                "referenceStrategy": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["interests", "count", "referenceMode"],
            description: "Interest aggregation response."
        )
    }

    private static func matchHitSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "route": ExploreContract.schema(type: "string"),
                "matchScore": ExploreContract.schema(type: "float"),
                "sourcePurposeWeight": ExploreContract.schema(type: "float"),
                "targetPurposeWeight": ExploreContract.schema(type: "float"),
                "sourceInterestWeight": ExploreContract.schema(type: "float"),
                "targetInterestWeight": ExploreContract.schema(type: "float"),
                "sourcePurposeName": ExploreContract.schema(type: "string"),
                "targetPurposeName": ExploreContract.schema(type: "string"),
                "interestName": ExploreContract.schema(type: "string"),
                "sourcePurposeRef": ExploreContract.schema(type: "string"),
                "sourcePortablePurposeRef": ExploreContract.schema(type: "string"),
                "targetPurposeRef": ExploreContract.schema(type: "string"),
                "targetPortablePurposeRef": ExploreContract.schema(type: "string"),
                "interestRef": ExploreContract.schema(type: "string"),
                "portableInterestRef": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["route", "matchScore", "sourcePurposeName", "targetPurposeName"],
            description: "A direct or via-interest perspective match hit."
        )
    }

    private static func matchResponseSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "directPurposeHits": ExploreContract.listSchema(item: matchHitSchema()),
                "viaInterestHits": ExploreContract.listSchema(item: matchHitSchema()),
                "allHits": ExploreContract.listSchema(item: matchHitSchema()),
                "count": ExploreContract.schema(type: "integer"),
                "referenceMode": ExploreContract.schema(type: "string"),
                "referenceStrategy": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["directPurposeHits", "viaInterestHits", "allHits", "count"],
            description: "Perspective purpose matching response."
        )
    }

    private static func perspectiveStateSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "activePurposeCount": ExploreContract.schema(type: "integer"),
                "activeInterestCount": ExploreContract.schema(type: "integer"),
                "activePurposes": activePurposesResponseSchema()
            ],
            requiredKeys: ["status", "activePurposeCount", "activeInterestCount", "activePurposes"],
            description: "Perspective state snapshot."
        )
    }

    private static func upsertResponseSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "updatedCount": ExploreContract.schema(type: "integer"),
                "message": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["status"],
            description: "Purpose upsert response."
        )
    }
    
    
    private func testAddPurpose()  async throws {
        let purpose = Purpose(name: "Test add purpose", description: "This test purpose will test how it is to wrap a purpose in a Weight (A goal will be added later)")
        let weightedPurpose = Weight(weight: 0.5, value: purpose)
        _ = try await addPurpose(purpose: weightedPurpose)
    }
    
    // Next time I add a placeholder method - remember to document what the idea behind the return value was (and other things...) - i guess it is to inform subscribers of a newly added purpose? Possibly wrong place?
     func addPurpose(purpose: Weight<Purpose>) async throws {
        await self.context.upsertActivePurpose(weighedPurpose: purpose)
         try await persistPerpective()
    }
    
}
