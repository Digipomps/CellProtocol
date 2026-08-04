// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import Crypto

/// Domain-separated SHA-256 utility for callers that bind observed action
/// facts. Components are length-prefixed, so concatenation cannot create
/// ambiguous byte sequences.
public enum PurposeBindingDigest {
    public static func sha256(domain: String, components: [Data]) -> String {
        var input = Data(domain.utf8)
        input.append(0)
        for component in components {
            var length = UInt64(component.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(component)
        }
        let digest = SHA256.hash(data: input)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(domain: String, strings: [String]) -> String {
        sha256(domain: domain, components: strings.map { Data($0.utf8) })
    }
}

public enum PurposeBoundActionStatus: String, Codable, Sendable {
    case proposed
    case reviewRequired = "review_required"
    case blocked
}

public enum PrimaryPurposeSelection: String, Codable, Sendable {
    case ownerConfirmed = "owner_confirmed"
    case deterministicResolution = "deterministic_resolution"
    case unknown
}

public enum PurposeEffectKind: String, Codable, Sendable {
    case externalDisclosure = "external_disclosure"
    case providerInvocation = "provider_invocation"
    case externalWrite = "external_write"
    case externalPublish = "external_publish"
    case subprocessExecution = "subprocess_execution"
}

public enum PurposeExecutionMode: String, Codable, Sendable {
    case execute
    case proposeOnly = "propose_only"
    case notRequested = "not_requested"
}

public enum PurposeDestinationClass: String, Codable, Sendable {
    case admittedRecipient = "admitted_recipient"
    case approvedProvider = "approved_provider"
    case ownerControlledStore = "owner_controlled_store"
    case approvedSubprocess = "approved_subprocess"
}

public struct PurposeActionBindings: Codable, Equatable, Sendable {
    public var purposeDigest: String
    public var actionDigest: String
    public var destinationDigest: String
    public var dataManifestDigest: String
    public var planDigest: String
    public var configDigest: String
    public var policyDigest: String
    public var taxonomyDigest: String
    public var payloadDigest: String

    public init(
        purposeDigest: String,
        actionDigest: String,
        destinationDigest: String,
        dataManifestDigest: String,
        planDigest: String,
        configDigest: String,
        policyDigest: String,
        taxonomyDigest: String,
        payloadDigest: String
    ) {
        self.purposeDigest = purposeDigest
        self.actionDigest = actionDigest
        self.destinationDigest = destinationDigest
        self.dataManifestDigest = dataManifestDigest
        self.planDigest = planDigest
        self.configDigest = configDigest
        self.policyDigest = policyDigest
        self.taxonomyDigest = taxonomyDigest
        self.payloadDigest = payloadDigest
    }

    fileprivate var allDigests: [String] {
        [
            purposeDigest, actionDigest, destinationDigest, dataManifestDigest,
            planDigest, configDigest, policyDigest, taxonomyDigest, payloadDigest
        ]
    }
}

public struct PurposeBoundActionIntent: Codable, Equatable, Sendable {
    public static let schemaV1 = "haven.purpose-bound-action-intent.v1"

    public struct Effect: Codable, Equatable, Sendable {
        public struct Destination: Codable, Equatable, Sendable {
            public var destinationRef: String
            public var destinationClass: PurposeDestinationClass

            public init(destinationRef: String, destinationClass: PurposeDestinationClass) {
                self.destinationRef = destinationRef
                self.destinationClass = destinationClass
            }
        }

        public struct DataScope: Codable, Equatable, Sendable {
            public var dataClassRefs: [String]
            public var fieldManifestDigest: String
            public var minimizationDeclared: Bool

            public init(
                dataClassRefs: [String],
                fieldManifestDigest: String,
                minimizationDeclared: Bool = true
            ) {
                self.dataClassRefs = dataClassRefs
                self.fieldManifestDigest = fieldManifestDigest
                self.minimizationDeclared = minimizationDeclared
            }
        }

        public var effectID: String
        public var effectKind: PurposeEffectKind
        public var actionRef: String
        public var executionMode: PurposeExecutionMode
        public var destination: Destination
        public var data: DataScope

        public init(
            effectID: String,
            effectKind: PurposeEffectKind,
            actionRef: String,
            executionMode: PurposeExecutionMode,
            destination: Destination,
            data: DataScope
        ) {
            self.effectID = effectID
            self.effectKind = effectKind
            self.actionRef = actionRef
            self.executionMode = executionMode
            self.destination = destination
            self.data = data
        }

        enum CodingKeys: String, CodingKey {
            case effectID = "effectId"
            case effectKind
            case actionRef
            case executionMode
            case destination
            case data
        }
    }

    public var schema: String
    public var intentID: String
    public var status: PurposeBoundActionStatus
    public var primaryPurposeRef: String
    public var primaryPurposeSelection: PrimaryPurposeSelection
    public var primaryPurposeEvidenceRefs: [String]?
    public var facetRefs: [String]?
    public var facetsAreNonAuthorizing: Bool
    public var effect: Effect
    public var bindings: PurposeActionBindings
    public var createdAt: String

    public init(
        schema: String = Self.schemaV1,
        intentID: String,
        status: PurposeBoundActionStatus,
        primaryPurposeRef: String,
        primaryPurposeSelection: PrimaryPurposeSelection,
        primaryPurposeEvidenceRefs: [String]? = nil,
        facetRefs: [String]? = nil,
        facetsAreNonAuthorizing: Bool = true,
        effect: Effect,
        bindings: PurposeActionBindings,
        createdAt: String
    ) {
        self.schema = schema
        self.intentID = intentID
        self.status = status
        self.primaryPurposeRef = primaryPurposeRef
        self.primaryPurposeSelection = primaryPurposeSelection
        self.primaryPurposeEvidenceRefs = primaryPurposeEvidenceRefs
        self.facetRefs = facetRefs
        self.facetsAreNonAuthorizing = facetsAreNonAuthorizing
        self.effect = effect
        self.bindings = bindings
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case intentID = "intentId"
        case status
        case primaryPurposeRef
        case primaryPurposeSelection
        case primaryPurposeEvidenceRefs
        case facetRefs
        case facetsAreNonAuthorizing
        case effect
        case bindings
        case createdAt
    }
}

public struct CellExecutionPolicy: Codable, Equatable, Sendable {
    public static let schemaV1 = "haven.cell-execution-policy.v1"

    public struct Bindings: Codable, Equatable, Sendable {
        public var configDigest: String
        public var policyDigest: String
        public var taxonomyDigest: String

        public init(configDigest: String, policyDigest: String, taxonomyDigest: String) {
            self.configDigest = configDigest
            self.policyDigest = policyDigest
            self.taxonomyDigest = taxonomyDigest
        }

        fileprivate var allDigests: [String] {
            [configDigest, policyDigest, taxonomyDigest]
        }
    }

    public struct Provenance: Codable, Equatable, Sendable {
        public var policyVersion: String
        public var issuerRef: String
        public var publicationRef: String
        public var signatureRef: String
        public var issuedAt: String

        public init(
            policyVersion: String,
            issuerRef: String,
            publicationRef: String,
            signatureRef: String,
            issuedAt: String
        ) {
            self.policyVersion = policyVersion
            self.issuerRef = issuerRef
            self.publicationRef = publicationRef
            self.signatureRef = signatureRef
            self.issuedAt = issuedAt
        }
    }

    public struct EffectCeiling: Codable, Equatable, Sendable {
        public struct RequiredPermissions: Codable, Equatable, Sendable {
            public var execute: Bool
            public var storage: Bool?
            public var disclosure: Bool?

            public init(execute: Bool = true, storage: Bool? = nil, disclosure: Bool? = nil) {
                self.execute = execute
                self.storage = storage
                self.disclosure = disclosure
            }
        }

        public struct StorageDisclosure: Codable, Equatable, Sendable {
            public var storageRequiresSeparateSPermission: Bool
            public var disclosureRequiresSeparateCapability: Bool
            public var storageDoesNotAuthorizeDisclosure: Bool

            public init(
                storageRequiresSeparateSPermission: Bool = true,
                disclosureRequiresSeparateCapability: Bool = true,
                storageDoesNotAuthorizeDisclosure: Bool = true
            ) {
                self.storageRequiresSeparateSPermission = storageRequiresSeparateSPermission
                self.disclosureRequiresSeparateCapability = disclosureRequiresSeparateCapability
                self.storageDoesNotAuthorizeDisclosure = storageDoesNotAuthorizeDisclosure
            }
        }

        public var ceilingID: String
        public var oneConcreteEffectOnly: Bool
        public var effectKind: PurposeEffectKind
        public var actionRef: String
        public var primaryPurposeRef: String
        public var purposeMatch: String
        public var permittedFacetRefs: [String]?
        public var allowedDestinationRefs: [String]
        public var allowedDataClassRefs: [String]
        public var planDigest: String
        public var requiredPermissions: RequiredPermissions
        public var storageDisclosure: StorageDisclosure

        public init(
            ceilingID: String,
            oneConcreteEffectOnly: Bool = true,
            effectKind: PurposeEffectKind,
            actionRef: String,
            primaryPurposeRef: String,
            purposeMatch: String = "exact_only",
            permittedFacetRefs: [String]? = nil,
            allowedDestinationRefs: [String],
            allowedDataClassRefs: [String],
            planDigest: String,
            requiredPermissions: RequiredPermissions,
            storageDisclosure: StorageDisclosure = .init()
        ) {
            self.ceilingID = ceilingID
            self.oneConcreteEffectOnly = oneConcreteEffectOnly
            self.effectKind = effectKind
            self.actionRef = actionRef
            self.primaryPurposeRef = primaryPurposeRef
            self.purposeMatch = purposeMatch
            self.permittedFacetRefs = permittedFacetRefs
            self.allowedDestinationRefs = allowedDestinationRefs
            self.allowedDataClassRefs = allowedDataClassRefs
            self.planDigest = planDigest
            self.requiredPermissions = requiredPermissions
            self.storageDisclosure = storageDisclosure
        }

        enum CodingKeys: String, CodingKey {
            case ceilingID = "ceilingId"
            case oneConcreteEffectOnly
            case effectKind
            case actionRef
            case primaryPurposeRef
            case purposeMatch
            case permittedFacetRefs
            case allowedDestinationRefs
            case allowedDataClassRefs
            case planDigest
            case requiredPermissions
            case storageDisclosure
        }
    }

    public var schema: String
    public var policyID: String
    public var status: String
    public var configPolicyIsCeilingNotGrant: Bool
    public var parentPurposeImpliesChild: Bool
    public var facetsAreNonAuthorizing: Bool
    public var ownerPathMayBypassExternalActionCeiling: Bool
    public var bindings: Bindings
    public var policyProvenance: Provenance
    public var defaultDecision: String
    public var effectCeilings: [EffectCeiling]

    public init(
        schema: String = Self.schemaV1,
        policyID: String,
        status: String = "normative_draft",
        configPolicyIsCeilingNotGrant: Bool = true,
        parentPurposeImpliesChild: Bool = false,
        facetsAreNonAuthorizing: Bool = true,
        ownerPathMayBypassExternalActionCeiling: Bool = false,
        bindings: Bindings,
        policyProvenance: Provenance,
        defaultDecision: String = "denied",
        effectCeilings: [EffectCeiling]
    ) {
        self.schema = schema
        self.policyID = policyID
        self.status = status
        self.configPolicyIsCeilingNotGrant = configPolicyIsCeilingNotGrant
        self.parentPurposeImpliesChild = parentPurposeImpliesChild
        self.facetsAreNonAuthorizing = facetsAreNonAuthorizing
        self.ownerPathMayBypassExternalActionCeiling = ownerPathMayBypassExternalActionCeiling
        self.bindings = bindings
        self.policyProvenance = policyProvenance
        self.defaultDecision = defaultDecision
        self.effectCeilings = effectCeilings
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case policyID = "policyId"
        case status
        case configPolicyIsCeilingNotGrant
        case parentPurposeImpliesChild
        case facetsAreNonAuthorizing
        case ownerPathMayBypassExternalActionCeiling
        case bindings
        case policyProvenance
        case defaultDecision
        case effectCeilings
    }
}

public enum PurposeAuthorizationStatus: String, Codable, Sendable {
    case eligible
    case denied
    case requiresHumanApproval = "requires_human_approval"
    case expired
}

public enum PurposeAuthorityPath: String, Codable, Sendable {
    case contractGrant = "contract_grant"
    case ownerPath = "owner_path"
    case cellSpecific = "cell_specific"
    /// A denied authorization attempt has no authority path. This avoids
    /// fabricating owner or Contract evidence merely to produce a receipt.
    case none
}

public enum TrustPackageEvidenceStatus: String, Codable, Sendable {
    case current
    case unavailable
    case expired
    case notRequired = "not_required"
}

public struct PurposeAuthorizationContext: Codable, Equatable, Sendable {
    public static let schemaV1 = "haven.purpose-authorization-context.v1"

    public struct IdentityEvidence: Codable, Equatable, Sendable {
        public var identityRef: String
        public var domain: String
        public var proofRef: String
    }

    public struct AuthorityEvidence: Codable, Equatable, Sendable {
        public struct OwnerPathEvidence: Codable, Equatable, Sendable {
            public var present: Bool
            public var mayBypassExternalActionCeiling: Bool
        }

        public var authorityPath: PurposeAuthorityPath
        public var agreementRef: String?
        public var contractRef: String?
        public var grantRef: String?
        public var cellAuthorityRef: String?
        public var ownerPath: OwnerPathEvidence
        public var authorityCurrent: Bool
    }

    public struct TrustPackageEvidence: Codable, Equatable, Sendable {
        public var evidenceRef: String?
        public var status: TrustPackageEvidenceStatus
        public var confersAuthority: Bool

        public init(
            evidenceRef: String? = nil,
            status: TrustPackageEvidenceStatus,
            confersAuthority: Bool = false
        ) {
            self.evidenceRef = evidenceRef
            self.status = status
            self.confersAuthority = confersAuthority
        }
    }

    public struct Checks: Codable, Equatable, Sendable {
        public var oneConcreteEffect: Bool
        public var exactPrimaryPurposeMatch: Bool
        public var parentMatchOnly: Bool
        public var facetMatchOnly: Bool
        public var unknownPurpose: Bool
        public var externalActionCeilingSatisfied: Bool
        public var destinationAllowed: Bool
        public var dataAllowed: Bool
        public var planAllowed: Bool
        public var storagePermissionSatisfied: Bool
        public var disclosureCapabilitySatisfied: Bool
        public var bindingDigestsMatch: Bool
    }

    public var schema: String
    public var contextID: String
    public var intentRef: String
    public var authorizationStatus: PurposeAuthorizationStatus
    public var identity: IdentityEvidence
    public var authority: AuthorityEvidence
    public var trustPackageEvidence: TrustPackageEvidence
    public var checks: Checks
    public var bindings: PurposeActionBindings
    public var denialReasons: [String]?

    enum CodingKeys: String, CodingKey {
        case schema
        case contextID = "contextId"
        case intentRef
        case authorizationStatus
        case identity
        case authority
        case trustPackageEvidence
        case checks
        case bindings
        case denialReasons
    }
}

public enum PurposeDecisionStatus: String, Codable, Sendable {
    case allowed
    case denied
    case requiresHumanApproval = "requires_human_approval"
    case expired
}

public enum PurposeExecutionStatus: String, Codable, Sendable {
    case notExecuted = "not_executed"
    case started
    case completed
    case failed
    case notAttempted = "not_attempted"
}

public struct ActionDecisionReceipt: Codable, Equatable, Sendable {
    public static let schemaV1 = "haven.action-decision-receipt.v1"

    public struct Checks: Codable, Equatable, Sendable {
        public var exactPrimaryPurposeMatch: Bool
        public var externalActionCeilingSatisfied: Bool
        public var storageDoesNotAuthorizeDisclosure: Bool
        public var trustPackageDidNotAuthorize: Bool
        public var ownerPathDidNotBypassCeiling: Bool
        public var bindingDigestsMatch: Bool
    }

    public var schema: String
    public var receiptID: String
    public var intentRef: String
    public var contextRef: String
    public var decisionStatus: PurposeDecisionStatus
    public var executionStatus: PurposeExecutionStatus
    public var authorityPath: PurposeAuthorityPath
    public var checks: Checks
    public var bindings: PurposeActionBindings
    public var reasonCodes: [String]?
    public var containsSecrets: Bool
    public var createdAt: String

    public func recordingExecution(_ status: PurposeExecutionStatus) -> ActionDecisionReceipt {
        var copy = self
        copy.executionStatus = status
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case receiptID = "receiptId"
        case intentRef
        case contextRef
        case decisionStatus
        case executionStatus
        case authorityPath
        case checks
        case bindings
        case reasonCodes
        case containsSecrets
        case createdAt
    }
}

public struct PurposeBoundAuthorizationEvidence: Equatable, Sendable {
    public var identityRef: String
    public var proofRef: String
    public var cellAuthorityRef: String?
    public var trustPackageEvidence: PurposeAuthorizationContext.TrustPackageEvidence
    public var storagePermissionSatisfied: Bool
    public var disclosureCapabilitySatisfied: Bool
    public var parentMatchOnly: Bool
    public var facetMatchOnly: Bool

    public init(
        identityRef: String,
        proofRef: String,
        cellAuthorityRef: String? = nil,
        trustPackageEvidence: PurposeAuthorizationContext.TrustPackageEvidence,
        storagePermissionSatisfied: Bool,
        disclosureCapabilitySatisfied: Bool,
        parentMatchOnly: Bool = false,
        facetMatchOnly: Bool = false
    ) {
        self.identityRef = identityRef
        self.proofRef = proofRef
        self.cellAuthorityRef = cellAuthorityRef
        self.trustPackageEvidence = trustPackageEvidence
        self.storagePermissionSatisfied = storagePermissionSatisfied
        self.disclosureCapabilitySatisfied = disclosureCapabilitySatisfied
        self.parentMatchOnly = parentMatchOnly
        self.facetMatchOnly = facetMatchOnly
    }
}

public struct PurposeBoundAuthorizationIdentifiers: Equatable, Sendable {
    public var contextID: String
    public var receiptID: String
    public var createdAt: String

    public init(contextID: String, receiptID: String, createdAt: String) {
        self.contextID = contextID
        self.receiptID = receiptID
        self.createdAt = createdAt
    }
}

public struct PurposeBoundAuthorizationResult: Equatable, Sendable {
    public var context: PurposeAuthorizationContext
    public var receipt: ActionDecisionReceipt

    public var allowed: Bool { receipt.decisionStatus == .allowed }
}

/// Pure, deterministic authorization for one concrete external effect.
///
/// The caller must bind `observedBindings` to the actual destination, data,
/// plan and payload immediately before the effect. Self-declared intent bytes
/// are not accepted as observed reality. The existing Cell authorization
/// decision supplies authority; the policy and purpose checks can only narrow.
public enum PurposeBoundActionAuthorizer {
    public static func evaluate(
        intent: PurposeBoundActionIntent,
        policy: CellExecutionPolicy,
        agreementPolicyBinding: AuthorizationPolicyBinding?,
        observedBindings: PurposeActionBindings,
        authorizationDecision: CellAuthorizationDecision,
        evidence: PurposeBoundAuthorizationEvidence,
        identifiers: PurposeBoundAuthorizationIdentifiers
    ) -> PurposeBoundAuthorizationResult {
        var reasons = [String]()
        func deny(_ condition: Bool, _ reason: String) {
            if condition && reasons.contains(reason) == false {
                reasons.append(reason)
            }
        }

        let unknownPurpose = intent.primaryPurposeRef == "purpose://prompt.unknown"
            || intent.primaryPurposeSelection == .unknown
        let purposeAndPolicyShapeValid = intent.schema == PurposeBoundActionIntent.schemaV1
            && policy.schema == CellExecutionPolicy.schemaV1
            && policy.status == "normative_draft"
            && policy.configPolicyIsCeilingNotGrant
            && policy.parentPurposeImpliesChild == false
            && policy.facetsAreNonAuthorizing
            && policy.ownerPathMayBypassExternalActionCeiling == false
            && policy.defaultDecision == "denied"
            && intent.facetsAreNonAuthorizing
            && intent.effect.data.minimizationDeclared
            && purposeRefIsValid(intent.primaryPurposeRef)
            && opaqueRefIsValid(intent.effect.actionRef)
            && opaqueRefIsValid(intent.effect.destination.destinationRef)
            && intent.effect.data.dataClassRefs.isEmpty == false
            && unique(intent.effect.data.dataClassRefs)
            && unique(intent.facetRefs ?? [])
            && unique(intent.primaryPurposeEvidenceRefs ?? [])
            && intent.bindings.allDigests.allSatisfy(digestIsValid)
            && observedBindings.allDigests.allSatisfy(digestIsValid)
            && policy.bindings.allDigests.allSatisfy(digestIsValid)
            && policy.effectCeilings.isEmpty == false
            && unique(policy.effectCeilings.map(\.ceilingID))
            && policy.effectCeilings.allSatisfy(validCeiling)
            && opaqueRefIsValid(policy.policyProvenance.issuerRef)
            && opaqueRefIsValid(policy.policyProvenance.publicationRef)
            && opaqueRefIsValid(policy.policyProvenance.signatureRef)
            && opaqueRefIsValid(evidence.identityRef)
            && opaqueRefIsValid(evidence.proofRef)
        deny(!purposeAndPolicyShapeValid, "invalid_or_unsupported_contract_shape")
        deny(unknownPurpose, "unknown_primary_purpose")
        deny(intent.status == .blocked, "intent_blocked")
        deny(intent.effect.executionMode != .execute, "execution_not_requested")

        let exactCeiling = policy.effectCeilings.first { ceiling in
            ceiling.oneConcreteEffectOnly
                && ceiling.effectKind == intent.effect.effectKind
                && ceiling.actionRef == intent.effect.actionRef
                && ceiling.primaryPurposeRef == intent.primaryPurposeRef
                && ceiling.purposeMatch == "exact_only"
        }
        let exactPrimaryPurposeMatch = exactCeiling != nil
        let destinationAllowed = exactCeiling?.allowedDestinationRefs.contains(
            intent.effect.destination.destinationRef
        ) ?? false
        let dataAllowed = exactCeiling.map {
            Set(intent.effect.data.dataClassRefs).isSubset(of: Set($0.allowedDataClassRefs))
        } ?? false
        let facetsAllowed = exactCeiling.map {
            Set(intent.facetRefs ?? []).isSubset(of: Set($0.permittedFacetRefs ?? []))
        } ?? false
        let planAllowed = exactCeiling?.planDigest == intent.bindings.planDigest
        let requiredStorage = exactCeiling?.requiredPermissions.storage == true
        let requiredDisclosure = exactCeiling?.requiredPermissions.disclosure == true
        let storagePermissionSatisfied = !requiredStorage || evidence.storagePermissionSatisfied
        let disclosureCapabilitySatisfied = !requiredDisclosure || evidence.disclosureCapabilitySatisfied

        deny(!exactPrimaryPurposeMatch, "exact_primary_purpose_or_action_not_allowed")
        deny(evidence.parentMatchOnly, "parent_purpose_match_is_non_authorizing")
        deny(evidence.facetMatchOnly, "facet_match_is_non_authorizing")
        deny(!facetsAllowed, "facet_not_permitted")
        deny(!destinationAllowed, "destination_not_allowed")
        deny(!dataAllowed, "data_class_not_allowed")
        deny(!planAllowed, "plan_not_allowed")
        deny(!storagePermissionSatisfied, "storage_permission_required")
        deny(!disclosureCapabilitySatisfied, "disclosure_capability_required")

        let policyBindingValid = policy.bindings.configDigest == intent.bindings.configDigest
            && policy.bindings.policyDigest == intent.bindings.policyDigest
            && policy.bindings.taxonomyDigest == intent.bindings.taxonomyDigest
            && policy.bindings.configDigest == observedBindings.configDigest
            && policy.bindings.policyDigest == observedBindings.policyDigest
            && policy.bindings.taxonomyDigest == observedBindings.taxonomyDigest
            && agreementPolicyBinding?.policyID == policy.policyID
            && agreementPolicyBinding?.policyVersion == policy.policyProvenance.policyVersion
            && agreementPolicyBinding?.policyDigest == policy.bindings.policyDigest
            && agreementPolicyBinding?.configDigest == policy.bindings.configDigest
            && agreementPolicyBinding?.taxonomyDigest == policy.bindings.taxonomyDigest
            && agreementPolicyBinding?.actionFamily == intent.effect.effectKind.rawValue
        let dynamicBindingsValid = intent.bindings == observedBindings
            && intent.effect.data.fieldManifestDigest == intent.bindings.dataManifestDigest
        let bindingDigestsMatch = policyBindingValid && dynamicBindingsValid
        deny(!bindingDigestsMatch, "binding_digest_mismatch")

        let authority = authorityEvidence(
            decision: authorizationDecision,
            cellAuthorityRef: evidence.cellAuthorityRef
        )
        let authorityBindingValid: Bool
        if authority.authorityPath == .contractGrant {
            authorityBindingValid = authorizationDecision.authorizationPolicyBinding == agreementPolicyBinding
                && authority.agreementRef != nil
                && authority.contractRef != nil
                && authority.grantRef != nil
        } else {
            authorityBindingValid = true
        }
        deny(!authorizationDecision.allowed, "underlying_cell_authorization_denied")
        deny(authorizationDecision.path == .debugBypass, "debug_bypass_cannot_authorize_external_effect")
        deny(authority.authorityPath == .none, "authority_evidence_missing")
        deny(!authority.authorityCurrent, "authority_not_current")
        deny(!authorityBindingValid, "agreement_policy_binding_mismatch")

        let trustEvidenceValid: Bool
        switch evidence.trustPackageEvidence.status {
        case .current:
            trustEvidenceValid = evidence.trustPackageEvidence.evidenceRef.map(opaqueRefIsValid) == true
        case .expired:
            trustEvidenceValid = evidence.trustPackageEvidence.evidenceRef.map(opaqueRefIsValid) == true
        case .notRequired:
            trustEvidenceValid = evidence.trustPackageEvidence.evidenceRef == nil
        case .unavailable:
            trustEvidenceValid = false
        }
        deny(evidence.trustPackageEvidence.confersAuthority, "trust_package_cannot_confer_authority")
        deny(!trustEvidenceValid, "trust_package_evidence_invalid_or_unavailable")

        let ceilingSatisfied = exactCeiling != nil
            && purposeAndPolicyShapeValid
            && facetsAllowed
            && destinationAllowed
            && dataAllowed
            && planAllowed
            && storagePermissionSatisfied
            && disclosureCapabilitySatisfied
            && bindingDigestsMatch
        let status: PurposeAuthorizationStatus
        if evidence.trustPackageEvidence.status == .expired {
            status = .expired
            deny(true, "trust_package_evidence_expired")
        } else if intent.status == .reviewRequired {
            status = .requiresHumanApproval
            deny(true, "human_approval_required")
        } else {
            status = reasons.isEmpty ? .eligible : .denied
        }

        let checks = PurposeAuthorizationContext.Checks(
            oneConcreteEffect: true,
            exactPrimaryPurposeMatch: exactPrimaryPurposeMatch,
            parentMatchOnly: evidence.parentMatchOnly,
            facetMatchOnly: evidence.facetMatchOnly,
            unknownPurpose: unknownPurpose,
            externalActionCeilingSatisfied: ceilingSatisfied,
            destinationAllowed: destinationAllowed,
            dataAllowed: dataAllowed,
            planAllowed: planAllowed,
            storagePermissionSatisfied: storagePermissionSatisfied,
            disclosureCapabilitySatisfied: disclosureCapabilitySatisfied,
            bindingDigestsMatch: bindingDigestsMatch
        )
        let context = PurposeAuthorizationContext(
            schema: PurposeAuthorizationContext.schemaV1,
            contextID: identifiers.contextID,
            intentRef: "intent://\(intent.intentID)",
            authorizationStatus: status,
            identity: .init(
                identityRef: evidence.identityRef,
                domain: authorizationDecision.request.identityDomain,
                proofRef: evidence.proofRef
            ),
            authority: authority,
            trustPackageEvidence: .init(
                evidenceRef: evidence.trustPackageEvidence.evidenceRef,
                status: evidence.trustPackageEvidence.status,
                confersAuthority: false
            ),
            checks: checks,
            bindings: observedBindings,
            denialReasons: reasons.isEmpty ? nil : reasons.sorted()
        )

        let decisionStatus: PurposeDecisionStatus
        switch status {
        case .eligible: decisionStatus = .allowed
        case .denied: decisionStatus = .denied
        case .requiresHumanApproval: decisionStatus = .requiresHumanApproval
        case .expired: decisionStatus = .expired
        }
        let receipt = ActionDecisionReceipt(
            schema: ActionDecisionReceipt.schemaV1,
            receiptID: identifiers.receiptID,
            intentRef: context.intentRef,
            contextRef: "context://\(identifiers.contextID)",
            decisionStatus: decisionStatus,
            executionStatus: decisionStatus == .allowed ? .notExecuted : .notAttempted,
            authorityPath: authority.authorityPath,
            checks: .init(
                exactPrimaryPurposeMatch: exactPrimaryPurposeMatch,
                externalActionCeilingSatisfied: ceilingSatisfied,
                storageDoesNotAuthorizeDisclosure: true,
                trustPackageDidNotAuthorize: true,
                ownerPathDidNotBypassCeiling: true,
                bindingDigestsMatch: bindingDigestsMatch
            ),
            bindings: observedBindings,
            reasonCodes: reasons.isEmpty ? nil : reasons.sorted(),
            containsSecrets: false,
            createdAt: identifiers.createdAt
        )
        return PurposeBoundAuthorizationResult(context: context, receipt: receipt)
    }

    private static func authorityEvidence(
        decision: CellAuthorizationDecision,
        cellAuthorityRef: String?
    ) -> PurposeAuthorizationContext.AuthorityEvidence {
        let path: PurposeAuthorityPath
        switch decision.path {
        case .ownerProof:
            path = .ownerPath
        case .signedContract:
            path = .contractGrant
        case .cellSpecific:
            path = cellAuthorityRef == nil ? .none : .cellSpecific
        default:
            path = .none
        }
        return .init(
            authorityPath: path,
            agreementRef: path == .contractGrant ? decision.agreementRef : nil,
            contractRef: path == .contractGrant ? decision.contractRef : nil,
            grantRef: path == .contractGrant ? decision.grantRef : nil,
            cellAuthorityRef: path == .cellSpecific ? cellAuthorityRef : nil,
            ownerPath: .init(
                present: path == .ownerPath,
                mayBypassExternalActionCeiling: false
            ),
            authorityCurrent: decision.allowed && path != .none
        )
    }

    private static func digestIsValid(_ value: String) -> Bool {
        value.count == 71
            && value.hasPrefix("sha256:")
            && value.dropFirst(7).allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func validCeiling(_ ceiling: CellExecutionPolicy.EffectCeiling) -> Bool {
        ceiling.ceilingID.isEmpty == false
            && ceiling.oneConcreteEffectOnly
            && opaqueRefIsValid(ceiling.actionRef)
            && purposeRefIsValid(ceiling.primaryPurposeRef)
            && ceiling.purposeMatch == "exact_only"
            && ceiling.allowedDestinationRefs.isEmpty == false
            && ceiling.allowedDestinationRefs.allSatisfy(opaqueRefIsValid)
            && unique(ceiling.allowedDestinationRefs)
            && ceiling.allowedDataClassRefs.isEmpty == false
            && unique(ceiling.allowedDataClassRefs)
            && unique(ceiling.permittedFacetRefs ?? [])
            && (ceiling.permittedFacetRefs ?? []).allSatisfy(purposeRefIsValid)
            && digestIsValid(ceiling.planDigest)
            && ceiling.requiredPermissions.execute
            && ceiling.storageDisclosure.storageRequiresSeparateSPermission
            && ceiling.storageDisclosure.disclosureRequiresSeparateCapability
            && ceiling.storageDisclosure.storageDoesNotAuthorizeDisclosure
    }

    private static func purposeRefIsValid(_ value: String) -> Bool {
        guard value.hasPrefix("purpose://"), opaqueRefIsValid(value) else { return false }
        let body = value.dropFirst("purpose://".count)
        guard let first = body.first,
              "abcdefghijklmnopqrstuvwxyz0123456789".contains(first) else {
            return false
        }
        return body.allSatisfy { "abcdefghijklmnopqrstuvwxyz0123456789._/-".contains($0) }
    }

    private static func opaqueRefIsValid(_ value: String) -> Bool {
        guard value.contains(where: { $0.isWhitespace }) == false,
              let separator = value.range(of: "://"),
              separator.lowerBound != value.startIndex,
              separator.upperBound != value.endIndex else {
            return false
        }
        let scheme = value[..<separator.lowerBound]
        guard let first = scheme.first, "abcdefghijklmnopqrstuvwxyz".contains(first) else {
            return false
        }
        return scheme.allSatisfy { "abcdefghijklmnopqrstuvwxyz0123456789+.-".contains($0) }
    }

    private static func unique(_ values: [String]) -> Bool {
        Set(values).count == values.count
    }
}
