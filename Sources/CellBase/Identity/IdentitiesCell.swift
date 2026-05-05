// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 09/07/2024.
//

import Foundation

public class IdentitiesCell: GeneralCell {
    var visitingIdentities: [String : Identity]
    
    required init(owner: Identity) async {
    visitingIdentities = [String : Identity]()
        await super.init(owner: owner)
        
        CellBase.diagnosticLog("IdentitiesCell init owner=\(owner.uuid)", domain: .identity)
    
            await setupPermissions(owner: owner)
            await setupKeys(owner: owner)
//        do {
//            try await self.attachUniversalResolver()
//        } catch {
//            print("attaching universal resolver failed with error: \(error)")
//        }
//        await self.checkDirectories()
        

    }
    
    enum CodingKeys: CodingKey {
        case visitingIdentities
        case generalCell
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visitingIdentities = try container.decode([String : Identity].self, forKey: .visitingIdentities)

        try super.init(from: decoder)
        
        // NB! This may not always work and could end up biting us in the butt at some point BEWARE!!!
        Task {
            await setupPermissions(owner: self.owner)
            await setupKeys(owner: self.owner)
        }
    }
    
    private func setupPermissions(owner: Identity) async  {
        self.agreementTemplate.addGrant("rw--", for: "identities")
    }
    
    private func setupKeys(owner: Identity) async  {
        await addInterceptForGet(requester: owner, key: "identities", getValueIntercept:  { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "identities", for: requester) {
                CellBase.diagnosticLog("IdentitiesCell get identities keypath=\(keypath)", domain: .identity)
                return .list(self.visitingIdentities.values
                    .sorted(by: { $0.uuid < $1.uuid })
                    .map { .identity($0) })
            }
            return .string("denied")
        })

        await registerContracts(requester: owner)
    }
    
    
    private func identity(for uuid: String) async throws {
        
    }

    private func registerContracts(requester: Identity) async {
        await registerExploreContract(
            requester: requester,
            key: "identities",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.listSchema(
                        item: Self.identitySchema(),
                        description: "List of visiting identities known to the cell."
                    ),
                    ExploreContract.schema(type: "string")
                ],
                description: "Returns visiting identities or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Lists visiting identities currently tracked by the identities cell.")
        )
    }

    private static func identitySchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "uuid": ExploreContract.schema(type: "string"),
                "displayName": ExploreContract.schema(type: "string"),
                "properties": ExploreContract.schema(type: "object"),
                "publicSecureKey": ExploreContract.schema(type: "object")
            ],
            requiredKeys: ["uuid", "displayName"],
            description: "Serialized identity summary."
        )
    }
}
