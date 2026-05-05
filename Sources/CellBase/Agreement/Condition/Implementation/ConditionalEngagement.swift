// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public struct ConditionalEngagement: Codable, Condition, ConnectChallengeProvidingCondition {
    public var uuid: String
    public var name: String
    
    public var condition: GrantCondition
    public var engagement: CellConfiguration
    
    /*
     the actual condition example
     <cell ref>.isMember(identity) - should identity always be able to check if it is itself a member?
     the real cell ref should only be revealed to identities that has been granted? Could be solved by lookup ref
     if not met
     connect to <cell> to get an explanation or way to solve it
     
     */
    
    public init() {
        self.uuid = UUID().uuidString
        self.name = "Conditional Engagement Condition"
        self.condition = GrantCondition(requestedGrant: "identity.accessToken", requestedPermission: "r---")// Change to something useful or drop this initializer?
        self.engagement = CellConfiguration(name: "Login Experience", cellReferences: [CellReference(endpoint: "ws://127.0.0.1:8081/publishersws/LoginCell", label: "login")] )
    }
    
    
    
    public func isMet(context: ConnectContext) async -> ConditionState {
        var state: ConditionState = await condition.isMet(context: context)
        if state == .unresolved {
            CellBase.diagnosticLog("ConditionalEngagement requires helper action", domain: .flow)
            state = .engage
        }
        return state
    }
    
    public func resolve(context: ConnectContext) async {
        
    }

    public func connectChallengeDescriptor(context: ConnectContext) async -> ConnectChallengeDescriptor? {
        ConnectChallengeDescriptor(
            reasonCode: "conditional_engagement_unresolved",
            userMessage: "Du ma fullfore \(name) for tilkoblingen kan fortsette.",
            requiredAction: "open_helper_configuration",
            canAutoResolve: false,
            helperCellConfiguration: engagement,
            developerHint: "ConditionalEngagement returned .engage. Present helper CellConfiguration to the active Porthole."
        )
    }
}
