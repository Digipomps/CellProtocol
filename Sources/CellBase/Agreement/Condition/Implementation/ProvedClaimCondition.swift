// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public struct ProvedClaimCondition : Equatable, Codable, Condition, ConnectChallengeProvidingCondition {
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
    
    public init(
        name: String,
        statement: String,
        requiredCredentialType: String? = nil,
        subjectClaimPath: String? = nil
    ) {
        self.uuid = UUID().uuidString
        self.name = name
        self.statement = statement // person.age > 18 or relations,smi. ...how to express that some sum is paid
        self.requiredCredentialType = requiredCredentialType
        self.subjectClaimPath = subjectClaimPath
        // statement must express that
    }

    public var name: String
    public var statement: String
    public var requiredCredentialType: String?
    public var subjectClaimPath: String?
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
                switch value {
                case .object( let vCClaimObject):
                    let claim = try convertToClaim( vCClaimObject) // Catch error and report
                    guard claimSubjectMatchesRequester(claim, requester: identity) else {
                        CellBase.diagnosticLog(
                            "ProvedClaimCondition rejected credential with wrong or missing subject binding",
                            domain: .agreement
                        )
                        return .unresolved
                    }
                    if try await claim.verify() { //
                        CellBase.diagnosticLog("ProvedClaimCondition claim verified", domain: .agreement)

                        let contextId = trustContextId(keypathExpression: keypathExpression)
                        let trustedByPolicy = await evaluateIssuerTrust(
                            claim: claim,
                            contextId: contextId,
                            requester: identity
                        )

                        // A target owner is not an implicit credential authority.
                        // Issuer trust, validity, and revocation policy must be
                        // evaluated by the TrustedIssuer runtime.
                        if !trustedByPolicy {
                            return .unresolved
                        }

                        guard credentialSatisfiesDeclaredRequirement(
                            claim,
                            expression: keypathExpression,
                            trustedByPolicy: trustedByPolicy
                        ) else {
                            CellBase.diagnosticLog(
                                "ProvedClaimCondition rejected credential not bound to declared type/claim/keypath",
                                domain: .agreement
                            )
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
                    
                default:
                    // Primitive Entity values are assertions made by the Entity
                    // owner, not cryptographic proof. Only a verified credential
                    // envelope may satisfy ProvedClaimCondition.
                    CellBase.diagnosticLog(
                        "ProvedClaimCondition rejected non-credential value",
                        domain: .agreement
                    )
                    return .unresolved
                    
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
        _ = requester
        guard let ownerDID = try? owner.did() else {
            return false
        }
        return issuerReference(claim.issuer) == ownerDID
    }

    private func claimSubjectMatchesRequester(_ claim: VCClaim, requester: Identity) -> Bool {
        guard case .string(let subjectID)? = claim.credentialSubject["id"],
              !subjectID.isEmpty else {
            return false
        }
        guard let requesterDID = try? requester.did() else {
            return false
        }
        return subjectID == requesterDID
    }

    private func credentialSatisfiesDeclaredRequirement(
        _ claim: VCClaim,
        expression: AnyKeypathExpression,
        trustedByPolicy: Bool
    ) -> Bool {
        let normalizedType = requiredCredentialType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedType, normalizedType.isEmpty == false,
           claim.type.contains(normalizedType) == false {
            return false
        }

        let normalizedClaimPath = subjectClaimPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedClaimPath, normalizedClaimPath.isEmpty == false {
            guard let subjectValue = credentialSubjectValue(
                in: claim.credentialSubject,
                path: normalizedClaimPath
            ), parsedComparison(
                subjectValue,
                operatorString: expression.operatorString,
                expected: expression.value
            ) else {
                return false
            }
        } else if trustedByPolicy == false {
            // A target-owner signature alone cannot turn an unrelated credential
            // into proof for an arbitrary condition.
            return false
        }

        let explicitBinding = stringValue(claim.credentialSubject["proofKeypath"])
            ?? stringValue(claim.credentialSubject["roleKeypath"])
        if let explicitBinding {
            let normalizedBinding = explicitBinding.trimmingCharacters(in: .whitespacesAndNewlines)
            let acceptedBindings = Set([
                expression.keypath,
                expression.shortenendKeypath,
                deletePrefix("identity.", from: expression.keypath)
            ].filter { $0.isEmpty == false })
            guard acceptedBindings.contains(normalizedBinding) else {
                return false
            }
        }

        return true
    }

    private func stringValue(_ value: ValueType?) -> String? {
        guard case let .string(string)? = value else { return nil }
        return string
    }

    private func credentialSubjectValue(in subject: Object, path: String) -> ValueType? {
        var components = path.split(separator: ".").map(String.init)
        if components.first == "credentialSubject" {
            components.removeFirst()
        }
        guard let first = components.first, var current = subject[first] else {
            return nil
        }
        for component in components.dropFirst() {
            guard case let .object(object) = current,
                  let nested = object[component] else {
                return nil
            }
            current = nested
        }
        return current
    }

    private func parsedComparison(
        _ actual: ValueType,
        operatorString: String,
        expected: ParsedValue
    ) -> Bool {
        if operatorString == "IN", case let .array(values) = expected {
            return values.contains { parsedComparison(actual, operatorString: "=", expected: $0) }
        }

        let equals = parsedValuesEqual(actual, expected)
        switch operatorString {
        case "=", "==":
            return equals
        case "!=":
            return !equals
        case ">", ">=", "<", "<=":
            guard let actualNumber = numericValue(actual),
                  let expectedNumber = numericValue(expected) else {
                return false
            }
            switch operatorString {
            case ">": return actualNumber > expectedNumber
            case ">=": return actualNumber >= expectedNumber
            case "<": return actualNumber < expectedNumber
            default: return actualNumber <= expectedNumber
            }
        default:
            return false
        }
    }

    private func parsedValuesEqual(_ actual: ValueType, _ expected: ParsedValue) -> Bool {
        switch (actual, expected) {
        case let (.bool(lhs), .bool(rhs)):
            return lhs == rhs
        case let (.string(lhs), .string(rhs)):
            return lhs == rhs
        case let (.string(lhs), .date(rhs)):
            return ISO8601DateFormatter().date(from: lhs) == rhs
        default:
            guard let lhs = numericValue(actual), let rhs = numericValue(expected) else {
                return false
            }
            return lhs == rhs
        }
    }

    private func numericValue(_ value: ValueType) -> Double? {
        switch value {
        case .number(let number), .integer(let number): return Double(number)
        case .float(let number): return number
        default: return nil
        }
    }

    private func numericValue(_ value: ParsedValue) -> Double? {
        switch value {
        case .int(let number): return Double(number)
        case .double(let number): return number
        default: return nil
        }
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
    public func connectChallengeDescriptor(context: ConnectContext) async -> ConnectChallengeDescriptor? {
        let trimmedStatement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmedStatement.isEmpty
            ? "Access requires a verifiable proof for '\(name)'."
            : "Access requires a verifiable proof satisfying: \(trimmedStatement)."
        return ConnectChallengeDescriptor(
            reasonCode: "proof_required",
            userMessage: message,
            requiredAction: "present_verifiable_credential",
            canAutoResolve: false,
            helperCellConfiguration: proofChallengeHelperConfiguration(message: message),
            developerHint: "Provide a verifiable credential or presentation at the identity/source/target keypath referenced by ProvedClaimCondition.statement, and make sure issuer trust policy accepts the issuer."
        )
    }

    private func proofChallengeHelperConfiguration(message: String) -> CellConfiguration {
        var configuration = CellConfiguration(name: "Proof Review")
        configuration.description = "Shows the proof requirement and opens AgreementWorkbench so policy can guide the user to present the required credential."
        configuration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: "cell:///AgreementWorkbench",
            sourceCellName: "AgreementWorkbenchCell",
            purpose: "Resolve proof requirement",
            purposeDescription: "Help the user present a concrete proof or credential before retrying admission.",
            interests: ["agreement", "access", "proofs", "credentials", "retry"],
            menuSlots: ["upperMid"]
        )
        configuration.addReference(CellReference(endpoint: "cell:///AgreementWorkbench", subscribeFeed: false, label: "agreementWorkbench"))
        configuration.skeleton = .VStack(SkeletonVStack(elements: [
            .Text(SkeletonText(text: "Proof required")),
            .Text(SkeletonText(text: message)),
            .Text(SkeletonText(keypath: "agreementWorkbench.state.headline")),
            .Text(SkeletonText(keypath: "agreementWorkbench.state.friendlySummary")),
            .Text(SkeletonText(keypath: "agreementWorkbench.state.saveResult"))
        ]))
        return configuration
    }

    public func resolve(context: ConnectContext) async {
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
                        guard claimSubjectMatchesRequester(claim, requester: identity),
                              try await claim.verify() else {
                            CellBase.diagnosticLog(
                                "ProvedClaimCondition.resolve rejected invalid or wrongly bound credential",
                                domain: .agreement
                            )
                            return
                        }

                        let trustedByPolicy = await evaluateIssuerTrust(
                            claim: claim,
                            contextId: trustContextId(keypathExpression: keypathExpression),
                            requester: identity
                        )
                        guard trustedByPolicy,
                              credentialSatisfiesDeclaredRequirement(
                                  claim,
                                  expression: keypathExpression,
                                  trustedByPolicy: trustedByPolicy
                              ) else {
                            CellBase.diagnosticLog(
                                "ProvedClaimCondition.resolve rejected untrusted or unrelated credential",
                                domain: .agreement
                            )
                            return
                        }

                        CellBase.diagnosticLog("ProvedClaimCondition.resolve claim verified", domain: .agreement)
                    } else {
                        CellBase.diagnosticLog("No claim objectValue", domain: .agreement)
                        
                        // 1. extrect value
                        // 2. find vc
                        // 3. evaluate expression
                    }
                    // if it is not a verifiable credential we must start to look for backing of the value
                } catch ValueTypeError.unexpectedValueType {
                    
                } catch {
                    CellBase.diagnosticLog("ProvedClaim error (resolve): \(error) keypath: \(shortenedKeypath)", domain: .agreement)
                }
                
                // check grants in identity
                //                        if context.identity.granted(grant) {
                //                            state = .met
                //                        }
                
            case "source":
                CellBase.diagnosticLog("ProvedClaimCondition.resolve lookup=source keypath=\(deletePrefix("source.", from: keypath))", domain: .agreement)
                
                
            case "target":
                CellBase.diagnosticLog("ProvedClaimCondition.resolve lookup=target keypath=\(deletePrefix("target.", from: keypath))", domain: .agreement)
            default:
                CellBase.diagnosticLog("Unknown lookup key: \(contextKey)", domain: .agreement)
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
            guard let requesterId = try? requester.did() else {
                return false
            }
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
        requiredCredentialType = nil
        subjectClaimPath = nil
        uuid = UUID().uuidString
        
    }

    // Experimental method..
    // F.ex this statement: identity.proofs.smi.products.purchased.<prodnum>"
    // Checks for unresolved condition that requires user interaction
    
}
