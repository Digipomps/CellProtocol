// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation


public struct ConnectContext {
    public let identity: Identity?
    
    public var target:  Emit?  {
        get async throws {
            switch targetRepresentation {
            case .embedded(let emit):
                return emit
            case .reference(let uuid):
                guard let resolver = CellBase.defaultCellResolver,
                      let identity = identity else {
                    return nil
                    // Should we start throwing here?
                }
                
                    let emit = try await resolver.cellAtEndpoint(endpoint: "cell://\(uuid)", requester: identity)
                    return emit
            case .none:
                return nil
            }
            
            throw ConnectContextError.otherError
        }
    }
    
    public var source: Absorb? {
        get async throws {
            switch sourceRepresentation {
            case .embedded(let absorb):
                return absorb
            case .reference(let uuid):
                guard let resolver = CellBase.defaultCellResolver,
                      let identity = identity else {
                    return nil
                    // Should we start throwing here?
                }
                
                    let emit = try await resolver.cellAtEndpoint(endpoint: "cell://\(uuid)", requester: identity)
                if let absorb = emit as? Absorb {
                    return absorb
                }
                  throw ConnectContextError.notRegistered
            case .none:
                return nil
            }
            
            throw ConnectContextError.otherError
        }
            
    }
    
     public let sourceRepresentation: AbsorbCellRepresentation
     public let targetRepresentation: EmitCellRepresentation
    
    public init(source: Absorb?, target: Emit?, identity: Identity?) {
        self.identity = identity
        if let source = source {
            sourceRepresentation = .embedded(source)
        } else {
            sourceRepresentation = .none
        }
        if let target = target {
            targetRepresentation = .embedded(target)
        } else {
            targetRepresentation = .none
        }
    }
}

public enum EmitCellRepresentation: Codable {
    case reference(String)
    case embedded(Emit)
    case none
    
    public init(from decoder: Decoder) throws {
//        do {
//            let singleValueContainer = try decoder.singleValueContainer()
//            let value = try singleValueContainer.decode(Emit.self)
//            self = .embedded(value)
//            return
//        } catch {}
        do {
            let singleValueContainer = try decoder.singleValueContainer()
            let value = try singleValueContainer.decode(String.self)
            self = .reference(value)
            return
        } catch {}
        
        throw ConnectContextError.noTarget
        
        
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .reference(value):
                try container.encode(value) //
            
        case let .embedded(value):
            try container.encode(value.uuid)
            
        case .none: ()
        }
    }
}

public enum AbsorbCellRepresentation: Codable {
    case reference(String)
    case embedded(Absorb)
    case none
    
    public init(from decoder: Decoder) throws {
//        do {
//            let singleValueContainer = try decoder.singleValueContainer()
//            let value = try singleValueContainer.decode(Absorb.self)
//            self = .embedded(value)
//            return
//        } catch {}
        do {
            let singleValueContainer = try decoder.singleValueContainer()
            let value = try singleValueContainer.decode(String.self)
            self = .reference(value)
            return
        } catch {}
        
        throw ConnectContextError.noSource
        
        
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .reference(value):
            try container.encode(value) //
        case let .embedded(value):
            if let value = value as? Emit {
                try container.encode(value.uuid)
            }
        case .none: ()
        }
    }
}


extension ConnectContext: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.identity = try container.decodeIfPresent(Identity.self, forKey: .identity)
        self.sourceRepresentation = try container.decode(AbsorbCellRepresentation.self, forKey: .sourceRepresentation)
        self.targetRepresentation = try container.decode(EmitCellRepresentation.self, forKey: .targetRepresentation)
    }
}

public enum ConnectContextError: Error {
    case noTarget
    case noSource
    case noIdentity
    case otherError
    case notRegistered
}

/*
 enum DIDVerification: Codable {
     case embedded(DIDVerificationMethod)
     case reference(String)
     
     // write decoding encoding methods...
     public init(from decoder: Decoder) throws {
         do {
             let singleValueContainer = try decoder.singleValueContainer()
             let value = try singleValueContainer.decode(DIDVerificationMethod.self)
             self = .embedded(value)
             return
         } catch {}
         do {
             let singleValueContainer = try decoder.singleValueContainer()
             let value = try singleValueContainer.decode(String.self)
             self = .reference(value)
             return
         } catch {}
         
         throw DIDError.noVerificationMethod
         
         
     }
     
     public func encode(to encoder: Encoder) throws {
         var container = encoder.singleValueContainer()
         switch self {
         case let .reference(value):
             try container.encode(value) //
         case let .embedded(value):
             try container.encode(value)
         }
     }
 }
 
 */
