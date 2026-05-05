//
//  AppleIntelligenceCell.swift
//

import Foundation

public final class AppleIntelligenceCell {
    
    private func toFlowElementValueType(_ value: ValueType) -> FlowElementValueType {
        switch value {
        case .string(let s):
            return .string(s)
        case .bool(let b):
            return .bool(b)
        case .number(let n):
            return .number(n)
        case .integer(let i):
            return .number(i)
        case .float(let d):
            return .string(String(d))
        case .data(let data):
            return .data(data)
        case .object(let o):
            return .object(o)
        case .list(let l):
            return .list(l)
        default:
            let json = (try? value.jsonString()) ?? "null"
            return .string(json)
        }
    }
    
    var ai: AIInterface {
        didSet {
            ai.send = { [weak self] (title, type, content, topic, origin, context) in
                guard let self = self else { return }
                let flowContent = self.toFlowElementValueType(content)
                let contentType: FlowElementContentType = {
                    switch content {
                    case .object, .list:
                        return .dslv17
                    case .string:
                        return .string
                    case .data:
                        return .base64
                    default:
                        return .string
                    }
                }()
                var msg = FlowElement(title: title, content: flowContent, properties: .init(type: type, contentType: contentType))
                // Further processing of msg...
            }
        }
    }
    
    // Other members of AppleIntelligenceCell...
}
