// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

extension BridgeBase {
    public enum Connection {
        case inbound(publisherUuid: String)
        case outbound
    }
    
    public struct Config {
        let owner: Identity
        let agreementTemplate: Agreement?
        let identityDomain: String
        let uuid: String
        let cellRepresentation: AnyCell? = nil
        let transport: BridgeTransportProtocol
        let connection: Connection
        // Pins which local identity resolves an inbound publisher. Command identity
        // is still passed to the publisher for access checks and mutations.
        let inboundPublisherLookupIdentity: Identity?
        // nil uses the discovered direct Cell scope. An explicit list pins the
        // allowed scopes, including before discovery; [] disables local proofs.
        let identityProofScopes: [BridgeIdentityProofScope]?
        
        public init(
            owner: Identity = Identity(),
            contractTemplate: Agreement? = nil,
            identityDomain: String = "bridge",
            uuid: String? = nil,
            transport: BridgeTransportProtocol,
            connection: Connection,
            inboundPublisherLookupIdentity: Identity? = nil,
            identityProofScopes: [BridgeIdentityProofScope]? = nil
        ) {
            self.uuid = uuid ?? UUID().uuidString
            self.owner = owner
            self.agreementTemplate = contractTemplate
            self.identityDomain = identityDomain
            self.transport = transport
            self.connection = connection
            self.inboundPublisherLookupIdentity = inboundPublisherLookupIdentity
            self.identityProofScopes = identityProofScopes
        }
        
        public init(owner: Identity = Identity(), contractTemplate: Agreement? = nil, identityDomain: String = "bridge", uuid: String? = nil, transport: BridgeTransportProtocol, identityProofScopes: [BridgeIdentityProofScope]? = nil) {
            self.uuid = uuid ?? UUID().uuidString
            self.owner = owner
            self.agreementTemplate = contractTemplate
            self.identityDomain = identityDomain
            self.transport = transport
            self.connection = .outbound
            self.inboundPublisherLookupIdentity = nil
            self.identityProofScopes = identityProofScopes
        }
        
        public func getTransport() -> BridgeTransportProtocol {transport}
    }
}
