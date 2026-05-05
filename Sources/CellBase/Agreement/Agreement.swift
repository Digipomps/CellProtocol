// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public class Agreement: Codable, Grantable {
    public var uuid: String
    public var name: String
    var state: AgreementState
    var owner: Identity
    public var signatories = [Identity]() 
    public var conditions = [any Condition]()
    public var grants = [Grant]()
    public var duration: Int = 60*60*24*365 // Remember to add start date...
    var timestamp: Int? // seconds from 01.01.71
    
    enum CodingKeys: String, CodingKey
    {
        case uuid
        case name
        case state
        case owner
        case signatories
        case conditions
        case grants
        case duration
        case timestamp
    }
    
    required public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try values.decodeIfPresent(String.self, forKey: .uuid) ?? UUID().uuidString
        name = try values.decode(String.self, forKey: .name)
        state = Self.decodeState(from: values)
        owner = try values.decode(Identity.self, forKey: .owner)
        
        if values.contains(.signatories) {
            signatories = try values.decode([Identity].self, forKey: .signatories)
        }
        if values.contains(.conditions) {
            if let typedCondtions = try? values.decode([TypedCondition].self, forKey: .conditions) {
                conditions = []
                for currentTypeCondition in typedCondtions {
                    conditions.append(currentTypeCondition.condition)
                }
            }
        }
        if values.contains(.grants) {
            grants = try values.decode([Grant].self, forKey: .grants)
        }
        duration = try values.decodeIfPresent(Int.self, forKey: .duration) ?? Self.defaultDuration
        if values.contains(.timestamp) {
            timestamp = try? values.decode(Int.self, forKey: .timestamp)
        }
    }
    
    public init() async {
        uuid = UUID.init().uuidString
        name = "Contract name here"
        state = .template
        owner = Identity()
        Task {
            if let localOwner = await (CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)) {
                owner = localOwner
            }
        }
        signatories = [owner]
        grants = [Grant(),Grant("Feed grant", keypath: "feed", permission: "r---")]
        conditions = [GrantCondition()]
    }

    private static let defaultDuration = 60 * 60 * 24 * 365

    private static func decodeState(from values: KeyedDecodingContainer<CodingKeys>) -> AgreementState {
        if let state = try? values.decodeIfPresent(AgreementState.self, forKey: .state) {
            return state
        }

        if let rawState = try? values.decodeIfPresent(String.self, forKey: .state) {
            CellBase.diagnosticLog(
                "Agreement decoded legacy/unknown state '\(rawState)'; defaulting to signed",
                domain: .agreement
            )
        } else if values.contains(.state) {
            CellBase.diagnosticLog(
                "Agreement decoded unreadable legacy state; defaulting to signed",
                domain: .agreement
            )
        } else {
            CellBase.diagnosticLog(
                "Agreement decoded legacy payload without state; defaulting to signed",
                domain: .agreement
            )
        }

        return .signed
    }
    
    public init(owner: Identity) {
        uuid = UUID.init().uuidString
        name = "Contract name here"
        state = .template
        self.owner = owner
        signatories = [owner]
        grants = [Grant(),Grant("Feed grant", keypath: "feed", permission: "r---")]
        conditions = [GrantCondition()]
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(name, forKey: .name)
        try container.encode(state, forKey: .state)
        try container.encode(owner, forKey: .owner)
        try container.encode(signatories, forKey: .signatories)
        if conditions.count > 0 {
            var typedConditions = [TypedCondition]()
            for condition in conditions {
                
                var type = ConditionType.httpRequest
                if condition is GrantCondition { // remember to expand to prove later
                    type = .grant
                } else if condition is ConditionalEngagement {
                    type = .engagement
                } else if condition is LookupCondition {
                    type = .lookup
                } else if condition is ProvedClaimCondition {
                    type = .prove
                } else if condition is ReplayGuaranteeCondition {
                    type = .replayGuarantee
                } else if condition is LifecycleFundingCondition {
                    type = .lifecycleFunding
                } else if condition is ColdStorageCondition {
                    type = .coldStorage
                } else if condition is LifecycleAlertAccessCondition {
                    type = .lifecycleAlertAccess
                }
                
                
                typedConditions.append(TypedCondition(type: type, condition: condition))
                try container.encode(typedConditions, forKey: .conditions)
            }
            
        }
        
        try container.encode(grants, forKey: .grants)
        try container.encode(duration, forKey: .duration)
    }
    
    
    
    func granted(_ grant: Grant) -> Bool {
        return false
    }
    
    public func addGrant(_ permission: String, for key: String) {
        let grant = Grant(keypath: key, permission: permission)
        addGrant(grant)
    }
    
    public func addGrant(_ grant: Grant) {
//        if  !grants.contains(grant) {
            grants.append(grant)
//        }
    }
    
    func removeGrant(_ grant: Grant) {
        
    }
    
    public func sign(identity: Identity) {
        //        Add cryptografic signature for identity
        if signatories.contains(identity) {
            // then sign...
        }
    }
    
    public func checkGrant(requestedGrant: Grant) -> Bool {
        var isGranted = false
        for currentGrant in grants {
            if currentGrant.granted(requestedGrant) {
                isGranted = true
                break
            }
        }
        return isGranted
    }
    
    private func signatoriesDescription() -> String {
        var signatoriesString = "Singnatories:\n"
            for signatory in self.signatories {
                signatoriesString.append("\t\(signatory.displayName) - \(signatory.uuid)\n")
            }
        return signatoriesString
    }
    
    private func conditionsDescription() -> String  {
        var conditionsString = "Conditions:\n"
            for condition in self.conditions {
                conditionsString.append("\t\(condition.name)\n")
            }
        return conditionsString
    }
    
    
    // Both grants and conditions must not be edited by others - should we check here or only in the cell's set permissions?
    public func addCondition(_ condition: Condition) throws { // may throw if not validated or something...
       // validate (not that it is resolves) that the condition itself is valid
//        if self.conditions.contains(
//            
//        }
        self.conditions.append(condition)
        CellBase.diagnosticLog("Agreement.addCondition count=\(conditions.count)", domain: .agreement)
    }
    
    private func grantsDescription() -> String  {
        var grantsString = "Grants:\n"
        for grant in grants {
            grantsString.append("\t\(String(describing: grant.keypath)) \(grant.permission.description())\n")
        }
        return grantsString
    }
    
    public func description() -> String {
        let descriptionString = "\n----------------------\nContract\n\(signatoriesDescription())\n\(conditionsDescription())\n\(grantsDescription())\nDuration: \(duration)\n----------------------\n"
        
        return descriptionString
    }
}

public extension Agreement {
    func set(keypath: String, value: ValueType) {
        CellBase.diagnosticLog("Agreement.set keypath=\(keypath)", domain: .agreement)
        let keypathComponemnts = keypath.split(separator: ".")
        let key = keypathComponemnts[0]
        let hasMoreComponents = keypathComponemnts.count > 1
        if key.contains("[]") {
                CellBase.diagnosticLog("Agreement.set key contains list marker", domain: .agreement)
        }
        switch key {
        case "signatories":
            if hasMoreComponents {
                CellBase.diagnosticLog("Agreement.set nested signatories keypath ignored: \(keypath)", domain: .agreement)
            } else {
                if case .identity(let identity) = value {
                    self.signatories.append(identity)
                } else if case .object(let object) = value {
                    do {
                        let identity = try convertObjectToIdentity(object: object)
                        self.signatories.append(identity)
                    } catch {
                        CellBase.diagnosticLog("Agreement.set failed to decode signatory: \(error)", domain: .agreement)
                    }
                    
                }
                
            }
            
        case "conditions":
            if hasMoreComponents {
                CellBase.diagnosticLog("Agreement.set nested conditions keypath ignored: \(keypath)", domain: .agreement)
            } else {
                 if case .object(let object) = value {
                    do {
                        let condition = try convertObjectToCondition(object: object)
                        CellBase.diagnosticLog("Agreement.set exploring condition \(condition.name)", domain: .agreement)
                        var updated = false
                        for i in conditions.indices {
                            if conditions[i].uuid == condition.uuid {
                                CellBase.diagnosticLog("Agreement.set updating condition \(condition.uuid)", domain: .agreement)
                                updated = true // If this fails we shhould still not add it?
                                switch condition.self {
                                case is ProvedClaimCondition:
                                    
                                    if let source = condition as? ProvedClaimCondition {
                                        var provedClaimCondition = ProvedClaimCondition(name: source.name, statement: source.statement)
                                        provedClaimCondition.uuid = source.uuid
                                            conditions[i]  = provedClaimCondition
                                             
                                    }
                                    
                                case is GrantCondition:
                                    CellBase.diagnosticLog("Agreement.set condition type=GrantCondition", domain: .agreement)
                                    if let source = condition as? GrantCondition {
                                        var grantCondition = GrantCondition(requestedGrant: source.grant.keypath, requestedPermission: source.grant.permission.permissionString)
                                        grantCondition.name = source.name
                                        grantCondition.uuid = source.uuid
                                        conditions[i] = grantCondition
                                    }
                                default:
                                    CellBase.diagnosticLog(
                                        "Agreement.set did not recognise condition type: \(condition)",
                                        domain: .agreement
                                    )
                                }
                                break
                            }
                            
                        }
                        
                        
                        if updated == false {
                            CellBase.diagnosticLog("Agreement.set adding new condition \(condition.name)", domain: .agreement)
                            try self.addCondition(condition)
                            
                            
                        }
                    } catch {
                        CellBase.diagnosticLog("Agreement.set failed to decode condition: \(error)", domain: .agreement)
                    }
                    
                }
            }
            
        case "grants":
            
            if hasMoreComponents {
                CellBase.diagnosticLog("Agreement.set nested grants keypath ignored: \(keypath)", domain: .agreement)
            } else {
                 if case .object(let object) = value {
                    do {
                        let grant = try convertObjectToGrant(object: object)
                         self.addGrant(grant)
                    } catch {
                        CellBase.diagnosticLog("Agreement.set failed to decode grant: \(error)", domain: .agreement)
                    }
                    
                }
            }
            
        default:
            CellBase.diagnosticLog("Agreement.set key not supported: \(key)", domain: .agreement)
            
        }
        
        
    }
    
    
    func get(keypath: String) -> ValueType {
        
        return .string("not yet implemented")
    }
    
    func deletePrefix(_ prefix: String, from string: String) -> String {
        guard string.hasPrefix(prefix) else { return string }
        return String(string.dropFirst(prefix.count))
    }
    
    func convertObjectToIdentity(object: Object) throws -> Identity {
        let jsonData = try JSONEncoder().encode(object)
        let identity = try JSONDecoder().decode(Identity.self, from: jsonData)
        return identity
    }
    
    
    // Remember to send condition as a typed condition
    func convertObjectToCondition(object: Object) throws -> Condition {
        let jsonData = try JSONEncoder().encode(object)
        let condition = try JSONDecoder().decode(TypedCondition.self, from: jsonData)
        return condition.condition
    }
    
    func convertObjectToGrant(object: Object) throws -> Grant {
        let jsonData = try JSONEncoder().encode(object)
        let identity = try JSONDecoder().decode(Grant.self, from: jsonData)
        return identity
    }
    

}
