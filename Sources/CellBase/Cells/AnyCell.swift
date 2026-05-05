// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif


public enum AnyCellError : Error {
    case noOwner
}

public class AnyCell: Emit, Codable {
    public func getOwner(requester: Identity) async throws -> Identity {
        if let owner = self.owner {
            return owner
        }
        throw AnyCellError.noOwner
    }
    
    public func getEmitterWithUUID(_ uuid: String, requester: Identity) async -> (any Emit)? {
        return nil
    }
    
    
    public var cellScope: CellUsageScope
    public var persistancy: Persistancy

    
    public func addAgreement(_ contract: Agreement, for identity: Identity) async -> AgreementState {
        //dummy
        return .template
    }
    
    public func admit(context: ConnectContext) async -> ConnectState {
        // dummy
        return .denied
    }
    
    public func close(requester: Identity) {
        //dummy...
    }
    
    func connect(identity: Identity) -> AnyPublisher<ConnectState, Error> {
        return PassthroughSubject<ConnectState, Error>().eraseToAnyPublisher()
    }
    
    public func addContract(_ contract: Agreement, for identity: Identity) -> AnyPublisher<AgreementState, Error> {
        return PassthroughSubject<AgreementState, Error>().eraseToAnyPublisher()
    }
    
    public func advertise(for identity: Identity) -> AnyCell {
        return self
    }
    
    public func state(requester: Identity) async throws -> ValueType {
        return .string("not implemented")
    }
    
    public var uuid: String
    public var agreementTemplate: Agreement
    public var name: String
    var owner: Identity?
    public var exploreManifest: ExploreManifest?
    
    var experiences: [CellConfiguration]? // Possibly a mix of CellTemplates and CellPublisher?
    var feedEndpoint : URL?
    public var feedProperties: FeedProperties?
    public var identityDomain: String
    
    static private var publishers = [String : Emit]()
    enum CodingKeys: String, CodingKey
    {
        case uuid
        case owner
        case name
        case contractTemplate
        case experiences
        case feedEndpoint
        case feedProperties
        case identityDomain
        case cellScope
        case persistancy
        case exploreManifest
    }
    public init(uuid: String, name: String, contractTemplate: Agreement, owner: Identity? = nil, experiences: [CellConfiguration]? = nil, feedEndpoint : URL? = nil, feedProperties: FeedProperties? = nil, identityDomain: String, cellScope: CellUsageScope = .template, persistancy: Persistancy = .ephemeral, exploreManifest: ExploreManifest? = nil) {
        self.uuid = uuid
        self.name = name
        self.agreementTemplate = contractTemplate
        self.owner = owner
        self.experiences = experiences
        self.feedEndpoint = feedEndpoint
        self.feedProperties = feedProperties
        self.identityDomain = identityDomain
        self.cellScope = cellScope
        self.persistancy = persistancy
        self.exploreManifest = exploreManifest
    }
    
    required public init(from decoder: Decoder) throws {
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

        name = try values.decode(String.self, forKey: .name)
        
        owner = try? values.decode(Identity.self, forKey: .owner)
        
        agreementTemplate = try values.decode(Agreement.self, forKey: .contractTemplate)
        
        experiences =  try? values.decode([CellConfiguration].self, forKey: .experiences)
        
        feedProperties =  try? values.decode(FeedProperties.self, forKey: .feedProperties)
        
        identityDomain = try values.decode(String.self, forKey: .identityDomain)
        
        cellScope = try values.decode(CellUsageScope.self, forKey: .cellScope)
        
        persistancy = try values.decode(Persistancy.self, forKey: .persistancy)

        exploreManifest = try values.decodeIfPresent(ExploreManifest.self, forKey: .exploreManifest)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(name, forKey: .name)
        try container.encode(agreementTemplate, forKey: .contractTemplate)
        try container.encode(feedEndpoint, forKey: .feedEndpoint)
        
        
        if self.owner != nil {
            try container.encode(self.owner, forKey: .owner)
        }
        if let localExperiences = experiences {
            try container.encode(localExperiences, forKey: .experiences)
        }
        
        if let feedProps = feedProperties {
            try container.encode(feedProps, forKey: .feedProperties)
        }
        try container.encode(identityDomain, forKey: .identityDomain)
        
        try container.encode(cellScope, forKey: .cellScope)
        try container.encode(persistancy, forKey: .persistancy)
        try container.encodeIfPresent(exploreManifest, forKey: .exploreManifest)
        //    var state: Dictionary
    }
    
    public func feed(requester: Identity) -> AnyPublisher<FlowElement, Error> {
        fatalError("NOT IMPLEMENTED")

    }
    
    public func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, any Error> {
        fatalError("NOT IMPLEMENTED")
    }
    
    public func startFeed(requester: Identity) {
        fatalError("NOT IMPLEMENTED")
    }
    
    public func getFeedPublisher() -> AnyPublisher<FlowElement, Error> {
        fatalError("NOT IMPLEMENTED")
    }
    
    public func connect(context: ConnectContext) -> AnyPublisher<ConnectState, Error> {
        fatalError("NOT IMPLEMENTED")
    }
    
    func addContract(contract: Agreement, context: ConnectContext) -> AgreementState {
        fatalError("NOT IMPLEMENTED")
        return AgreementState.template
    }
    
    func isMember(identity: Identity) -> Bool {
        return false
    }
    
    func addMember(identity: Identity) {
    }
}
