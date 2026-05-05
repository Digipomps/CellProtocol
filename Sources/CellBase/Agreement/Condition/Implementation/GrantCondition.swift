// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public struct GrantCondition: Codable, Condition {
    public var uuid: String
    public var name: String
    public var grant: Grant
    
    public func isMet(context: ConnectContext) async  -> ConditionState {
        var state = ConditionState.unresolved
        // check if grant is valid.
        // How to lookup identity, source and target cell?
        if let keypath = grant.keypathComponents {
            let contextKey = keypath[0]
            switch contextKey {
            case "identity":
                // check grants in identity
                if let identity = context.identity {
                    if let childGrant = grant.childGrant() {
                        if identity.granted(childGrant) {
                            state = .met
                        }
                    }
                }
                
            case "source":
                CellBase.diagnosticLog("GrantCondition checking source", domain: .agreement)
                if let source = try? await context.source {
                    if let childGrant = grant.childGrant() {
                        CellBase.diagnosticLog("GrantCondition source childGrant=\(childGrant.keypath)", domain: .agreement)
//                        if source.granted(childGrant /* for identity */) {
//                            state = .met
//                        }
                    }
                }
            case "target":
                CellBase.diagnosticLog("GrantCondition checking target", domain: .agreement)
                if let target = try? await context.target {
                    if let childGrant = grant.childGrant() {
                        CellBase.diagnosticLog("GrantCondition target childGrant=\(childGrant.keypath)", domain: .agreement)
                        // For demo purpose
                        if childGrant.keypath.contains("isMember") {
                            state = .met
                        }
//                        if target.granted(childGrant)
//                        {
//                            state = .met
//                        }
                    }
                }
            default:
                print("Unknown lookup key: \(contextKey)")
            }
        }
        
        
        return state
    }
    public init() {
        name = "Test Grant Condition"
        grant = Grant()
        uuid = UUID().uuidString
    }
    
    public init(requestedGrant: String, requestedPermission: String) {
        uuid = UUID.init().uuidString
        name = "Grant Condition \(requestedGrant)"
        grant = Grant("Request grant", keypath: requestedGrant, permission: requestedPermission)
    }
    
    public func resolve(context: ConnectContext) async {
        
    }
}
