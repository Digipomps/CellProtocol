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
        
        public init(owner: Identity = Identity(), contractTemplate: Agreement? = nil, identityDomain: String = "bridge", uuid: String? = nil, transport: BridgeTransportProtocol, connection: Connection) {
            self.uuid = uuid ?? UUID().uuidString
            self.owner = owner
            self.agreementTemplate = contractTemplate
            self.identityDomain = identityDomain
            self.transport = transport
            self.connection = connection
        }
        
        public init(owner: Identity = Identity(), contractTemplate: Agreement? = nil, identityDomain: String = "bridge", uuid: String? = nil, transport: BridgeTransportProtocol) {
            self.uuid = uuid ?? UUID().uuidString
            self.owner = owner
            self.agreementTemplate = contractTemplate
            self.identityDomain = identityDomain
            self.transport = transport
            self.connection = .outbound
        }
        
        public func getTransport() -> BridgeTransportProtocol {transport}
    }
}
