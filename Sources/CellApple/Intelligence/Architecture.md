//
//  AppleIntelligenceCell.swift
//

import Foundation
import DSFValueBinders
import os.log

public actor AppleIntelligenceCell: GeneralCell {
    
    static let log = OSLog(subsystem: "com.example.AppleIntelligence", category: "AppleIntelligenceCell")
    
    // MARK: - Properties
    
    public var outbox: [ValueType] = []
    
    // MARK: - Initialization
    
    public override init(owner: Identity) async throws {
        try await super.init(owner: owner)
        try await setupKeys()
    }
    
    // MARK: - Interceptor Setup
    
    private func setupKeys() async throws {
        let owner = self.owner
        
        // GET interceptor for "ai.state"
        await addInterceptForGet(requester: owner, key: "ai.state") { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            let snapshot = await self.assistant.snapshotPayload(from: self, requester: requester)
            return snapshot
        }
        
        // SET interceptor for "ai.send"
        await addInterceptForSet(requester: owner, key: "ai.send") { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            
            let content: ValueType = (value["content"] ?? .null)
            let flowContent = self.toFlowElementValueType(content)
            let contentType: FlowElementContentType = {
                switch content {
                case .object, .list: return .dslv17
                case .string: return .string
                case .data: return .base64
                default: return .string
                }
            }()
            
            var msg = FlowElement(title: "", content: flowContent, properties: .init(type: .event, contentType: contentType))
            msg.topic = "ai.intent.requestConfigurations"
            msg.origin = self.uuid
            
            if await self.validateAccess("-w--", at: "feed", for: requester) {
                self.pushFlowElement(msg, requester: requester)
                return .string("ok")
            } else {
                return .string("access denied")
            }
        }
    }
    
    // MARK: - Helper
    
    private func toFlowElementValueType(_ value: ValueType) -> FlowElementValueType {
        switch value {
        case .string(let s): return .string(s)
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .integer(let i): return .number(i)
        case .float(let d): return .string(String(d))
        case .data(let data): return .data(data)
        case .object(let o): return .object(o)
        case .list(let l): return .list(l)
        default:
            let json = (try? value.jsonString()) ?? "null"
            return .string(json)
        }
    }
    
    // MARK: - Outbox
    
    public func enqueueOutboxMessage(_ message: ValueType) {
        // Only accept object messages
        guard case .object = message else { return }
        outbox.append(message)
    }
}
