// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public struct ProvedClaimCondition : Equatable, Codable, Condition {
    public var uuid: String
    /*
     The Prove condition embeds a statement that has to resolve to true
     F.ex identity.person.age > 18
     or
     I have a signed ticket for entering
     or
     {
     "@context": [
     "https://www.w3.org/2018/credentials/v1"
     ],
     "type": ["VerifiableCredential", "UniversityDegree"],
     "id": "urn:credential:34502108-4540",
     "issuer": "did:web:socrates-university.auth0lab.com",
     "issuanceDate": "2020-07-20T13:58:53Z",
     "credentialSubject": {
     "id": "urn:university:eng:90312",
     "entitlementIdentifier": "90312",
     "name": "Hanna Herwitz",
     "title": "Electrical Engineer",
     "description": "Hanna graduated with honors as an Electrical Engineer",
     "dateOfIssue": "2019-06-15",
     "expiryDate": "2025-03-01",
     "directedBy": "Socrates University",
     "location": "United States",
     },
     "credentialStatus": {
     "id": "https://socrates-university.auth0lab.com/vcs/credential/status/14",
     "type": "CredentialStatusList2017"
     }
     "proof": {
     "type": "Ed25519Signature2020",
     "created": "2020-07-20T13:58:53Z",
     "proofPurpose": "assertionMethod",
     "verificationMethod": "https://socrates-university.auth0lab.com/keys/1",
     "proofValue": "z2ty8BNvrKCvAXGqJVXF8aZ1jK5o5uXFvhXJksUXhn61uSwJJmWdcntfqvZTLbWmQHpieyhdcrG43em37Jo8bswvR"
     }
     }
     
     credentialSubject.name = Hanna Herwitz | is valid (signed) |
     */
    
    public init(name: String, statement: String) {
        self.uuid = UUID().uuidString
        self.name = name
        self.statement = statement // person.age > 18 or relations,smi. ...how to express that some sum is paid
        // statement must express that
    }

    public var name: String
    public var statement: String
//    public var targetKeypath: String = "target.addClaim" // Target keypath could also be cell://
    
    public func isMet(context: ConnectContext) async -> ConditionState {
        var state = ConditionState.unresolved
        CellBase.diagnosticLog("ProvedClaimCondition.isMet statement=\(statement)", domain: .agreement)
        
        // If the owner of the target cell is the same as the issuer then we don't (necessecerily ) have to involve the user in granting access
        
        if let keypathExpression = AnyKeypathExpression.parseStatement(statement),
           let identity = context.identity // The identity here is representing the user og is the basis for whats allowed
        {
            do {
                let value = try await getValueAtConditionKeypath(keypathExpression: keypathExpression, connectContext: context)
                guard let targetOwner = try await context.target?.getOwner(requester: identity) else {// Is this a requirement? Aka should we use guard?
                    throw CellBaseError.noIdentity
                }
                
                let operatorString = keypathExpression.operatorString
                let keypathValue = keypathExpression.value
                switch value {
                case .object( let vCClaimObject):
                    let claim = try convertToClaim( vCClaimObject) // Catch error and report
                    if try await claim.verify() { //
                        CellBase.diagnosticLog("ProvedClaimCondition claim verified", domain: .agreement)

                        let contextId = trustContextId(keypathExpression: keypathExpression)
                        let trustedByPolicy = await evaluateIssuerTrust(
                            claim: claim,
                            contextId: contextId,
                            requester: identity
                        )

                        // Backward-compatible fallback while trust policy rollout happens.
                        let trustedByOwner = await issuerIsTargetOwner(claim: claim, owner: targetOwner, requester: identity)
                        if !trustedByPolicy && !trustedByOwner {
                            return .unresolved
                        }
                        
                        // check statement
                        //
                        // ensure that there's sufficient grants to reach
                        // if user need to be involved send flowItem via ... Identity?
                        
                        state = .met
                    } else {
                        print("Value at keypath not valid VC")
                        // VC did exist but was not valid
                    }
                    
                case .string(let string): // For all the following we need to find the corresponding Verifible Credential
                    CellBase.diagnosticLog("ProvedClaimCondition comparing string value", domain: .agreement)
                
                    switch keypathExpression.operatorString {
                    case "=":
                        if case let .string(statementString) = keypathExpression.value {
                            if string == statementString {
                                state = .met
                                break
                            }
                        }
                    default:
                        print("Operator not relevant for String: \(keypathExpression.operatorString)")
                    }
                    
                    
                case .bool(let bool):
                    CellBase.diagnosticLog("ProvedClaimCondition comparing bool value", domain: .agreement)
                    switch keypathExpression.operatorString {
                    case "=":
                        if case let .bool(statementBool) = keypathExpression.value {
                            if bool == statementBool {
                                state = .met
                                break
                            }
                        }
                    default:
                        print("Operator not relevant for Bool: \(keypathExpression.operatorString)")
                    }
                    
                case .number(let int):
                    CellBase.diagnosticLog("ProvedClaimCondition comparing number value", domain: .agreement)
                    switch keypathExpression.operatorString {
                    case "=":
                        if case let .int(statementInteger) = keypathExpression.value {
                            if int == statementInteger {
                                state = .met
                                break
                            }
                        }
                        
                    case "<":
                        if case let .int(statementInteger) = keypathExpression.value {
                            if int < statementInteger {
                                state = .met
                                break
                            }
                        }
                        
                        
                    case ">":
                        if case let .int(statementInteger) = keypathExpression.value {
                            if int > statementInteger {
                                state = .met
                                break
                            }
                        }
                        
                    case "<=":
                        if case let .int(statementInteger) = keypathExpression.value {
                            if int <= statementInteger {
                                state = .met
                                break
                            }
                        }
                        
                    case ">=":
                        if case let .int(statementInteger) = keypathExpression.value {
                            if  int >= statementInteger {
                                state = .met
                                break
                            }
                        }
                    default:
                        print("Operator not relevant for number: \(keypathExpression.operatorString)")
                    }
                    
                case .integer(let int):
                    CellBase.diagnosticLog("ProvedClaimCondition comparing integer value", domain: .agreement)
                    switch keypathExpression.operatorString {
                    case "=":
                        if case let .int(statementInteger) = keypathExpression.value {
                            if int == statementInteger {
                                state = .met
                                break
                            }
                        }
                        
                    case "<":
                        if case let .int(statementInteger) = keypathExpression.value {
                            if int < statementInteger {
                                state = .met
                                break
                            }
                        }
                        
                        
                    case ">":
                        if case let .int(statementInteger) = keypathExpression.value {
                            if int > statementInteger {
                                state = .met
                                break
                            }
                        }
                        
                    case "<=":
                        if case let .int(statementInteger) = keypathExpression.value {
                            if int <= statementInteger {
                                state = .met
                                break
                            }
                        }
                        
                    case ">=":
                        if case let .int(statementInteger) = keypathExpression.value {
                            if  int >= statementInteger {
                                state = .met
                                break
                            }
                        }
                    default:
                        print("Operator not relevant for Integer: \(keypathExpression.operatorString)")
                    }
                    
                case .float(let statementFloat):
                    CellBase.diagnosticLog("ProvedClaimCondition comparing float value", domain: .agreement)
                    
                default:
                    print("Got unsupported statement value: \(value)")
                    
                }
                
            } catch KeyPathError.notFound(let erroredKeypath){
                print("No value found at \(erroredKeypath)")
            } catch KeypathStorageErrors.denied {
                print("Getting value at condition keypath was denied")
            } catch {
                print("Getting condition value failed with error: \(error)")
            }
            
        }
        // check if grant is valid.
        // How to lookup identity, source and target cell?
        
        
        
        
        return state
    }
    
    func getClaim(for keypath: String, requester: Identity) -> VCClaim? {
        // identity.claims.keypaths.<keypath> = <claimId>
        return nil
    }
    
    func issuerIsTargetOwner(claim: VCClaim, owner: Identity, requester: Identity) async -> Bool {
        do {
            let ownerUuidValue = try await requester.get(keypath: "relations.issuers.\(claim.issuer)", requester: requester)
            if case let .string(ownerUuid) = ownerUuidValue {
                if ownerUuid == owner.uuid {
                    return true
                }
            }
            
        } catch {
            print("Getting ownerUuid from issuer failed with error: \(error)")
        }
        return false
    }
    
    func getValueAtConditionKeypath(keypathExpression: AnyKeypathExpression, connectContext: ConnectContext) async throws -> ValueType {
        let keypath = keypathExpression.keypath
        let contextKey = keypathExpression.keypathComponents[0]
        guard let identity = connectContext.identity else {
            throw CellBaseError.noIdentity
        }
        
        
        switch contextKey {
        case "identity":
            CellBase.diagnosticLog("ProvedClaimCondition.isMet lookup=identity", domain: .agreement)
            let shortenedKeypath = deletePrefix("identity.", from: keypath)
            return try await identity.get(keypath: shortenedKeypath, requester: identity)
            
            
        case "source":
            guard let source = try await connectContext.source as? Meddle else {
                throw CellBaseError.noSourceCell
            }
            CellBase.diagnosticLog("ProvedClaimCondition.isMet lookup=source", domain: .agreement)
            let shortenedKeypath = deletePrefix("source.", from: keypath)
            return try await source.get(keypath: shortenedKeypath, requester: identity)
             
        case "target":
            guard let target = try await connectContext.target as? Meddle else {
                throw CellBaseError.noTargetCell
            }
            CellBase.diagnosticLog("ProvedClaimCondition.isMet lookup=target", domain: .agreement)
            let shortenedKeypath = deletePrefix("target.", from: keypath)
            
            return try await target.get(keypath: shortenedKeypath, requester: identity)
            
        default:
            print("Unknown lookup key: \(contextKey)")
        }
        throw DataError.unknownCase
    }
    
    // Transfor this method into getting hints of how to resolve an unresolved condition?
    public func resolve(context: ConnectContext) async {
        var state = ConditionState.unresolved
        CellBase.diagnosticLog("ProvedClaimCondition.resolve statement=\(statement)", domain: .agreement)
        
        if let keypathExpression = AnyKeypathExpression.parseStatement(statement),
           let identity = context.identity
        {
            let keypath = keypathExpression.keypath
            let contextKey = keypathExpression.keypathComponents[0]
            switch contextKey {
            case "identity":
                CellBase.diagnosticLog("ProvedClaimCondition.resolve lookup=identity", domain: .agreement)
                let shortenedKeypath = deletePrefix("identity.", from: keypath)
                /*
                 cases for retrieval og vc and data
                 ticket -> self contained in vc
                 value claim backed by vc
                 */
                do {
                    // is it is a claimvalue then verify it and addit to target
                    let value = try await identity.get(keypath: shortenedKeypath, requester: identity)
                   
                    if case let .object(vCClaimObject) = value {
                        let claim = try convertToClaim( vCClaimObject)
                        // The identity here is representing the user og is the basis for whats allowed
                        guard let targetOwner = try await context.target?.getOwner(requester: identity) else {
                            throw ConditionError.noTargetOwner
                        }
                        
                        if !(await issuerIsTargetOwner(claim: claim, owner: targetOwner, requester: identity)) {
//                            return .unresolved
                        }
                        
                        if try await claim.verify() { //
                            // We are in identity now - so lookup there. get context target as meddle later on...
                            CellBase.diagnosticLog("ProvedClaimCondition.resolve claim verified", domain: .agreement)
//                            if let targetMeddle = try await context.target as? Meddle {
//                                let targetShortenedKeypath = deletePrefix("target.", from: targetKeypath)
//                                let response = try await targetMeddle.set(keypath: targetShortenedKeypath, value: value, requester: identity)
//                            }
                            
                            // set claim in target keypath? f.ex source.claims
                            
                            // check statement
                            //
                            // ensure that there's sufficient grants to reach
                            // if user need to be involded send flowItem via ... Identity?
                            
                            state = .met
                        } else {
                          // get vc for keypath
                            print("Value at keypath not valid VC")
                        }
                    } else {
                        print("No claim objectValue!")
                        
                        // 1. extrect value
                        // 2. find vc
                        // 3. evaluate expression
                    }
                    // if it is not a verifiable credential we must start to look for backing of the value
                } catch ValueTypeError.unexpectedValueType {
                    
                } catch {
                    print("ProvedClaim error (resolve): \(error) keypath: \(shortenedKeypath)")
                }
                
                // check grants in identity
                //                        if context.identity.granted(grant) {
                //                            state = .met
                //                        }
                
            case "source":
                let shortenedKeypath = deletePrefix("source.", from: keypath)
                CellBase.diagnosticLog("ProvedClaimCondition.resolve lookup=source", domain: .agreement)
                
                
            case "target":
                let shortenedKeypath = deletePrefix("target.", from: keypath)
                CellBase.diagnosticLog("ProvedClaimCondition.resolve lookup=target", domain: .agreement)
            default:
                print("Unknown lookup key: \(contextKey)")
            }
        }
    }
    
    
    
    func deletePrefix(_ prefix: String, from string: String) -> String {
        guard string.hasPrefix(prefix) else { return string }
        return String(string.dropFirst(prefix.count))
    }
    
    func convertToClaim(_ claimObject: Object) throws -> VCClaim {
        
        let claimObjectJson = try JSONEncoder().encode(claimObject)
        let claim = try JSONDecoder().decode(VCClaim.self, from: claimObjectJson)
        
        return claim
    }

    func trustContextId(keypathExpression: AnyKeypathExpression) -> String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return "prove:\(keypathExpression.keypath)"
    }

    func evaluateIssuerTrust(claim: VCClaim, contextId: String, requester: Identity) async -> Bool {
        guard let resolver = CellBase.defaultCellResolver else {
            return false
        }
        guard
            let trustedIssuerEmit = try? await resolver.cellAtEndpoint(endpoint: "cell:///TrustedIssuers", requester: requester),
            let trustedIssuerMeddle = trustedIssuerEmit as? Meddle
        else {
            return false
        }

        do {
            let claimObject = try convertClaimToObject(claim)
            let requesterId = (try? requester.did()) ?? requester.uuid
            let payload: Object = [
                "issuerId": .string(issuerReference(claim.issuer)),
                "contextId": .string(contextId),
                "requesterId": .string(requesterId),
                "candidateVc": .object(claimObject)
            ]
            let response = try await trustedIssuerMeddle.set(
                keypath: "trustedIssuers.evaluate",
                value: .object(payload),
                requester: requester
            )
            guard
                let response,
                case .object(let responseObject) = response,
                case .string(let decision)? = responseObject["decision"]
            else {
                return false
            }
            return decision == "trusted"
        } catch {
            print("Trusted issuer evaluation failed with error: \(error)")
        }
        return false
    }

    func convertClaimToObject(_ claim: VCClaim) throws -> Object {
        let claimJson = try JSONEncoder().encode(claim)
        return try JSONDecoder().decode(Object.self, from: claimJson)
    }

    func issuerReference(_ issuer: IssuerType) -> String {
        switch issuer {
        case .reference(let reference):
            return reference
        case .embedded(let object):
            if case .string(let id)? = object["id"] {
                return id
            }
            return "embedded_issuer"
        }
    }
    
    
    init() {
        name = "Test Proved Claim Condition"
        statement = "identity.person.human = true"
        uuid = UUID().uuidString
        
    }

    func validateVerifiablePresentation(_ verifiablePresentation: VCPresentation ) -> Bool {
        return true
    }
        
    // Experimental method..
    // F.ex this statement: identity.proofs.smi.products.purchased.<prodnum>"
    // Checks for unresolved condition that requires user interaction
    
}
