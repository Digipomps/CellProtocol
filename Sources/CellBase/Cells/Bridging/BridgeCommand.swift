// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum Command: String {
    case ready
    case description // = "&description"
    
    //Emit protocol
    case admit
    case agreement
    case feed
    case state
    case emitter // getEmitterWithUUID - this may not be necessary...
    
    case valueForKeypath
    case setValueForKeypath
    
    // Meddle protocol
    case get
    case set
    
    //Absorb protocol
    case connectEmitter
    case absorbFlow
    case removeConnecion
    case dropFlow
    case disconnectAll
    case unsubscribeAll
    // Absorb extension used to lookup statuses of cells connect over a bridge 
    case attachedStatus
    case attachedStatuses
    
    
    //explore protocol
    case keys
    case typeForKey
    
    case sign
    case response
    case none
}

public enum BridgeError: Error, Codable {
    case timeout
    case someError
}

public struct BridgeCommand: Codable {
    public var cmd: String
    public var command: Command {
        get {
            return Command(rawValue: cmd) ?? .none
        }
    }
    public var identity: Identity?
    public var payload: ValueType?
    public var cid: Int
    public var error: BridgeError?
    
    enum CodingKeys: String, CodingKey
    {
        case cmd // = "&cmd"
        case cid // = "&cid"
        case identity //= "&identity"
        case description = "&description"
        case connectState = "&connectState"
        case agreementState = "&agreementState"
        case agreementPayload = "&agreementPayload"
        case verifiableCredential = "&verifiableCredential"
        case cellConfiguration = "&cellConfiguration"
        case cellReference = "&cellReference"
        case connectContext = "&connectContext"
        case flowElement = "&flowElement"
        case cell = "&cell"
        case keyValue = "&keyValue"
        case setValueState = "&setValueState"
        case setValueResponse = "&setValueResponse"
        
        //client protocol
        case connectEmitter
        case absorbFlow
        case removeConnecion
        case dropFlow
        case disconnectAll 
        case unsubscribeAll
        
        //explore protocol
        case keys
        case typeForKey
        
        case bool
        case float
        case data
        case integer
        
        
        case sign
        case signature = "&signature"
        case object = "&object"
        case number = "&number"
        case string = "&string"
        case list  = "&list"
    }
    //CloudBridgeCommand(cmd: "response", payload: payload, cid: command.cid)
    public init(cmd: String, identity: Identity? = nil, payload: ValueType?, cid: Int) {
        self.cmd = cmd
        self.payload = payload
        self.cid = cid
        self.identity = identity
    }
    
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cmd = try values.decode(String.self, forKey: .cmd)
        cid = try values.decode(Int.self, forKey: .cid)
        identity = try? values.decodeIfPresent(Identity.self, forKey: .identity)
        payload = Self.decodePayload(from: values)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cmd, forKey: .cmd)
        try container.encode(cid, forKey: .cid)
        if identity != nil {
            try container.encode(identity, forKey: .identity)
        }
        if let payload = payload {
            switch payload {
            case let .description(value):
                try container.encode(value, forKey: .description)
                
            case let .flowElement(value):
                try container.encode(value, forKey: .flowElement)
                
            case let .connectState(value):
                try container.encode(value, forKey: .connectState)
                
            case let .contractState(value):
                try container.encode(value, forKey: .agreementState)
                
            case let .agreementPayload(value):
                try container.encode(value, forKey: .agreementPayload)
                
            case let .verifiableCredential(value):
                try container.encode(value, forKey: .verifiableCredential)
                
            case let .keyValue(value):
                try container.encode(value, forKey: .keyValue)
                
            case let .setValueState(value):
                try container.encode(value, forKey: .setValueState)
            case let .setValueResponse(value):
                try container.encode(value, forKey: .setValueResponse)
                
            case let .signData(value):
                try container.encode(value, forKey: .sign)
                
            case let .signature(value):
                try container.encode(value, forKey: .signature)
                
            case let .object(value):
                try container.encode(value, forKey: .object)
                
            case let .list(value):
                try container.encode(value, forKey: .list)
                
            case let .string(value):
                try container.encode(value, forKey: .string)
                
            case let .number(value):
                try container.encode(value, forKey: .number)
                

                
//            default:
//                print("Got something to encode with unknown type: \(String(describing: payload))")
            case let .bool(value):
                try container.encode(value, forKey: .bool)
            case let .integer(value):
                try container.encode(value, forKey: .integer)
            case let .float(value):
                try container.encode(value, forKey: .float)
            case let .data(value):
                try container.encode(value, forKey: .data)
            case let .cellConfiguration(value):
                try container.encode(value, forKey: .cellConfiguration)
            case let .cellReference(value):
                try container.encode(value, forKey: .cellReference)
            case let .identity(value):
                try container.encode(value, forKey: .identity)
            case let .connectContext(value):
                try container.encode(value, forKey: .connectContext)
            case let .cell(value):
                try container.encode(value, forKey: .cell)
            case .null:
                break
            }
        }
    }

    private static let payloadDecodingKeys: [CodingKeys] = [
        .agreementPayload,
        .description,
        .connectState,
        .agreementState,
        .verifiableCredential,
        .flowElement,
        .object,
        .list,
        .string,
        .number,
        .float,
        .data,
        .bool,
        .integer,
        .cellReference,
        .cellConfiguration,
        .cell,
        .keyValue,
        .setValueState,
        .setValueResponse,
        .sign,
        .signature,
        .connectEmitter,
        .absorbFlow,
        .removeConnecion,
        .dropFlow,
        .disconnectAll,
        .unsubscribeAll,
        .keys,
        .typeForKey
    ]

    private static func decodePayload(
        from values: KeyedDecodingContainer<CodingKeys>
    ) -> ValueType? {
        for key in payloadDecodingKeys {
            if let typedValue = try? values.decodeIfPresent(ValueType.self, forKey: key) {
                return typedValue
            }
        }
        return nil
    }
}
