// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation


public struct FlowElement : Codable, /*Hashable, */Identifiable {
    
    public var id = UUID.init().uuidString // Just to yank it in... maybe consider removing this...
    public var title: String
    public var topic: String
    public var content: FlowElementValueType
    public var properties: FlowElement.Properties?
    public var origin: String? // uri refering to the cell the feed item originated in (optional)
    
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case topic
        case content
        case properties
        case origin
    }
    public struct Properties: Codable, Hashable {
        public var mimetype: String? = nil
        public var type: FlowElementType
        public var contentType: FlowElementContentType? // Tell us what the contents value represent
        
        public init(mimetype: String? = nil, type: FlowElementType, contentType: FlowElementContentType?) {
            self.mimetype = mimetype
            self.type = type
            self.contentType = contentType
        }
    }
    
    public static func == (lhs: FlowElement, rhs: FlowElement) -> Bool {
        return lhs.id == rhs.id
    }
    
    public init() { // for testing
        self.id = UUID.init().uuidString
        self.title = "Test FlowElement title"
        self.content = .string("FlowElement content string")
        self.properties = Properties(type: .content, contentType: .dslv17)
        self.topic = "*"
    }
    
    public init(id: String = UUID.init().uuidString, title: String, content: FlowElementValueType, properties: Properties? ) { // for testing
        self.id = id
        self.title = title
        self.content = content
        self.properties = properties
        self.topic = "*"
    }
    
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        if let localLabel = try? values.decode(String.self, forKey: .topic) {
        topic = localLabel
        } else {
            topic = "*"
        }
        title = try values.decode(String.self, forKey: .title)
        properties = try? values.decode(Properties.self, forKey: .properties)
        origin = try? values.decodeIfPresent(String.self, forKey: .origin)
        do {
        switch properties?.contentType {
        case .string:
            let decoded = try values.decode(String.self, forKey: .content)
            content = .string(decoded)
        case .dslv17:
            let decoded = try values.decode(Object.self, forKey: .content)
            content = .object(decoded)
        case .rdf:
            let decoded = try values.decode(Object.self, forKey: .content)
            content = .object(decoded)
        case .base64:
            let decoded = try values.decode(String.self, forKey: .content)
            guard let decodedData = Data(base64Encoded: decoded) else {
                throw Swift.DecodingError.dataCorrupted(
                    Swift.DecodingError.Context(
                        codingPath: values.codingPath + [CodingKeys.content],
                        debugDescription: "Expected base64 encoded flow content"
                    )
                )
            }
            content = .data(decodedData)
        case .html:
            let decoded = try values.decode(Object.self, forKey: .content)
            content = .object(decoded)
        case .httpRedirect:
            let decoded = try values.decode(String.self, forKey: .content)
            content = .string(decoded)
        case .login:
            let decoded = try values.decode(Object.self, forKey: .content)
            content = .object(decoded)
        case .experienceTemplate:
            let decoded = try values.decode(Object.self, forKey: .content)
            content = .object(decoded)
        case .object:
            let decoded = try values.decode(Object.self, forKey: .content)
            content = .object(decoded)

        case .none:
            CellBase.diagnosticLog("Untyped FlowElement content", domain: .flow)
            let decoded = try values.decode(Object.self, forKey: .content)
            content = .object(decoded)
        }
        } catch {
            CellBase.diagnosticLog("Decoding feed item content failed with error: \(error)", domain: .flow)
            content = .string("Decoding error")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(topic, forKey: .topic)
        try container.encode(properties, forKey: .properties)
        if origin != nil {
            try container.encode(origin, forKey: .origin)
        }
        switch content {
        case let .string(value):
            try container.encode(value, forKey: .content)
        case let .object(value):
            try container.encode(value, forKey: .content)
        case let .list(value):
            try container.encode(value, forKey: .content)
        case let .data(value):
            try container.encode(value, forKey: .content)
        case let .number(value):
            try container.encode(value, forKey: .content)
        case let .bool(value):
            try container.encode(value, forKey: .content)
        }
        
    }
    
}
