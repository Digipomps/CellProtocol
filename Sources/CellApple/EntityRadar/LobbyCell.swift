// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  LobbyCell.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 27/11/2024.
//
@_spi(HAVENRuntime) import CellBase
import Foundation

/*
 The lobby is where other entities are first let in.
 First create a dictionary with some (public) info about whhat you're pursuing
 */

class LobbyCell: GeneralCell {
    var context: Perspective
    var perspectiveCell: PerspectiveCell?
    private let purposeStateLock = NSLock()
    private var publicPurposeDict = [String: String]()
    
    required init(owner: Identity) async {
        
        self.context = Perspective()
        
        await super.init(owner: owner)
        
        print("LobbyCell init. Owner: \(owner.uuid)")
        try? await ensureRuntimeReady()
    }
    
    required init(from decoder: any Decoder) throws {
        context = Perspective()
        perspectiveCell = nil
        let container = try decoder.container(keyedBy: CodingKeys.self)
        publicPurposeDict = try container.decodeIfPresent([String: String].self, forKey: .publicPurposeDict) ?? [:]
        try super.init(from: decoder)
    }

    private enum CodingKeys: String, CodingKey {
        case publicPurposeDict
    }

    override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        purposeStateLock.lock()
        let purposeSnapshot = publicPurposeDict
        purposeStateLock.unlock()
        try container.encode(purposeSnapshot, forKey: .publicPurposeDict)
    }

    public override func installCellRuntimeBindingsForAccess() async throws {
        let bindingOwner = storedOwnerIdentity
        await setupPermissions(owner: bindingOwner)
        await setupKeys(owner: bindingOwner)
    }
    
    
    private func setupPermissions(owner: Identity) async {
        let unsupportedOrOwnerOnlyKeys = Set(["start", "stop", "purposes.update"])
        self.agreementTemplate.grants.removeAll { grant in
            if grant.keypath == "purposes" {
                return grant.permission.permissionString != "r---"
            }
            return unsupportedOrOwnerOnlyKeys.contains(grant.keypath)
        }
        self.agreementTemplate.ensureGrant("r---", for: "purposes")
    }
    
    private func setupKeys(owner: Identity) async {
        await registerContracts(requester: owner)

        await addInterceptForGet(requester: owner, key: "purposes") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "purposes", for: requester) else {
                return .string("denied")
            }
            return .object(self.getPublicPurposesValue())
        }

        await addInterceptForSet(requester: owner, key: "purposes.update") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "purposes.update", for: requester) else {
                return .string("denied")
            }
            try self.setPublicPurposes(purposesValue: value)
            return .string("ok")
        }
    }

    private func registerContracts(requester: Identity) async {
        await registerExploreContract(
            requester: requester,
            key: "purposes",
            method: .get,
            input: .null,
            returns: ExploreContract.schema(
                type: "object",
                description: "Map of public purpose identifiers to human-readable descriptions."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Reads the owner-published public purpose map.")
        )

        await registerExploreContract(
            requester: requester,
            key: "purposes.update",
            method: .set,
            input: ExploreContract.schema(
                type: "object",
                description: "Complete replacement map whose values must all be strings."
            ),
            returns: ExploreContract.schema(type: "string"),
            permissions: ["-w--"],
            required: false,
            description: .string("Replaces the public purpose map; owner authority is required.")
        )
    }
    
    func getPerspectiveCell(requester: Identity) async throws -> PerspectiveCell {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        guard let cell = try await resolver.cellAtEndpoint(endpoint: "cell:///Perspective", requester: requester ) as? PerspectiveCell else {
            throw CellBaseError.noTargetCell
        }
        
        let admitState = try await self.attach(emitter: cell, label: "perspective", requester: requester)
        if admitState == ConnectState.connected {
            try await self.absorbFlow(label: "perspective", requester: requester)
        }
        return cell
    }
    
    //---------------
    private func getPublicPurposesValue() -> Object {
        purposeStateLock.lock()
        let purposeSnapshot = publicPurposeDict
        purposeStateLock.unlock()
        var pruposesObject = Object()
        for (key, value) in purposeSnapshot {
            pruposesObject[key] = .string(value)
        }
        return pruposesObject
    }
    
    private func setPublicPurposes(purposesValue: ValueType) throws {
        guard case .object(let object) = purposesValue else {
            throw SetValueError.paramErr
        }
        var purposeDict = [String : String]()
        
        for (key, value) in object {
            guard case let .string(string) = value else {
                throw SetValueError.paramErr
            }
            purposeDict[key] = string
        }
        setPublicPurposes(purposesDict: purposeDict)
    }
    
    private func setPublicPurposes(purposesDict: [String : String]) {
        purposeStateLock.lock()
        self.publicPurposeDict = purposesDict
        purposeStateLock.unlock()
    }

}
