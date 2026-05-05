// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct CellConfigurationDiscovery: Codable, Hashable {
    public var sourceCellEndpoint: String?
    public var sourceCellName: String?
    public var purpose: String?
    public var purposeDescription: String?
    public var interests: [String]
    public var purposeRefs: [String]
    public var interestRefs: [String]
    public var menuSlots: [String]
    public var localizedText: [String: CellConfigurationDiscoveryLocalization]

    public init(
        sourceCellEndpoint: String? = nil,
        sourceCellName: String? = nil,
        purpose: String? = nil,
        purposeDescription: String? = nil,
        interests: [String] = [],
        purposeRefs: [String] = [],
        interestRefs: [String] = [],
        menuSlots: [String] = [],
        localizedText: [String: CellConfigurationDiscoveryLocalization] = [:]
    ) {
        self.sourceCellEndpoint = sourceCellEndpoint
        self.sourceCellName = sourceCellName
        self.purpose = purpose
        self.purposeDescription = purposeDescription
        self.interests = interests
        self.purposeRefs = Self.uniqueSorted(purposeRefs)
        self.interestRefs = Self.uniqueSorted(interestRefs)
        self.menuSlots = menuSlots
        self.localizedText = localizedText
    }

    enum CodingKeys: String, CodingKey {
        case sourceCellEndpoint
        case sourceCellName
        case purpose
        case purposeDescription
        case interests
        case purposeRefs
        case interestRefs
        case menuSlots
        case localizedText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sourceCellEndpoint: try container.decodeIfPresent(String.self, forKey: .sourceCellEndpoint),
            sourceCellName: try container.decodeIfPresent(String.self, forKey: .sourceCellName),
            purpose: try container.decodeIfPresent(String.self, forKey: .purpose),
            purposeDescription: try container.decodeIfPresent(String.self, forKey: .purposeDescription),
            interests: try container.decodeIfPresent([String].self, forKey: .interests) ?? [],
            purposeRefs: try container.decodeIfPresent([String].self, forKey: .purposeRefs) ?? [],
            interestRefs: try container.decodeIfPresent([String].self, forKey: .interestRefs) ?? [],
            menuSlots: try container.decodeIfPresent([String].self, forKey: .menuSlots) ?? [],
            localizedText: try container.decodeIfPresent([String: CellConfigurationDiscoveryLocalization].self, forKey: .localizedText) ?? [:]
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sourceCellEndpoint, forKey: .sourceCellEndpoint)
        try container.encodeIfPresent(sourceCellName, forKey: .sourceCellName)
        try container.encodeIfPresent(purpose, forKey: .purpose)
        try container.encodeIfPresent(purposeDescription, forKey: .purposeDescription)
        try container.encode(interests, forKey: .interests)
        if !purposeRefs.isEmpty {
            try container.encode(purposeRefs, forKey: .purposeRefs)
        }
        if !interestRefs.isEmpty {
            try container.encode(interestRefs, forKey: .interestRefs)
        }
        try container.encode(menuSlots, forKey: .menuSlots)
        if !localizedText.isEmpty {
            try container.encode(localizedText, forKey: .localizedText)
        }
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

public struct CellConfigurationDiscoveryLocalization: Codable, Hashable {
    public var purpose: String?
    public var purposeDescription: String?
    public var interests: [String]

    public init(
        purpose: String? = nil,
        purposeDescription: String? = nil,
        interests: [String] = []
    ) {
        self.purpose = purpose
        self.purposeDescription = purposeDescription
        self.interests = interests
    }
}

public struct CellReference: Hashable {
    public static func == (lhs: CellReference, rhs: CellReference) -> Bool {
        return lhs.label == rhs.label && lhs.endpoint == rhs.endpoint && lhs.setKeysAndValues.count == rhs.setKeysAndValues.count && lhs.subscriptions.count == rhs.subscriptions.count
    }
    
    public var id: String {
        get {
            return "\(label):\(endpoint)" // We colud cache the hash value but may have to do it another way anyway
        }
    }
    public var endpoint: String
    public var subscribeFeed: Bool = true
    public var label: String
//    public var intercept: String? // Maybe lookup a stored closure
//    public var namedIntercepts: [String: String]?
    public var subscriptions = [CellReference]()
    
//    We need a way to configure the newlycreated cell
    public var setKeysAndValues = [KeyValue]()
    
    public init(endpoint: String, subscribeFeed: Bool = true, label: String, intercept: String? = nil, namedIntercepts: [String : String]? = nil, subscriptions: [CellReference]? = nil) {
        self.endpoint = endpoint
        self.subscribeFeed = subscribeFeed
        self.label = label
//        self.intercept = intercept
//        self.namedIntercepts = namedIntercepts
        if let subs = subscriptions {
            self.subscriptions = subs
        }
        
    }
    public mutating func addSubscription(_ subscription: CellReference) {
        subscriptions.append(subscription)
    }
    
    public mutating func addKeyAndValue(_ keyValue: KeyValue) {
        
        setKeysAndValues.append(keyValue)
    }
}

public struct CellConfiguration {
    public var name: String
    public var uuid: String
    public var description: String?
    public var discovery: CellConfigurationDiscovery?
    // instructions on how to configure the target
    public var cellReferences: [CellReference]?
    
    public var skeleton: SkeletonElement?
    
    public mutating func addReference(_ reference: CellReference) {
        if cellReferences == nil {
            cellReferences = [CellReference]()
        }
        cellReferences?.append(reference)
    }
    
    public mutating func removeReference(_ reference: CellReference) {
        if cellReferences == nil {
            cellReferences = [CellReference]()
        }
        cellReferences?.removeAll(where: { ref in
            return ref.id == reference.id
        })
    }
    public init(name: String, cellReferences: [CellReference]? = nil) {
        self.name = name
        self.cellReferences = cellReferences
        self.uuid = UUID().uuidString
        self.skeleton = .Text(SkeletonText(text: "Hello HAVEN"))
    }
}


extension CellConfiguration: Codable {
    enum CodingKeys: String, CodingKey
    {
        case uuid
        case name
        case description
        case discovery
        case cellReferences
        case skeleton
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.uuid) {
            if let suppliedUuid = try? values.decode(String.self, forKey: .uuid) {
                uuid = suppliedUuid
            } else {
                uuid = UUID.init().uuidString
            }
        } else {
            uuid = UUID.init().uuidString
        }
        self.name = try values.decode(String.self, forKey: .name)
        self.description = try values.decodeIfPresent(String.self, forKey: .description)
        self.discovery = try values.decodeIfPresent(CellConfigurationDiscovery.self, forKey: .discovery)
        self.cellReferences = try values.decodeIfPresent([CellReference].self, forKey: .cellReferences)
        self.skeleton = try values.decodeIfPresent(SkeletonElement.self, forKey: .skeleton)
    }
    
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(discovery, forKey: .discovery)
        try container.encode(cellReferences, forKey: .cellReferences)
        try container.encodeIfPresent(skeleton, forKey: .skeleton)
        
    }
}
/*
 public var endpoint: String
 public var subscribeFeed: Bool = true
 public var label: String
//    public var intercept: String? // Maybe lookup a stored closure
//    public var namedIntercepts: [String: String]?
 public var subscriptions = [CellReference]()
 
//    We need a way to configure the newlycreated cell
 public var setKeysAndValues = [KeyValue]()

 */


extension CellReference: Codable {
    enum CodingKeys: String, CodingKey
    {
        case endpoint
        case subscribeFeed
        case label
        case subscriptions
        case setKeysAndValues
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.endpoint = try values.decode(String.self, forKey: .endpoint)
        self.subscribeFeed = try values.decode(Bool.self, forKey: .subscribeFeed)
        self.label = try values.decode(String.self, forKey: .label)

            if let subs = try values.decodeIfPresent([CellReference].self, forKey: .subscriptions) {
            self.subscriptions = subs
        } else {
            self.subscriptions = [CellReference]()
        }
        
        if let keys = try values.decodeIfPresent([KeyValue].self, forKey: .setKeysAndValues) {
            self.setKeysAndValues = keys
        } else {
            self.setKeysAndValues = [KeyValue]()
        }
        
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(subscribeFeed, forKey: .subscribeFeed)
        try container.encode(label, forKey: .label)
        try container.encode(subscriptions, forKey: .subscriptions)
        try container.encode(setKeysAndValues, forKey: .setKeysAndValues)
    }
}
