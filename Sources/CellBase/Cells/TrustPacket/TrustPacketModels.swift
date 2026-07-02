// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct TrustPacketBoundary: Codable, Equatable {
    public var label: String
    public var purposeRef: String?
    public var audience: String
    public var duration: String
    public var dataCategories: [String]
    public var canRevoke: Bool
    public var canExport: Bool

    public init(label: String, purposeRef: String? = nil, audience: String, duration: String, dataCategories: [String] = [], canRevoke: Bool = true, canExport: Bool = true) {
        self.label = label
        self.purposeRef = purposeRef
        self.audience = audience
        self.duration = duration
        self.dataCategories = dataCategories
        self.canRevoke = canRevoke
        self.canExport = canExport
    }
}

public struct TrustPacketEvidenceRef: Codable, Equatable {
    public var id: String
    public var type: String
    public var issuer: String?
    public var claim: String?
    public var policyRef: String?
    public var status: String
    public var evidenceRef: String?
    public var verifiedAt: String?
    public var summary: String?

    public init(id: String, type: String, issuer: String? = nil, claim: String? = nil, policyRef: String? = nil, status: String = "declared", evidenceRef: String? = nil, verifiedAt: String? = nil, summary: String? = nil) {
        self.id = id
        self.type = type
        self.issuer = issuer
        self.claim = claim
        self.policyRef = policyRef
        self.status = status
        self.evidenceRef = evidenceRef
        self.verifiedAt = verifiedAt
        self.summary = summary
    }
}

public struct TrustPacketDraft: Codable, Equatable {
    public var id: String
    public var packetType: String
    public var title: String
    public var message: String
    public var purposeRef: String?
    public var interestRefs: [String]
    public var audience: String?
    public var recipient: String?
    public var duration: String?
    public var dataCategories: [String]
    public var aiUseSummary: String?
    public var boundaries: [TrustPacketBoundary]
    public var evidenceRefs: [TrustPacketEvidenceRef]
    public var agreementReference: AgreementReference?
    public var updatedAt: String?

    public init(id: String = "trust-packet-draft", packetType: String = "trust.packet.basic", title: String = "Tillitspakke", message: String = "", purposeRef: String? = nil, interestRefs: [String] = [], audience: String? = nil, recipient: String? = nil, duration: String? = nil, dataCategories: [String] = [], aiUseSummary: String? = nil, boundaries: [TrustPacketBoundary] = [], evidenceRefs: [TrustPacketEvidenceRef] = [], agreementReference: AgreementReference? = nil, updatedAt: String? = nil) {
        self.id = id
        self.packetType = packetType
        self.title = title
        self.message = message
        self.purposeRef = purposeRef
        self.interestRefs = interestRefs
        self.audience = audience
        self.recipient = recipient
        self.duration = duration
        self.dataCategories = dataCategories
        self.aiUseSummary = aiUseSummary
        self.boundaries = boundaries
        self.evidenceRefs = evidenceRefs
        self.agreementReference = agreementReference
        self.updatedAt = updatedAt
    }
}

public struct TrustPacketOriginSignature: Codable, Equatable {
    public var signerIdentityId: String
    public var signerDisplayName: String?
    public var signingKeyFingerprint: String?
    public var algorithm: String
    public var payloadHash: String
    public var signature: String
    public var signedAt: String
    public var verificationStatus: String
    public var verificationMessage: String

    public init(signerIdentityId: String, signerDisplayName: String? = nil, signingKeyFingerprint: String? = nil, algorithm: String = "identity.sign.sha256", payloadHash: String, signature: String, signedAt: String, verificationStatus: String, verificationMessage: String) {
        self.signerIdentityId = signerIdentityId
        self.signerDisplayName = signerDisplayName
        self.signingKeyFingerprint = signingKeyFingerprint
        self.algorithm = algorithm
        self.payloadHash = payloadHash
        self.signature = signature
        self.signedAt = signedAt
        self.verificationStatus = verificationStatus
        self.verificationMessage = verificationMessage
    }
}

public struct TrustPacketReceipt: Codable, Equatable {
    public var id: String
    public var packetId: String
    public var packetType: String
    public var status: String
    public var title: String
    public var summary: String
    public var purposeRef: String?
    public var interestRefs: [String]
    public var audience: String
    public var recipient: String?
    public var duration: String
    public var dataCategories: [String]
    public var aiUseSummary: String?
    public var boundaries: [TrustPacketBoundary]
    public var evidenceRefs: [TrustPacketEvidenceRef]
    public var agreementReference: AgreementReference?
    public var explicitConsent: Bool
    public var revokeAvailable: Bool
    public var exportAvailable: Bool
    public var createdAt: String
    public var revokedAt: String?
    public var originSignature: TrustPacketOriginSignature?

    public init(id: String, packetId: String, packetType: String, status: String, title: String, summary: String, purposeRef: String?, interestRefs: [String], audience: String, recipient: String?, duration: String, dataCategories: [String], aiUseSummary: String?, boundaries: [TrustPacketBoundary], evidenceRefs: [TrustPacketEvidenceRef], agreementReference: AgreementReference?, explicitConsent: Bool, revokeAvailable: Bool, exportAvailable: Bool, createdAt: String, revokedAt: String? = nil, originSignature: TrustPacketOriginSignature? = nil) {
        self.id = id
        self.packetId = packetId
        self.packetType = packetType
        self.status = status
        self.title = title
        self.summary = summary
        self.purposeRef = purposeRef
        self.interestRefs = interestRefs
        self.audience = audience
        self.recipient = recipient
        self.duration = duration
        self.dataCategories = dataCategories
        self.aiUseSummary = aiUseSummary
        self.boundaries = boundaries
        self.evidenceRefs = evidenceRefs
        self.agreementReference = agreementReference
        self.explicitConsent = explicitConsent
        self.revokeAvailable = revokeAvailable
        self.exportAvailable = exportAvailable
        self.createdAt = createdAt
        self.revokedAt = revokedAt
        self.originSignature = originSignature
    }
}

public struct TrustPacketPurposeCandidate: Codable, Equatable {
    public var id: String
    public var label: String
    public var purposeRef: String
    public var purposeDescription: String
    public var interestRefs: [String]
    public var goalRefs: [String]
    public var supportingText: String
    public var evidenceRefs: [String]
    public var confidence: Double
    public var requiresApproval: Bool
    public var reviewRequired: Bool
    public var mutatesPerspective: Bool
    public var status: String
    public var createdAt: String?
    public var confirmedAt: String?

    public init(id: String, label: String, purposeRef: String, purposeDescription: String, interestRefs: [String], goalRefs: [String], supportingText: String, evidenceRefs: [String] = [], confidence: Double, requiresApproval: Bool = true, reviewRequired: Bool = true, mutatesPerspective: Bool = false, status: String = "candidate", createdAt: String? = nil, confirmedAt: String? = nil) {
        self.id = id
        self.label = label
        self.purposeRef = purposeRef
        self.purposeDescription = purposeDescription
        self.interestRefs = interestRefs
        self.goalRefs = goalRefs
        self.supportingText = supportingText
        self.evidenceRefs = evidenceRefs
        self.confidence = confidence
        self.requiresApproval = requiresApproval
        self.reviewRequired = reviewRequired
        self.mutatesPerspective = mutatesPerspective
        self.status = status
        self.createdAt = createdAt
        self.confirmedAt = confirmedAt
    }
}

public struct TrustPacketDisclosureRecord: Codable, Equatable {
    public var id: String
    public var receiptId: String
    public var recipient: String
    public var purposeRef: String?
    public var dataCategories: [String]
    public var sharedAt: String
    public var status: String

    public init(id: String, receiptId: String, recipient: String, purposeRef: String?, dataCategories: [String], sharedAt: String, status: String = "shared") {
        self.id = id
        self.receiptId = receiptId
        self.recipient = recipient
        self.purposeRef = purposeRef
        self.dataCategories = dataCategories
        self.sharedAt = sharedAt
        self.status = status
    }
}

public struct TrustPacketMetricSnapshot: Codable, Equatable {
    public var receiptCompletenessRate: Double
    public var purposeGroundingRate: Double
    public var consentIntegrityRate: Double
    public var revokeExportReliability: Double
    public var signatureVerificationRate: Double
    public var privacyOverreachBlocks: Int
    public var trustSupportingInteractionRate: Double
    public var receiptCount: Int
    public var updatedAt: String

    public init(receiptCompletenessRate: Double, purposeGroundingRate: Double, consentIntegrityRate: Double, revokeExportReliability: Double, signatureVerificationRate: Double, privacyOverreachBlocks: Int, trustSupportingInteractionRate: Double, receiptCount: Int, updatedAt: String) {
        self.receiptCompletenessRate = receiptCompletenessRate
        self.purposeGroundingRate = purposeGroundingRate
        self.consentIntegrityRate = consentIntegrityRate
        self.revokeExportReliability = revokeExportReliability
        self.signatureVerificationRate = signatureVerificationRate
        self.privacyOverreachBlocks = privacyOverreachBlocks
        self.trustSupportingInteractionRate = trustSupportingInteractionRate
        self.receiptCount = receiptCount
        self.updatedAt = updatedAt
    }
}
