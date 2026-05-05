// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public class TrustedIssuerCell: GeneralCell {
    private struct ClaimSchema: Codable {
        var credentialType: String?
        var subjectPath: String
        var operatorString: String
        var expectedValue: ValueType

        enum CodingKeys: String, CodingKey {
            case credentialType
            case subjectPath
            case operatorString = "operator"
            case expectedValue
        }

        func asObject() -> Object {
            var object: Object = [
                "subjectPath": .string(subjectPath),
                "operator": .string(operatorString),
                "expectedValue": expectedValue
            ]
            if let credentialType, !credentialType.isEmpty {
                object["credentialType"] = .string(credentialType)
            }
            return object
        }
    }

    private struct TrustPolicy: Codable {
        var contextId: String
        var displayName: String
        var claimSchema: ClaimSchema?
        var threshold: Double
        var requireRevocationCheck: Bool
        var requireSubjectBinding: Bool
        var requireIndependentSources: Int
        var maxGraphDepth: Int
        var acceptedIssuerKinds: [String]
        var acceptedDidMethods: [String]
        var timeDecayHalfLifeDays: Double
        var status: String

        func asObject() -> Object {
            var object: Object = [
                "contextId": .string(contextId),
                "displayName": .string(displayName),
                "threshold": .float(threshold),
                "requireRevocationCheck": .bool(requireRevocationCheck),
                "requireSubjectBinding": .bool(requireSubjectBinding),
                "requireIndependentSources": .integer(requireIndependentSources),
                "maxGraphDepth": .integer(maxGraphDepth),
                "acceptedIssuerKinds": .list(acceptedIssuerKinds.map { .string($0) }),
                "acceptedDidMethods": .list(acceptedDidMethods.map { .string($0) }),
                "timeDecayHalfLifeDays": .float(timeDecayHalfLifeDays),
                "status": .string(status)
            ]
            if let claimSchema {
                object["claimSchema"] = .object(claimSchema.asObject())
            }
            return object
        }
    }

    private struct IssuerProfile: Codable {
        var issuerId: String
        var displayName: String
        var issuerKind: String
        var baseWeight: Double
        var contexts: [String]
        var metadata: Object
        var status: String
        var updatedAt: Double

        func asObject() -> Object {
            [
                "issuerId": .string(issuerId),
                "displayName": .string(displayName),
                "issuerKind": .string(issuerKind),
                "baseWeight": .float(baseWeight),
                "contexts": .list(contexts.map { .string($0) }),
                "metadata": .object(metadata),
                "status": .string(status),
                "updatedAt": .float(updatedAt)
            ]
        }
    }

    private struct TrustAttestation: Codable {
        var attestationId: String
        var subjectIssuerId: String
        var contextId: String
        var statement: String
        var weight: Double
        var scope: String
        var audience: String?
        var validFrom: String?
        var validUntil: String?
        var evidenceRef: String?
        var issuer: String
        var proof: Object?
        var status: String
        var createdAt: Double

        func asObject() -> Object {
            var object: Object = [
                "attestationId": .string(attestationId),
                "subjectIssuerId": .string(subjectIssuerId),
                "contextId": .string(contextId),
                "statement": .string(statement),
                "weight": .float(weight),
                "scope": .string(scope),
                "issuer": .string(issuer),
                "status": .string(status),
                "createdAt": .float(createdAt)
            ]
            if let audience, !audience.isEmpty {
                object["audience"] = .string(audience)
            }
            if let validFrom, !validFrom.isEmpty {
                object["validFrom"] = .string(validFrom)
            }
            if let validUntil, !validUntil.isEmpty {
                object["validUntil"] = .string(validUntil)
            }
            if let evidenceRef, !evidenceRef.isEmpty {
                object["evidenceRef"] = .string(evidenceRef)
            }
            if let proof {
                object["proof"] = .object(proof)
            }
            return object
        }
    }

    private struct EvaluationRecord: Codable {
        var evaluationId: String
        var issuerId: String
        var contextId: String
        var requesterId: String?
        var score: Double
        var decision: String
        var threshold: Double
        var reasons: [String]
        var components: Object
        var snapshotHash: String
        var createdAt: String

        func asObject() -> Object {
            var object: Object = [
                "evaluationId": .string(evaluationId),
                "issuerId": .string(issuerId),
                "contextId": .string(contextId),
                "score": .float(score),
                "decision": .string(decision),
                "threshold": .float(threshold),
                "reasons": .list(reasons.map { .string($0) }),
                "components": .object(components),
                "snapshotHash": .string(snapshotHash),
                "createdAt": .string(createdAt)
            ]
            if let requesterId, !requesterId.isEmpty {
                object["requesterId"] = .string(requesterId)
            }
            return object
        }
    }

    private var policiesByContext: [String: TrustPolicy]
    private var issuersById: [String: IssuerProfile]
    private var attestationsById: [String: TrustAttestation]
    private var evaluationCurrentByKey: [String: EvaluationRecord]
    private var evaluationHistory: [EvaluationRecord]

    required init(owner: Identity) async {
        policiesByContext = [:]
        issuersById = [:]
        attestationsById = [:]
        evaluationCurrentByKey = [:]
        evaluationHistory = []
        await super.init(owner: owner)

        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    enum CodingKeys: CodingKey {
        case policiesByContext
        case issuersById
        case attestationsById
        case evaluationCurrentByKey
        case evaluationHistory
        case generalCell
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policiesByContext = (try? container.decode([String: TrustPolicy].self, forKey: .policiesByContext)) ?? [:]
        issuersById = (try? container.decode([String: IssuerProfile].self, forKey: .issuersById)) ?? [:]
        attestationsById = (try? container.decode([String: TrustAttestation].self, forKey: .attestationsById)) ?? [:]
        evaluationCurrentByKey = (try? container.decode([String: EvaluationRecord].self, forKey: .evaluationCurrentByKey)) ?? [:]
        evaluationHistory = (try? container.decode([EvaluationRecord].self, forKey: .evaluationHistory)) ?? []

        try super.init(from: decoder)

        Task {
            await setupPermissions(owner: self.owner)
            await setupKeys(owner: self.owner)
        }
    }

    public override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(policiesByContext, forKey: .policiesByContext)
        try container.encode(issuersById, forKey: .issuersById)
        try container.encode(attestationsById, forKey: .attestationsById)
        try container.encode(evaluationCurrentByKey, forKey: .evaluationCurrentByKey)
        try container.encode(evaluationHistory, forKey: .evaluationHistory)
        try super.encode(to: encoder)
    }

    private func setupPermissions(owner: Identity) async {
        agreementTemplate.addGrant("rw--", for: "trustedIssuers")
    }

    private func setupKeys(owner: Identity) async {
        await addInterceptForGet(requester: owner, key: "trustedIssuers.state") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "trustedIssuers.state", for: requester) else {
                return .string("denied")
            }
            return await self.stateValue(requester: requester)
        }
        await addInterceptForGet(requester: owner, key: "trustedIssuers.policies") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "trustedIssuers.policies", for: requester) else {
                return .string("denied")
            }
            return .list(self.policiesByContext.values.sorted(by: { $0.contextId < $1.contextId }).map { .object($0.asObject()) })
        }
        await addInterceptForGet(requester: owner, key: "trustedIssuers.issuers") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "trustedIssuers.issuers", for: requester) else {
                return .string("denied")
            }
            return .list(self.issuersById.values.sorted(by: { $0.issuerId < $1.issuerId }).map { .object($0.asObject()) })
        }
        await addInterceptForGet(requester: owner, key: "trustedIssuers.attestations") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "trustedIssuers.attestations", for: requester) else {
                return .string("denied")
            }
            return .list(self.attestationsById.values.sorted(by: { $0.attestationId < $1.attestationId }).map { .object($0.asObject()) })
        }
        await addInterceptForGet(requester: owner, key: "trustedIssuers.evaluations.current") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "trustedIssuers.evaluations.current", for: requester) else {
                return .string("denied")
            }
            return .list(self.evaluationCurrentByKey.values.sorted(by: { $0.evaluationId < $1.evaluationId }).map { .object($0.asObject()) })
        }
        await addInterceptForGet(requester: owner, key: "trustedIssuers.evaluations.history") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "trustedIssuers.evaluations.history", for: requester) else {
                return .string("denied")
            }
            return .list(self.evaluationHistory.map { .object($0.asObject()) })
        }

        await addInterceptForSet(requester: owner, key: "trustedIssuers.policy.upsert") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustedIssuers.policy.upsert", for: requester) else {
                return .string("denied")
            }
            return try await self.handlePolicyUpsert(payload: value, requester: requester)
        }
        await addInterceptForSet(requester: owner, key: "trustedIssuers.policy.delete") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustedIssuers.policy.delete", for: requester) else {
                return .string("denied")
            }
            return try await self.handlePolicyDelete(payload: value, requester: requester)
        }
        await addInterceptForSet(requester: owner, key: "trustedIssuers.issuer.upsert") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustedIssuers.issuer.upsert", for: requester) else {
                return .string("denied")
            }
            return try await self.handleIssuerUpsert(payload: value, requester: requester)
        }
        await addInterceptForSet(requester: owner, key: "trustedIssuers.issuer.delete") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustedIssuers.issuer.delete", for: requester) else {
                return .string("denied")
            }
            return try await self.handleIssuerDelete(payload: value, requester: requester)
        }
        await addInterceptForSet(requester: owner, key: "trustedIssuers.attestation.publish") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustedIssuers.attestation.publish", for: requester) else {
                return .string("denied")
            }
            return try await self.handleAttestationPublish(payload: value, requester: requester)
        }
        await addInterceptForSet(requester: owner, key: "trustedIssuers.attestation.revoke") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustedIssuers.attestation.revoke", for: requester) else {
                return .string("denied")
            }
            return try await self.handleAttestationRevoke(payload: value, requester: requester)
        }
        await addInterceptForSet(requester: owner, key: "trustedIssuers.evaluate") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustedIssuers.evaluate", for: requester) else {
                return .string("denied")
            }
            return try await self.handleEvaluate(payload: value, requester: requester)
        }

        await registerContracts(requester: owner)
    }

    private func stateValue(requester: Identity) async -> ValueType {
        let policyList = policiesByContext.values
            .sorted(by: { $0.contextId < $1.contextId })
            .map { ValueType.object($0.asObject()) }
        let issuerList = issuersById.values
            .sorted(by: { $0.issuerId < $1.issuerId })
            .map { ValueType.object($0.asObject()) }
        let attestationList = attestationsById.values
            .sorted(by: { $0.attestationId < $1.attestationId })
            .map { ValueType.object($0.asObject()) }
        let currentEvaluations = evaluationCurrentByKey.values
            .sorted(by: { $0.evaluationId < $1.evaluationId })
            .map { ValueType.object($0.asObject()) }

        return .object([
            "policyCount": .integer(policyList.count),
            "issuerCount": .integer(issuerList.count),
            "attestationCount": .integer(attestationList.count),
            "evaluationCurrentCount": .integer(currentEvaluations.count),
            "evaluationHistoryCount": .integer(evaluationHistory.count),
            "policies": .list(policyList),
            "issuers": .list(issuerList),
            "attestations": .list(attestationList),
            "evaluationsCurrent": .list(currentEvaluations)
        ])
    }

    private func handlePolicyUpsert(payload: ValueType, requester: Identity) async throws -> ValueType {
        guard case .object(let object) = payload else {
            return .string("error: invalid payload for trustedIssuers.policy.upsert")
        }
        guard let contextId = stringValue(object["contextId"]), !contextId.isEmpty else {
            return .string("error: missing contextId")
        }

        let claimSchema: ClaimSchema?
        if case .object(let claimObject)? = object["claimSchema"] {
            guard let subjectPath = stringValue(claimObject["subjectPath"]), !subjectPath.isEmpty else {
                return .string("error: missing claimSchema.subjectPath")
            }
            let op = stringValue(claimObject["operator"]) ?? ">="
            guard let expectedValue = claimObject["expectedValue"] else {
                return .string("error: missing claimSchema.expectedValue")
            }
            claimSchema = ClaimSchema(
                credentialType: stringValue(claimObject["credentialType"]),
                subjectPath: subjectPath,
                operatorString: op,
                expectedValue: expectedValue
            )
        } else {
            claimSchema = nil
        }

        let policy = TrustPolicy(
            contextId: contextId,
            displayName: stringValue(object["displayName"]) ?? contextId,
            claimSchema: claimSchema,
            threshold: clamp(doubleValue(object["threshold"]) ?? 0.7),
            requireRevocationCheck: boolValue(object["requireRevocationCheck"], default: false),
            requireSubjectBinding: boolValue(object["requireSubjectBinding"], default: true),
            requireIndependentSources: max(0, intValue(object["requireIndependentSources"]) ?? 1),
            maxGraphDepth: max(0, intValue(object["maxGraphDepth"]) ?? 2),
            acceptedIssuerKinds: stringList(object["acceptedIssuerKinds"]),
            acceptedDidMethods: stringList(object["acceptedDidMethods"]),
            timeDecayHalfLifeDays: max(1.0, doubleValue(object["timeDecayHalfLifeDays"]) ?? 180.0),
            status: stringValue(object["status"]) ?? "active"
        )
        policiesByContext[contextId] = policy
        return .object(policy.asObject())
    }

    private func handlePolicyDelete(payload: ValueType, requester: Identity) async throws -> ValueType {
        guard case .object(let object) = payload else {
            return .string("error: invalid payload for trustedIssuers.policy.delete")
        }
        guard let contextId = stringValue(object["contextId"]), !contextId.isEmpty else {
            return .string("error: missing contextId")
        }
        let removed = policiesByContext.removeValue(forKey: contextId) != nil
        return .object(["contextId": .string(contextId), "removed": .bool(removed)])
    }

    private func handleIssuerUpsert(payload: ValueType, requester: Identity) async throws -> ValueType {
        guard case .object(let object) = payload else {
            return .string("error: invalid payload for trustedIssuers.issuer.upsert")
        }
        guard let issuerId = stringValue(object["issuerId"]), !issuerId.isEmpty else {
            return .string("error: missing issuerId")
        }
        let profile = IssuerProfile(
            issuerId: issuerId,
            displayName: stringValue(object["displayName"]) ?? issuerId,
            issuerKind: stringValue(object["issuerKind"]) ?? "person",
            baseWeight: clamp(doubleValue(object["baseWeight"]) ?? 0.5),
            contexts: stringList(object["contexts"]),
            metadata: objectValue(object["metadata"]) ?? [:],
            status: stringValue(object["status"]) ?? "active",
            updatedAt: Date().timeIntervalSince1970
        )
        issuersById[issuerId] = profile
        return .object(profile.asObject())
    }

    private func handleIssuerDelete(payload: ValueType, requester: Identity) async throws -> ValueType {
        guard case .object(let object) = payload else {
            return .string("error: invalid payload for trustedIssuers.issuer.delete")
        }
        guard let issuerId = stringValue(object["issuerId"]), !issuerId.isEmpty else {
            return .string("error: missing issuerId")
        }
        let removed = issuersById.removeValue(forKey: issuerId) != nil
        return .object(["issuerId": .string(issuerId), "removed": .bool(removed)])
    }

    private func handleAttestationPublish(payload: ValueType, requester: Identity) async throws -> ValueType {
        guard case .object(let object) = payload else {
            return .string("error: invalid payload for trustedIssuers.attestation.publish")
        }
        guard let subjectIssuerId = stringValue(object["subjectIssuerId"]), !subjectIssuerId.isEmpty else {
            return .string("error: missing subjectIssuerId")
        }
        guard let contextId = stringValue(object["contextId"]), !contextId.isEmpty else {
            return .string("error: missing contextId")
        }
        let attestationId = stringValue(object["attestationId"]) ?? UUID().uuidString
        let attestation = TrustAttestation(
            attestationId: attestationId,
            subjectIssuerId: subjectIssuerId,
            contextId: contextId,
            statement: stringValue(object["statement"]) ?? "trusted_for_context",
            weight: clamp(doubleValue(object["weight"]) ?? 0.3),
            scope: stringValue(object["scope"]) ?? "private",
            audience: stringValue(object["audience"]),
            validFrom: stringValue(object["validFrom"]),
            validUntil: stringValue(object["validUntil"]),
            evidenceRef: stringValue(object["evidenceRef"]),
            issuer: stringValue(object["issuer"]) ?? requester.uuid,
            proof: objectValue(object["proof"]),
            status: "active",
            createdAt: Date().timeIntervalSince1970
        )
        attestationsById[attestationId] = attestation
        return .object(attestation.asObject())
    }

    private func handleAttestationRevoke(payload: ValueType, requester: Identity) async throws -> ValueType {
        guard case .object(let object) = payload else {
            return .string("error: invalid payload for trustedIssuers.attestation.revoke")
        }
        guard let attestationId = stringValue(object["attestationId"]), !attestationId.isEmpty else {
            return .string("error: missing attestationId")
        }
        guard var attestation = attestationsById[attestationId] else {
            return .string("error: attestation not found")
        }
        attestation.status = "revoked"
        attestationsById[attestationId] = attestation
        return .object(attestation.asObject())
    }

    private func handleEvaluate(payload: ValueType, requester: Identity) async throws -> ValueType {
        guard case .object(let object) = payload else {
            return .string("error: invalid payload for trustedIssuers.evaluate")
        }
        guard let contextId = stringValue(object["contextId"]), !contextId.isEmpty else {
            return .string("error: missing contextId")
        }
        guard let issuerId = stringValue(object["issuerId"]), !issuerId.isEmpty else {
            return .string("error: missing issuerId")
        }
        guard let policy = policiesByContext[contextId], policy.status == "active" else {
            return .string("error: no active policy for contextId")
        }

        let evaluationId = stringValue(object["evaluationId"]) ?? UUID().uuidString
        let requesterId = stringValue(object["requesterId"])
        let nowDate = Date()
        let nowIso = iso8601(nowDate)
        var reasons = [String]()
        var components: Object = [
            "baseWeight": .float(0),
            "endorsementContribution": .float(0),
            "freshnessFactor": .float(1),
            "diversityFactor": .float(1),
            "penalties": .float(0)
        ]

        guard let issuerProfile = issuersById[issuerId], issuerProfile.status == "active" else {
            let record = finalizeRecord(
                evaluationId: evaluationId,
                issuerId: issuerId,
                contextId: contextId,
                requesterId: requesterId,
                score: 0.0,
                threshold: policy.threshold,
                decision: "untrusted",
                reasons: ["issuer_not_registered_or_inactive"],
                components: components,
                createdAt: nowIso
            )
            storeEvaluation(record: record)
            return .object(record.asObject())
        }

        if !policy.acceptedIssuerKinds.isEmpty && !policy.acceptedIssuerKinds.contains(issuerProfile.issuerKind) {
            reasons.append("issuer_kind_not_allowed")
        }
        if !policy.acceptedDidMethods.isEmpty, let didMethod = didMethod(of: issuerId), !policy.acceptedDidMethods.contains(didMethod) {
            reasons.append("issuer_did_method_not_allowed")
        }

        guard let vcObject = objectValue(object["candidateVc"]) else {
            reasons.append("missing_candidate_vc")
            let record = finalizeRecord(
                evaluationId: evaluationId,
                issuerId: issuerId,
                contextId: contextId,
                requesterId: requesterId,
                score: 0.0,
                threshold: policy.threshold,
                decision: "untrusted",
                reasons: reasons.sorted(),
                components: components,
                createdAt: nowIso
            )
            storeEvaluation(record: record)
            return .object(record.asObject())
        }

        let vcValidation = try await validateCredential(
            vcObject: vcObject,
            expectedIssuerId: issuerId,
            policy: policy,
            requesterId: requesterId
        )
        reasons.append(contentsOf: vcValidation.reasons)
        if !vcValidation.isValid {
            let record = finalizeRecord(
                evaluationId: evaluationId,
                issuerId: issuerId,
                contextId: contextId,
                requesterId: requesterId,
                score: 0.0,
                threshold: policy.threshold,
                decision: "untrusted",
                reasons: reasons.sorted(),
                components: components,
                createdAt: nowIso
            )
            storeEvaluation(record: record)
            return .object(record.asObject())
        }

        let liveAttestations = attestationsById.values
            .filter { $0.subjectIssuerId == issuerId && $0.contextId == contextId && $0.status == "active" }
            .filter { attestationIsTimeValid($0, now: nowDate) }
            .sorted(by: { lhs, rhs in
                if lhs.issuer == rhs.issuer {
                    return lhs.attestationId < rhs.attestationId
                }
                return lhs.issuer < rhs.issuer
            })

        let uniqueSourceCount = Set(liveAttestations.map { $0.issuer }).count
        if uniqueSourceCount < policy.requireIndependentSources {
            reasons.append("insufficient_independent_sources")
            let record = finalizeRecord(
                evaluationId: evaluationId,
                issuerId: issuerId,
                contextId: contextId,
                requesterId: requesterId,
                score: 0.0,
                threshold: policy.threshold,
                decision: "untrusted",
                reasons: reasons.sorted(),
                components: components,
                createdAt: nowIso
            )
            storeEvaluation(record: record)
            return .object(record.asObject())
        }

        let baseWeight = clamp(issuerProfile.baseWeight)
        let halfLife = max(1.0, policy.timeDecayHalfLifeDays)
        var endorsementSum = 0.0
        var freshnessSamples = [Double]()
        for attestation in liveAttestations {
            let sourceTrust = sourceTrust(
                issuerId: attestation.issuer,
                contextId: contextId,
                maxDepth: policy.maxGraphDepth,
                visited: Set([issuerId])
            )
            let freshness = freshnessFactor(attestation: attestation, now: nowDate, halfLifeDays: halfLife)
            freshnessSamples.append(freshness)
            endorsementSum += clamp(attestation.weight) * sourceTrust * freshness
        }
        let normalizedEndorsement = 1.0 - Foundation.exp(-endorsementSum)
        let diversityFactor: Double
        if policy.requireIndependentSources <= 1 {
            diversityFactor = 1.0
        } else {
            diversityFactor = clamp(Double(uniqueSourceCount) / Double(policy.requireIndependentSources), min: 0.7, max: 1.0)
        }
        let penalties = 0.0
        let rawScore = (0.6 * baseWeight) + (0.4 * normalizedEndorsement)
        let score = clamp((rawScore * diversityFactor) - penalties)
        let decision = score >= policy.threshold ? "trusted" : "untrusted"
        reasons.append(decision == "trusted" ? "trust_threshold_met" : "trust_threshold_not_met")

        components["baseWeight"] = .float(baseWeight)
        components["endorsementContribution"] = .float(normalizedEndorsement)
        components["freshnessFactor"] = .float(freshnessSamples.isEmpty ? 1.0 : (freshnessSamples.reduce(0.0, +) / Double(freshnessSamples.count)))
        components["diversityFactor"] = .float(diversityFactor)
        components["penalties"] = .float(penalties)

        let record = finalizeRecord(
            evaluationId: evaluationId,
            issuerId: issuerId,
            contextId: contextId,
            requesterId: requesterId,
            score: score,
            threshold: policy.threshold,
            decision: decision,
            reasons: reasons.sorted(),
            components: components,
            createdAt: nowIso
        )
        storeEvaluation(record: record)
        return .object(record.asObject())
    }

    private func validateCredential(
        vcObject: Object,
        expectedIssuerId: String,
        policy: TrustPolicy,
        requesterId: String?
    ) async throws -> (isValid: Bool, reasons: [String]) {
        var reasons = [String]()

        if !hasVCContext(vcObject) {
            reasons.append("vc_context_missing")
        }
        if !hasType(vcObject["type"], required: "VerifiableCredential") {
            reasons.append("vc_type_missing")
        }
        guard let vcIssuer = issuerIdFromVC(vcObject) else {
            reasons.append("vc_issuer_missing")
            return (false, reasons)
        }
        if vcIssuer != expectedIssuerId {
            reasons.append("vc_issuer_mismatch")
        }
        if vcObject["credentialSubject"] == nil {
            reasons.append("vc_credential_subject_missing")
        }

        if !credentialTimeWindowValid(vcObject) {
            reasons.append("vc_time_window_invalid")
        }

        if policy.requireRevocationCheck {
            if !revocationStatusAllows(vcObject) {
                reasons.append("revocation_check_failed")
            }
        }

        if let schema = policy.claimSchema {
            if let credentialType = schema.credentialType, !credentialType.isEmpty, !hasType(vcObject["type"], required: credentialType) {
                reasons.append("credential_type_not_allowed")
            }
            guard let leftValue = try? vcObject.get(keypath: schema.subjectPath) else {
                reasons.append("claim_subject_path_missing")
                return (false, reasons)
            }
            if !compareValues(left: leftValue, op: schema.operatorString, right: schema.expectedValue) {
                reasons.append("claim_predicate_not_met")
            }
        }

        if policy.requireSubjectBinding {
            let subjectId = subjectIdFromVC(vcObject)
            if subjectId == nil {
                reasons.append("subject_binding_missing")
            } else if let requesterId, subjectId != requesterId {
                reasons.append("subject_binding_mismatch")
            }
        }

        do {
            let verified = try await cryptographicallyVerify(vcObject: vcObject)
            if verified {
                reasons.append("vc_signature_valid")
            } else {
                reasons.append("vc_signature_invalid")
            }
        } catch {
            reasons.append("vc_crypto_verification_error")
        }

        let hardFailures: Set<String> = [
            "vc_context_missing",
            "vc_type_missing",
            "vc_issuer_missing",
            "vc_issuer_mismatch",
            "vc_credential_subject_missing",
            "vc_time_window_invalid",
            "revocation_check_failed",
            "claim_subject_path_missing",
            "claim_predicate_not_met",
            "subject_binding_missing",
            "subject_binding_mismatch",
            "vc_signature_invalid",
            "vc_crypto_verification_error",
            "credential_type_not_allowed"
        ]
        let failed = reasons.contains(where: { hardFailures.contains($0) })
        return (!failed, reasons)
    }

    private func cryptographicallyVerify(vcObject: Object) async throws -> Bool {
        var normalized = vcObject
        if normalized["issuanceDate"] == nil, let validFrom = normalized["validFrom"] {
            normalized["issuanceDate"] = validFrom
        }
        if normalized["id"] == nil {
            return false
        }
        let claimData = try JSONEncoder().encode(normalized)
        let claim = try JSONDecoder().decode(VCClaim.self, from: claimData)
        return try await claim.verify()
    }

    private func storeEvaluation(record: EvaluationRecord) {
        let key = "\(record.contextId)|\(record.issuerId)"
        evaluationCurrentByKey[key] = record
        evaluationHistory.append(record)
        if evaluationHistory.count > 512 {
            evaluationHistory.removeFirst(evaluationHistory.count - 512)
        }
    }

    private func finalizeRecord(
        evaluationId: String,
        issuerId: String,
        contextId: String,
        requesterId: String?,
        score: Double,
        threshold: Double,
        decision: String,
        reasons: [String],
        components: Object,
        createdAt: String
    ) -> EvaluationRecord {
        let reasonsValue = ValueType.list(reasons.map { .string($0) })
        let canonicalObject: Object = [
            "evaluationId": .string(evaluationId),
            "issuerId": .string(issuerId),
            "contextId": .string(contextId),
            "requesterId": requesterId.map { .string($0) } ?? .null,
            "score": .float(score),
            "threshold": .float(threshold),
            "decision": .string(decision),
            "reasons": reasonsValue,
            "components": .object(components),
            "createdAt": .string(createdAt)
        ]
        let snapshotHash: String = {
            guard let data = try? JSONEncoder().encode(canonicalObject) else { return "" }
            return data.base64EncodedString()
        }()

        return EvaluationRecord(
            evaluationId: evaluationId,
            issuerId: issuerId,
            contextId: contextId,
            requesterId: requesterId,
            score: score,
            decision: decision,
            threshold: threshold,
            reasons: reasons,
            components: components,
            snapshotHash: snapshotHash,
            createdAt: createdAt
        )
    }

    private func sourceTrust(issuerId: String, contextId: String, maxDepth: Int, visited: Set<String>) -> Double {
        guard !visited.contains(issuerId) else { return 0.0 }
        let base = clamp(issuersById[issuerId]?.baseWeight ?? 0.0)
        guard maxDepth > 0 else { return base }

        let now = Date()
        let incoming = attestationsById.values
            .filter { $0.subjectIssuerId == issuerId && $0.contextId == contextId && $0.status == "active" }
            .filter { attestationIsTimeValid($0, now: now) }
            .sorted(by: { lhs, rhs in
                if lhs.issuer == rhs.issuer {
                    return lhs.attestationId < rhs.attestationId
                }
                return lhs.issuer < rhs.issuer
            })
        if incoming.isEmpty {
            return base
        }

        let halfLife = max(1.0, policiesByContext[contextId]?.timeDecayHalfLifeDays ?? 180.0)
        var recursiveSum = 0.0
        for attestation in incoming {
            let sourceDepthTrust = sourceTrust(
                issuerId: attestation.issuer,
                contextId: contextId,
                maxDepth: maxDepth - 1,
                visited: visited.union([issuerId])
            )
            let freshness = freshnessFactor(attestation: attestation, now: now, halfLifeDays: halfLife)
            recursiveSum += clamp(attestation.weight) * sourceDepthTrust * freshness
        }
        let normalized = 1.0 - Foundation.exp(-recursiveSum)
        return clamp((0.6 * base) + (0.4 * normalized))
    }

    private func freshnessFactor(attestation: TrustAttestation, now: Date, halfLifeDays: Double) -> Double {
        let referenceDate: Date
        if let validFrom = attestation.validFrom, let parsed = parseDate(validFrom) {
            referenceDate = parsed
        } else {
            referenceDate = Date(timeIntervalSince1970: attestation.createdAt)
        }
        let ageDays = max(0.0, now.timeIntervalSince(referenceDate) / 86_400.0)
        let lambda = Foundation.log(2.0) / max(1.0, halfLifeDays)
        return clamp(Foundation.exp(-lambda * ageDays))
    }

    private func attestationIsTimeValid(_ attestation: TrustAttestation, now: Date) -> Bool {
        if let validFrom = attestation.validFrom, let date = parseDate(validFrom), now < date {
            return false
        }
        if let validUntil = attestation.validUntil, let date = parseDate(validUntil), now > date {
            return false
        }
        return true
    }

    private func credentialTimeWindowValid(_ vcObject: Object) -> Bool {
        let now = Date()
        let fromString = stringValue(vcObject["validFrom"]) ?? stringValue(vcObject["issuanceDate"])
        if let fromString, let fromDate = parseDate(fromString), now < fromDate {
            return false
        }
        let untilString = stringValue(vcObject["validUntil"]) ?? stringValue(vcObject["expirationDate"])
        if let untilString, let untilDate = parseDate(untilString), now > untilDate {
            return false
        }
        return true
    }

    private func revocationStatusAllows(_ vcObject: Object) -> Bool {
        guard case .object(let statusObject)? = vcObject["credentialStatus"] else {
            return false
        }
        if case .bool(let revoked)? = statusObject["revoked"] {
            return !revoked
        }
        if case .string(let status)? = statusObject["status"] {
            return status.lowercased() != "revoked"
        }
        return true
    }

    private func hasVCContext(_ vcObject: Object) -> Bool {
        guard let contextValue = vcObject["@context"] else { return false }
        switch contextValue {
        case .string(let context):
            return context.contains("credentials")
        case .list(let list):
            for value in list {
                if case .string(let context) = value, context.contains("credentials") {
                    return true
                }
            }
            return false
        default:
            return false
        }
    }

    private func hasType(_ typeValue: ValueType?, required: String) -> Bool {
        guard let typeValue else { return false }
        switch typeValue {
        case .string(let type):
            return type == required
        case .list(let list):
            return list.contains { value in
                if case .string(let type) = value {
                    return type == required
                }
                return false
            }
        default:
            return false
        }
    }

    private func issuerIdFromVC(_ vcObject: Object) -> String? {
        if case .string(let issuer)? = vcObject["issuer"] {
            return issuer
        }
        if case .object(let issuerObject)? = vcObject["issuer"] {
            if case .string(let issuer)? = issuerObject["id"] {
                return issuer
            }
        }
        return nil
    }

    private func subjectIdFromVC(_ vcObject: Object) -> String? {
        guard case .object(let subject)? = vcObject["credentialSubject"] else {
            return nil
        }
        if case .string(let id)? = subject["id"] {
            return id
        }
        return nil
    }

    private func compareValues(left: ValueType, op: String, right: ValueType) -> Bool {
        if let leftNumber = numericValue(left), let rightNumber = numericValue(right) {
            switch op {
            case "=",
                 "==":
                return leftNumber == rightNumber
            case "!=":
                return leftNumber != rightNumber
            case ">":
                return leftNumber > rightNumber
            case "<":
                return leftNumber < rightNumber
            case ">=":
                return leftNumber >= rightNumber
            case "<=":
                return leftNumber <= rightNumber
            default:
                return false
            }
        }

        if case .string(let leftString) = left, case .string(let rightString) = right {
            switch op {
            case "=", "==":
                return leftString == rightString
            case "!=":
                return leftString != rightString
            default:
                return false
            }
        }

        if case .bool(let leftBool) = left, case .bool(let rightBool) = right {
            switch op {
            case "=", "==":
                return leftBool == rightBool
            case "!=":
                return leftBool != rightBool
            default:
                return false
            }
        }
        return false
    }

    private func numericValue(_ value: ValueType) -> Double? {
        switch value {
        case .integer(let integer):
            return Double(integer)
        case .number(let number):
            return Double(number)
        case .float(let float):
            return float
        default:
            return nil
        }
    }

    private func didMethod(of did: String) -> String? {
        guard did.hasPrefix("did:") else { return nil }
        let parts = did.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        return "did:\(parts[1])"
    }

    private func stringValue(_ value: ValueType?) -> String? {
        guard let value else { return nil }
        if case .string(let string) = value {
            return string
        }
        return nil
    }

    private func boolValue(_ value: ValueType?, default defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        if case .bool(let result) = value {
            return result
        }
        return defaultValue
    }

    private func intValue(_ value: ValueType?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .integer(let integer):
            return integer
        case .number(let number):
            return number
        case .float(let float):
            return Int(float)
        default:
            return nil
        }
    }

    private func doubleValue(_ value: ValueType?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .float(let number):
            return number
        case .integer(let number):
            return Double(number)
        case .number(let number):
            return Double(number)
        case .string(let number):
            return Double(number)
        default:
            return nil
        }
    }

    private func registerContracts(requester: Identity) async {
        await registerExploreContract(
            requester: requester,
            key: "trustedIssuers.state",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [Self.stateSchema(), ExploreContract.schema(type: "string")],
                description: "Returns current trusted issuer state or a failure string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the full trusted issuer state with counts and current collections.")
        )

        for (key, itemSchema, summary) in [
            ("trustedIssuers.policies", Self.policySchema(), "Lists trust policies keyed by evaluation context."),
            ("trustedIssuers.issuers", Self.issuerSchema(), "Lists issuer profiles known to the trust registry."),
            ("trustedIssuers.attestations", Self.attestationSchema(), "Lists trust attestations published for issuers."),
            ("trustedIssuers.evaluations.current", Self.evaluationSchema(), "Lists the latest evaluation per issuer/context pair."),
            ("trustedIssuers.evaluations.history", Self.evaluationSchema(), "Lists historical trust evaluation records.")
        ] {
            await registerExploreContract(
                requester: requester,
                key: key,
                method: .get,
                input: .null,
                returns: ExploreContract.oneOfSchema(
                    options: [ExploreContract.listSchema(item: itemSchema), ExploreContract.schema(type: "string")],
                    description: "Returns the requested trusted issuer collection or a failure string."
                ),
                permissions: ["r---"],
                required: false,
                description: .string(summary)
            )
        }

        await registerExploreContract(
            requester: requester,
            key: "trustedIssuers.policy.upsert",
            method: .set,
            input: Self.policyUpsertSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.policySchema(), ExploreContract.schema(type: "string")],
                description: "Returns the stored trust policy or an error string."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Creates or updates a trust policy for a context.")
        )

        await registerExploreContract(
            requester: requester,
            key: "trustedIssuers.policy.delete",
            method: .set,
            input: Self.contextDeleteSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.removalResultSchema(idKey: "contextId"), ExploreContract.schema(type: "string")],
                description: "Returns context removal result or an error string."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Deletes a trust policy for a context.")
        )

        await registerExploreContract(
            requester: requester,
            key: "trustedIssuers.issuer.upsert",
            method: .set,
            input: Self.issuerUpsertSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.issuerSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the stored issuer profile or an error string."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Creates or updates a trusted issuer profile.")
        )

        await registerExploreContract(
            requester: requester,
            key: "trustedIssuers.issuer.delete",
            method: .set,
            input: Self.issuerDeleteSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.removalResultSchema(idKey: "issuerId"), ExploreContract.schema(type: "string")],
                description: "Returns issuer removal result or an error string."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Deletes a trusted issuer profile.")
        )

        await registerExploreContract(
            requester: requester,
            key: "trustedIssuers.attestation.publish",
            method: .set,
            input: Self.attestationPublishSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.attestationSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the stored attestation or an error string."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Publishes a trust attestation for an issuer within a context.")
        )

        await registerExploreContract(
            requester: requester,
            key: "trustedIssuers.attestation.revoke",
            method: .set,
            input: Self.attestationRevokeSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.attestationSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the revoked attestation or an error string."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Revokes a previously published trust attestation.")
        )

        await registerExploreContract(
            requester: requester,
            key: "trustedIssuers.evaluate",
            method: .set,
            input: Self.evaluateSchema(),
            returns: ExploreContract.oneOfSchema(
                options: [Self.evaluationSchema(), ExploreContract.schema(type: "string")],
                description: "Returns the trust evaluation record or an error string."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Evaluates a candidate credential against issuer trust policy and attestations.")
        )
    }

    private static func claimSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "credentialType": ExploreContract.schema(type: "string"),
                "subjectPath": ExploreContract.schema(type: "string"),
                "operator": ExploreContract.schema(type: "string"),
                "expectedValue": ExploreContract.unknownSchema(description: "Expected value compared against the credential subject path.")
            ],
            requiredKeys: ["subjectPath", "operator", "expectedValue"],
            description: "Predicate used to test credential subject claims."
        )
    }

    private static func policySchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "contextId": ExploreContract.schema(type: "string"),
                "displayName": ExploreContract.schema(type: "string"),
                "claimSchema": claimSchema(),
                "threshold": ExploreContract.schema(type: "float"),
                "requireRevocationCheck": ExploreContract.schema(type: "bool"),
                "requireSubjectBinding": ExploreContract.schema(type: "bool"),
                "requireIndependentSources": ExploreContract.schema(type: "integer"),
                "maxGraphDepth": ExploreContract.schema(type: "integer"),
                "acceptedIssuerKinds": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "acceptedDidMethods": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "timeDecayHalfLifeDays": ExploreContract.schema(type: "float"),
                "status": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["contextId", "threshold", "status"],
            description: "Trust policy for a credential evaluation context."
        )
    }

    private static func issuerSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "issuerId": ExploreContract.schema(type: "string"),
                "displayName": ExploreContract.schema(type: "string"),
                "issuerKind": ExploreContract.schema(type: "string"),
                "baseWeight": ExploreContract.schema(type: "float"),
                "contexts": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "metadata": ExploreContract.schema(type: "object"),
                "status": ExploreContract.schema(type: "string"),
                "updatedAt": ExploreContract.schema(type: "float")
            ],
            requiredKeys: ["issuerId", "issuerKind", "baseWeight", "status"],
            description: "Trusted issuer profile."
        )
    }

    private static func attestationSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "attestationId": ExploreContract.schema(type: "string"),
                "subjectIssuerId": ExploreContract.schema(type: "string"),
                "contextId": ExploreContract.schema(type: "string"),
                "statement": ExploreContract.schema(type: "string"),
                "weight": ExploreContract.schema(type: "float"),
                "scope": ExploreContract.schema(type: "string"),
                "audience": ExploreContract.schema(type: "string"),
                "validFrom": ExploreContract.schema(type: "string"),
                "validUntil": ExploreContract.schema(type: "string"),
                "evidenceRef": ExploreContract.schema(type: "string"),
                "issuer": ExploreContract.schema(type: "string"),
                "proof": ExploreContract.schema(type: "object"),
                "status": ExploreContract.schema(type: "string"),
                "createdAt": ExploreContract.schema(type: "float")
            ],
            requiredKeys: ["attestationId", "subjectIssuerId", "contextId", "weight", "issuer", "status"],
            description: "Trust attestation for an issuer within a context."
        )
    }

    private static func evaluationSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "evaluationId": ExploreContract.schema(type: "string"),
                "issuerId": ExploreContract.schema(type: "string"),
                "contextId": ExploreContract.schema(type: "string"),
                "requesterId": ExploreContract.schema(type: "string"),
                "score": ExploreContract.schema(type: "float"),
                "decision": ExploreContract.schema(type: "string"),
                "threshold": ExploreContract.schema(type: "float"),
                "reasons": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "components": ExploreContract.schema(type: "object"),
                "snapshotHash": ExploreContract.schema(type: "string"),
                "createdAt": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["evaluationId", "issuerId", "contextId", "score", "decision", "threshold", "reasons", "createdAt"],
            description: "Trust evaluation record for a credential candidate."
        )
    }

    private static func stateSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "policyCount": ExploreContract.schema(type: "integer"),
                "issuerCount": ExploreContract.schema(type: "integer"),
                "attestationCount": ExploreContract.schema(type: "integer"),
                "evaluationCurrentCount": ExploreContract.schema(type: "integer"),
                "evaluationHistoryCount": ExploreContract.schema(type: "integer"),
                "policies": ExploreContract.listSchema(item: policySchema()),
                "issuers": ExploreContract.listSchema(item: issuerSchema()),
                "attestations": ExploreContract.listSchema(item: attestationSchema()),
                "evaluationsCurrent": ExploreContract.listSchema(item: evaluationSchema())
            ],
            requiredKeys: ["policyCount", "issuerCount", "attestationCount", "evaluationCurrentCount", "evaluationHistoryCount"],
            description: "Current trusted issuer registry state."
        )
    }

    private static func policyUpsertSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "contextId": ExploreContract.schema(type: "string"),
                "displayName": ExploreContract.schema(type: "string"),
                "claimSchema": claimSchema(),
                "threshold": ExploreContract.schema(type: "float"),
                "requireRevocationCheck": ExploreContract.schema(type: "bool"),
                "requireSubjectBinding": ExploreContract.schema(type: "bool"),
                "requireIndependentSources": ExploreContract.schema(type: "integer"),
                "maxGraphDepth": ExploreContract.schema(type: "integer"),
                "acceptedIssuerKinds": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "acceptedDidMethods": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "timeDecayHalfLifeDays": ExploreContract.schema(type: "float"),
                "status": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["contextId"],
            description: "Creates or updates a trust policy."
        )
    }

    private static func issuerUpsertSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "issuerId": ExploreContract.schema(type: "string"),
                "displayName": ExploreContract.schema(type: "string"),
                "issuerKind": ExploreContract.schema(type: "string"),
                "baseWeight": ExploreContract.schema(type: "float"),
                "contexts": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "metadata": ExploreContract.schema(type: "object"),
                "status": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["issuerId"],
            description: "Creates or updates a trusted issuer profile."
        )
    }

    private static func attestationPublishSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "attestationId": ExploreContract.schema(type: "string"),
                "subjectIssuerId": ExploreContract.schema(type: "string"),
                "contextId": ExploreContract.schema(type: "string"),
                "statement": ExploreContract.schema(type: "string"),
                "weight": ExploreContract.schema(type: "float"),
                "scope": ExploreContract.schema(type: "string"),
                "audience": ExploreContract.schema(type: "string"),
                "validFrom": ExploreContract.schema(type: "string"),
                "validUntil": ExploreContract.schema(type: "string"),
                "evidenceRef": ExploreContract.schema(type: "string"),
                "issuer": ExploreContract.schema(type: "string"),
                "proof": ExploreContract.schema(type: "object")
            ],
            requiredKeys: ["subjectIssuerId", "contextId"],
            description: "Publishes an issuer trust attestation."
        )
    }

    private static func attestationRevokeSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "attestationId": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["attestationId"],
            description: "Revokes a trust attestation by identifier."
        )
    }

    private static func contextDeleteSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "contextId": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["contextId"],
            description: "Deletes a trust policy by context identifier."
        )
    }

    private static func issuerDeleteSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "issuerId": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["issuerId"],
            description: "Deletes an issuer profile by issuer identifier."
        )
    }

    private static func removalResultSchema(idKey: String) -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                idKey: ExploreContract.schema(type: "string"),
                "removed": ExploreContract.schema(type: "bool")
            ],
            requiredKeys: [idKey, "removed"],
            description: "Removal result payload."
        )
    }

    private static func evaluateSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "evaluationId": ExploreContract.schema(type: "string"),
                "issuerId": ExploreContract.schema(type: "string"),
                "contextId": ExploreContract.schema(type: "string"),
                "requesterId": ExploreContract.schema(type: "string"),
                "candidateVc": ExploreContract.schema(type: "object")
            ],
            requiredKeys: ["issuerId", "contextId", "candidateVc"],
            description: "Evaluates a candidate credential against trust policy."
        )
    }

    private func stringList(_ value: ValueType?) -> [String] {
        guard let value else { return [] }
        switch value {
        case .string(let item):
            return item.isEmpty ? [] : [item]
        case .list(let values):
            return values.compactMap { listValue in
                if case .string(let item) = listValue, !item.isEmpty {
                    return item
                }
                return nil
            }
        default:
            return []
        }
    }

    private func objectValue(_ value: ValueType?) -> Object? {
        guard let value else { return nil }
        if case .object(let object) = value {
            return object
        }
        return nil
    }

    private func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private func iso8601(_ value: Date) -> String {
        ISO8601DateFormatter().string(from: value)
    }

    private func clamp(_ value: Double, min minimum: Double = 0.0, max maximum: Double = 1.0) -> Double {
        Swift.min(maximum, Swift.max(minimum, value))
    }
}
