// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

struct TypedCondition: Codable {
    let type: ConditionType
    let condition: Condition
    
    enum CodingKeys: String, CodingKey {
        case type
        case condition
    }
    
    init(type: ConditionType, condition: Condition) {
        self.type = type
        self.condition = condition
    }
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let tmpType = try? values.decode(ConditionType.self, forKey: .type) {
        type = tmpType
        } else {
            type = .grant
        }
        switch type {
        case .httpRequest:
            condition = try values.decode(DummyCondition.self, forKey: .condition)
        case .grant:
            condition = try values.decode(GrantCondition.self, forKey: .condition)
        case .prove:
            condition = try values.decode(ProvedClaimCondition.self, forKey: .condition)
        case .engagement:
            condition = try values.decode(ConditionalEngagement.self, forKey: .condition)
        case .lookup:
            condition = try values.decode(LookupCondition.self, forKey: .condition)
        case .replayGuarantee:
            condition = try values.decode(ReplayGuaranteeCondition.self, forKey: .condition)
        case .lifecycleFunding:
            condition = try values.decode(LifecycleFundingCondition.self, forKey: .condition)
        case .coldStorage:
            condition = try values.decode(ColdStorageCondition.self, forKey: .condition)
        case .lifecycleAlertAccess:
            condition = try values.decode(LifecycleAlertAccessCondition.self, forKey: .condition)
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch type {
        case .httpRequest:
            if let encodeCondition = condition as? DummyCondition {
                try container.encode(encodeCondition, forKey: .condition)
            }
        case .grant:
            if let encodeCondition = condition as? GrantCondition {
                try container.encode(encodeCondition, forKey: .condition)
            }
        case .prove:
            if let encodeCondition = condition as? ProvedClaimCondition {
                try container.encode(encodeCondition, forKey: .condition)
            }
        case .engagement:
            if let encodeCondition = condition as? ConditionalEngagement {
                try container.encode(encodeCondition, forKey: .condition)
            }
            
        case .lookup:
            if let encodeCondition = condition as? LookupCondition {
                try container.encode(encodeCondition, forKey: .condition)
            }
        case .replayGuarantee:
            if let encodeCondition = condition as? ReplayGuaranteeCondition {
                try container.encode(encodeCondition, forKey: .condition)
            }
        case .lifecycleFunding:
            if let encodeCondition = condition as? LifecycleFundingCondition {
                try container.encode(encodeCondition, forKey: .condition)
            }
        case .coldStorage:
            if let encodeCondition = condition as? ColdStorageCondition {
                try container.encode(encodeCondition, forKey: .condition)
            }
        case .lifecycleAlertAccess:
            if let encodeCondition = condition as? LifecycleAlertAccessCondition {
                try container.encode(encodeCondition, forKey: .condition)
            }
        }
    }
}
