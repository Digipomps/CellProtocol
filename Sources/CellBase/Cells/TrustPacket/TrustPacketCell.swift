// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public final class TrustPacketCell: GeneralCell {
    private var draft: TrustPacketDraft
    private var receipts: [TrustPacketReceipt]
    private var confirmedPurposeCandidates: [TrustPacketPurposeCandidate]
    private var disclosures: [TrustPacketDisclosureRecord]
    private var privacyOverreachBlocks: Int

    private enum CodingKeys: String, CodingKey {
        case draft
        case receipts
        case confirmedPurposeCandidates
        case disclosures
        case privacyOverreachBlocks
        case generalCell
    }

    public required init(owner: Identity) async {
        draft = TrustPacketDraft()
        receipts = []
        confirmedPurposeCandidates = []
        disclosures = []
        privacyOverreachBlocks = 0
        await super.init(owner: owner)
        await setupPermissions()
        await setupKeys()
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        draft = try container.decodeIfPresent(TrustPacketDraft.self, forKey: .draft) ?? TrustPacketDraft()
        receipts = try container.decodeIfPresent([TrustPacketReceipt].self, forKey: .receipts) ?? []
        confirmedPurposeCandidates = try container.decodeIfPresent([TrustPacketPurposeCandidate].self, forKey: .confirmedPurposeCandidates) ?? []
        disclosures = try container.decodeIfPresent([TrustPacketDisclosureRecord].self, forKey: .disclosures) ?? []
        privacyOverreachBlocks = try container.decodeIfPresent(Int.self, forKey: .privacyOverreachBlocks) ?? 0
        try super.init(from: decoder)

        Task {
            await setupPermissions()
            await setupKeys()
        }
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(draft, forKey: .draft)
        try container.encode(receipts, forKey: .receipts)
        try container.encode(confirmedPurposeCandidates, forKey: .confirmedPurposeCandidates)
        try container.encode(disclosures, forKey: .disclosures)
        try container.encode(privacyOverreachBlocks, forKey: .privacyOverreachBlocks)
    }

    private func setupPermissions() async {
        agreementTemplate.addGrant("rw--", for: "trustPacket")
    }

    private func setupKeys() async {
        let owner = self.owner

        await registerGet(key: "trustPacket.state", owner: owner, returns: Self.stateSchema(), permissions: ["r---"], description: .string("Returns trust-packet draft, receipts, signatures, purpose candidates, disclosures, and trust-support metrics.")) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "trustPacket", for: requester) else { return .string("denied") }
            return self.statePayload()
        }

        await registerGet(key: "trustPacket.state.draft", owner: owner, returns: Self.draftSchema(), permissions: ["r---"], description: .string("Returns the current trust-packet draft.")) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "trustPacket", for: requester) else { return .string("denied") }
            return Self.encodeValue(self.draft)
        }

        await registerGet(key: "trustPacket.state.receipts", owner: owner, returns: Self.receiptListSchema(), permissions: ["r---"], description: .string("Returns local trust-packet receipts, including origin signatures when present.")) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "trustPacket", for: requester) else { return .string("denied") }
            return Self.encodeValue(self.receipts)
        }

        await registerGet(key: "trustPacket.state.metrics", owner: owner, returns: Self.metricsSchema(), permissions: ["r---"], description: .string("Returns local trust-support metrics. These metrics are not a person score or global reputation.")) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "trustPacket", for: requester) else { return .string("denied") }
            return Self.encodeValue(self.metricSnapshot(updatedAt: Self.iso8601(Date())))
        }

        await registerGet(key: "trustPacket.receipts.current", owner: owner, returns: ExploreContract.oneOfSchema(options: [.null, Self.receiptSchema()]), permissions: ["r---"], description: .string("Returns the latest local trust-packet receipt.")) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "trustPacket", for: requester) else { return .string("denied") }
            guard let receipt = self.receipts.last else { return .null }
            return Self.encodeValue(receipt)
        }

        await registerSet(key: "trustPacket.draft.setMessage", owner: owner, input: ExploreContract.oneOfSchema(options: [ExploreContract.schema(type: "string"), Self.setMessageSchema()]), returns: Self.resultOrErrorSchema(result: Self.draftSchema()), permissions: ["-w--"], flowEffects: [Self.flowEffect("trustPacket.draft.updated")], description: .string("Updates trust-packet draft text. This does not consent, sign, or share.")) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustPacket", for: requester) else { return .string("denied") }
            return self.setMessage(payload, requester: requester)
        }

        await registerSet(key: "trustPacket.draft.setBoundaries", owner: owner, input: Self.boundariesInputSchema(), returns: Self.resultOrErrorSchema(result: Self.draftSchema()), permissions: ["-w--"], flowEffects: [Self.flowEffect("trustPacket.draft.updated")], description: .string("Updates purpose, audience, duration, AI/evidence, and boundary metadata. This does not share.")) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustPacket", for: requester) else { return .string("denied") }
            return self.setBoundaries(payload, requester: requester)
        }

        await registerSet(key: "trustPacket.previewReceipt", owner: owner, input: Self.receiptActionInputSchema(), returns: Self.resultOrErrorSchema(result: Self.receiptSchema()), permissions: ["-w--"], flowEffects: [Self.flowEffect("trustPacket.receipt.previewed")], description: .string("Creates an unsigned preview receipt without consent or data sharing.")) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustPacket", for: requester) else { return .string("denied") }
            return await self.previewReceipt(payload, requester: requester)
        }

        await registerSet(key: "trustPacket.sendBasicTrustPacket", owner: owner, input: Self.receiptActionInputSchema(), returns: Self.resultOrErrorSchema(result: Self.receiptSchema()), permissions: ["-w--"], flowEffects: [Self.flowEffect("trustPacket.sent")], description: .string("Creates a signed receipt and sends a basic trust packet only when required boundaries and explicit consent are present.")) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustPacket", for: requester) else { return .string("denied") }
            return await self.sendBasicTrustPacket(payload, requester: requester)
        }

        await registerSet(key: "trustPacket.verifyReceiptSignature", owner: owner, input: Self.receiptSelectorSchema(), returns: Self.resultOrErrorSchema(result: Self.signatureVerificationSchema()), permissions: ["-w--"], description: .string("Verifies the selected receipt origin signature against the receipt payload and owner identity.")) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustPacket", for: requester) else { return .string("denied") }
            return await self.verifyReceiptSignature(payload)
        }

        await registerSet(key: "trustPacket.exportOwnReceipt", owner: owner, input: Self.receiptSelectorSchema(), returns: Self.resultOrErrorSchema(result: Self.exportManifestSchema()), permissions: ["-w--"], flowEffects: [Self.flowEffect("trustPacket.exported")], description: .string("Exports the owner's receipt and audit manifest, including signature provenance.")) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustPacket", for: requester) else { return .string("denied") }
            return self.exportOwnReceipt(payload, requester: requester)
        }

        await registerSet(key: "trustPacket.revokeGrant", owner: owner, input: Self.revokeInputSchema(), returns: Self.resultOrErrorSchema(result: Self.receiptSchema()), permissions: ["-w--"], flowEffects: [Self.flowEffect("trustPacket.revoked")], description: .string("Marks a local trust-packet receipt as revoked and emits a revocation receipt. External grant enforcement remains resolver-owned.")) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustPacket", for: requester) else { return .string("denied") }
            return await self.revokeGrant(payload, requester: requester)
        }

        await registerSet(key: "trustPacket.shareWithProjectRoom", owner: owner, input: Self.shareInputSchema(), returns: Self.resultOrErrorSchema(result: Self.disclosureSchema()), permissions: ["-w--"], flowEffects: [Self.flowEffect("trustPacket.share.disclosed"), Self.flowEffect("trustPacket.share.blocked")], description: .string("Creates a disclosure record only with explicit consent. Missing consent is treated as a privacy-overreach block.")) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustPacket", for: requester) else { return .string("denied") }
            return self.shareWithProjectRoom(payload, requester: requester)
        }

        await registerSet(key: "trustPacket.extractPurposeCandidates", owner: owner, input: Self.extractPurposeInputSchema(), returns: Self.purposeCandidateResponseSchema(), permissions: ["-w--"], description: .string("Returns side-effect-free purpose/interest candidates from explicit packet content. It never mutates PerspectiveCell.")) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustPacket", for: requester) else { return .string("denied") }
            return self.extractPurposeCandidates(payload)
        }

        await registerSet(key: "trustPacket.confirmPurposeCandidate", owner: owner, input: Self.confirmPurposeCandidateInputSchema(), returns: Self.resultOrErrorSchema(result: Self.purposeCandidateSchema()), permissions: ["-w--"], flowEffects: [Self.flowEffect("trustPacket.purpose.confirmed")], description: .string("Records explicit user confirmation of a purpose candidate. Perspective mutation remains a separate explicit action.")) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustPacket", for: requester) else { return .string("denied") }
            return self.confirmPurposeCandidate(payload, requester: requester)
        }

        await registerSet(key: "trustPacket.evaluateAgainstPerspective", owner: owner, input: Self.evaluatePerspectiveInputSchema(), returns: Self.evaluatePerspectiveResponseSchema(), permissions: ["-w--"], description: .string("Explains direct/via-interest overlap against provided Perspective refs. It never grants access.")) { [weak self] requester, payload in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "trustPacket", for: requester) else { return .string("denied") }
            return self.evaluateAgainstPerspective(payload)
        }
    }
}

private extension TrustPacketCell {
    func setMessage(_ payload: ValueType, requester: Identity) -> ValueType {
        if let message = Self.string(payload) {
            draft.message = message
        } else if let object = ExploreContract.object(from: payload) {
            draft.message = Self.string(object["message"]) ?? draft.message
            draft.title = Self.string(object["title"]) ?? draft.title
            draft.packetType = Self.string(object["packetType"]) ?? draft.packetType
        } else {
            return Self.error("trustPacket.draft.setMessage", "invalid_payload", "Expected string or object payload.")
        }
        draft.updatedAt = Self.timestamp(payload) ?? Self.iso8601(Date())
        emit("trustPacket.draft.updated", "Trust packet draft updated", Self.encodeValue(draft), requester)
        return Self.success("trustPacket.draft.setMessage", Self.encodeValue(draft))
    }

    func setBoundaries(_ payload: ValueType, requester: Identity) -> ValueType {
        guard let object = ExploreContract.object(from: payload) else {
            return Self.error("trustPacket.draft.setBoundaries", "invalid_payload", "Expected object payload.")
        }
        draft.purposeRef = Self.string(object["purposeRef"]) ?? draft.purposeRef
        draft.interestRefs = Self.stringList(object["interestRefs"]) ?? draft.interestRefs
        draft.audience = Self.string(object["audience"]) ?? draft.audience
        draft.recipient = Self.string(object["recipient"]) ?? draft.recipient
        draft.duration = Self.string(object["duration"]) ?? draft.duration
        draft.dataCategories = Self.stringList(object["dataCategories"]) ?? draft.dataCategories
        draft.aiUseSummary = Self.string(object["aiUseSummary"]) ?? draft.aiUseSummary
        draft.evidenceRefs = Self.evidenceRefs(object["evidenceRefs"]) ?? draft.evidenceRefs
        draft.agreementReference = Self.agreementReference(object["agreementReference"]) ?? draft.agreementReference
        if let boundaries = Self.boundaries(object["boundaries"]) {
            draft.boundaries = boundaries
        } else if let audience = draft.audience, let duration = draft.duration {
            draft.boundaries = [TrustPacketBoundary(label: "Delingsgrense", purposeRef: draft.purposeRef, audience: audience, duration: duration, dataCategories: draft.dataCategories)]
        }
        draft.updatedAt = Self.timestamp(payload) ?? Self.iso8601(Date())
        emit("trustPacket.draft.updated", "Trust packet boundaries updated", Self.encodeValue(draft), requester)
        return Self.success("trustPacket.draft.setBoundaries", Self.encodeValue(draft))
    }

    func previewReceipt(_ payload: ValueType, requester: Identity) async -> ValueType {
        let receipt = makeReceipt(status: "preview", explicitConsent: false, createdAt: Self.timestamp(payload) ?? Self.iso8601(Date()))
        receipts.append(receipt)
        emit("trustPacket.receipt.previewed", "Trust packet receipt previewed", Self.encodeValue(receipt), requester)
        return Self.success("trustPacket.previewReceipt", Self.encodeValue(receipt))
    }

    func sendBasicTrustPacket(_ payload: ValueType, requester: Identity) async -> ValueType {
        guard Self.bool(ExploreContract.object(from: payload)?["explicitConsent"]) == true else {
            return Self.error("trustPacket.sendBasicTrustPacket", "explicit_consent_required", "Sending requires explicit user consent.")
        }
        if let missing = missingRequiredReceiptField() {
            return Self.error("trustPacket.sendBasicTrustPacket", "incomplete_trust_packet", "Missing required field: \(missing).")
        }
        let unsigned = makeReceipt(status: "sent", explicitConsent: true, createdAt: Self.timestamp(payload) ?? Self.iso8601(Date()))
        let signed = await signReceipt(unsigned, signedAt: unsigned.createdAt)
        receipts.append(signed)
        emit("trustPacket.sent", "Trust packet sent", Self.encodeValue(signed), requester)
        return Self.success("trustPacket.sendBasicTrustPacket", Self.encodeValue(signed))
    }

    func verifyReceiptSignature(_ payload: ValueType) async -> ValueType {
        guard let receipt = selectedReceipt(payload) else {
            return Self.error("trustPacket.verifyReceiptSignature", "receipt_not_found", "No matching receipt exists.")
        }
        let result = await verificationObject(for: receipt)
        return Self.success("trustPacket.verifyReceiptSignature", .object(result))
    }

    func exportOwnReceipt(_ payload: ValueType, requester: Identity) -> ValueType {
        guard let receipt = selectedReceipt(payload) else {
            return Self.error("trustPacket.exportOwnReceipt", "receipt_not_found", "No matching receipt exists.")
        }
        let receiptValue = Self.encodeValue(receipt)
        let manifest: Object = [
            "recordType": .string("trust_packet_audit_export_manifest"),
            "receiptId": .string(receipt.id),
            "exportedAt": .string(Self.timestamp(payload) ?? Self.iso8601(Date())),
            "recordCount": .integer(1),
            "excludedSecrets": .list([.string("private keys"), .string("raw provider credentials")]),
            "retentionPolicy": .string("receipt-local; downstream deletion remains governed by the target contract"),
            "checksum": .string(Self.sha256Hex(receiptValue)),
            "signatureStatus": .string(receipt.originSignature?.verificationStatus ?? "missing"),
            "receipt": receiptValue
        ]
        let result = ValueType.object(manifest)
        emit("trustPacket.exported", "Trust packet receipt exported", result, requester)
        return Self.success("trustPacket.exportOwnReceipt", result)
    }

    func revokeGrant(_ payload: ValueType, requester: Identity) async -> ValueType {
        guard let index = selectedReceiptIndex(payload) else {
            return Self.error("trustPacket.revokeGrant", "receipt_not_found", "No matching receipt exists.")
        }
        receipts[index].status = "revoked"
        receipts[index].revokedAt = Self.timestamp(payload) ?? Self.iso8601(Date())
        receipts[index].originSignature = nil
        receipts[index] = await signReceipt(receipts[index], signedAt: receipts[index].revokedAt ?? Self.iso8601(Date()))
        var object = (try? Self.objectValue(receipts[index])) ?? [:]
        object["resolverEnforcement"] = .string("external_contract_owner_must_revoke_corresponding_capability")
        let result = ValueType.object(object)
        emit("trustPacket.revoked", "Trust packet receipt revoked", result, requester)
        return Self.success("trustPacket.revokeGrant", result)
    }

    func shareWithProjectRoom(_ payload: ValueType, requester: Identity) -> ValueType {
        let object = ExploreContract.object(from: payload) ?? [:]
        guard Self.bool(object["explicitConsent"]) == true else {
            privacyOverreachBlocks += 1
            let error = Self.error("trustPacket.shareWithProjectRoom", "explicit_consent_required", "Project-room sharing requires explicit consent.")
            emit("trustPacket.share.blocked", "Trust packet sharing blocked", error, requester)
            return error
        }
        guard let receipt = selectedReceipt(payload) ?? receipts.last, receipt.status != "revoked" else {
            return Self.error("trustPacket.shareWithProjectRoom", "receipt_not_shareable", "A non-revoked receipt is required before sharing.")
        }
        let disclosure = TrustPacketDisclosureRecord(
            id: "trust-packet-disclosure-\(disclosures.count + 1)",
            receiptId: receipt.id,
            recipient: Self.string(object["projectRoom"]) ?? Self.string(object["recipient"]) ?? "project-room",
            purposeRef: receipt.purposeRef,
            dataCategories: receipt.dataCategories,
            sharedAt: Self.string(object["sharedAt"]) ?? Self.iso8601(Date())
        )
        disclosures.append(disclosure)
        let result = Self.encodeValue(disclosure)
        emit("trustPacket.share.disclosed", "Trust packet shared with project room", result, requester)
        return Self.success("trustPacket.shareWithProjectRoom", result)
    }

    func extractPurposeCandidates(_ payload: ValueType) -> ValueType {
        let object = ExploreContract.object(from: payload) ?? [:]
        let text = [Self.string(object["title"]), Self.string(object["message"]), Self.string(object["audience"]), Self.string(object["aiUseSummary"]), draft.title, draft.message, draft.audience, draft.aiUseSummary]
            .compactMap { $0 }
            .joined(separator: " ")
        if Self.containsNegativeIntent(text) {
            return .object(["status": .string("ok"), "mutatesPerspective": .bool(false), "blockedByNegativeIntent": .bool(true), "candidates": .list([]), "message": .string("Purpose extraction stopped by explicit negative intent.")])
        }
        let candidates = Self.candidates(from: text, draft: draft, createdAt: Self.timestamp(payload) ?? Self.iso8601(Date()))
        return .object(["status": .string("ok"), "mutatesPerspective": .bool(false), "blockedByNegativeIntent": .bool(false), "candidates": Self.encodeValue(candidates), "message": .string("Candidates require explicit confirmation before PerspectiveCell.addPurpose.")])
    }

    func confirmPurposeCandidate(_ payload: ValueType, requester: Identity) -> ValueType {
        guard let object = ExploreContract.object(from: payload),
              Self.bool(object["approved"]) == true,
              let label = Self.string(object["label"]),
              let purposeRef = Self.string(object["purposeRef"]) else {
            return Self.error("trustPacket.confirmPurposeCandidate", "not_approved", "Candidate confirmation requires approved=true, label, and purposeRef.")
        }
        let candidate = TrustPacketPurposeCandidate(
            id: Self.string(object["id"]) ?? "trust-purpose-candidate-\(confirmedPurposeCandidates.count + 1)",
            label: label,
            purposeRef: purposeRef,
            purposeDescription: Self.string(object["purposeDescription"]) ?? "User-confirmed trust packet purpose.",
            interestRefs: Self.stringList(object["interestRefs"]) ?? [],
            goalRefs: Self.stringList(object["goalRefs"]) ?? [],
            supportingText: Self.string(object["supportingText"]) ?? draft.message,
            evidenceRefs: Self.stringList(object["evidenceRefs"]) ?? [],
            confidence: Self.double(object["confidence"]) ?? 1.0,
            status: "confirmed",
            createdAt: Self.string(object["createdAt"]),
            confirmedAt: Self.string(object["confirmedAt"]) ?? Self.iso8601(Date())
        )
        confirmedPurposeCandidates.append(candidate)
        let result = Self.encodeValue(candidate)
        emit("trustPacket.purpose.confirmed", "Trust packet purpose candidate confirmed", result, requester)
        return Self.success("trustPacket.confirmPurposeCandidate", .object(["candidate": result, "perspectiveMutation": .string("caller_must_explicitly_call_perspective.addPurpose")]))
    }

    func evaluateAgainstPerspective(_ payload: ValueType) -> ValueType {
        let object = ExploreContract.object(from: payload) ?? [:]
        let activePurposeRefs = Set(Self.stringList(object["activePurposeRefs"]) ?? [])
        let activeInterestRefs = Set(Self.stringList(object["activeInterestRefs"]) ?? [])
        let purposeRef = Self.string(object["purposeRef"]) ?? draft.purposeRef
        let interestRefs = Set(Self.stringList(object["interestRefs"]) ?? draft.interestRefs)
        let directHits: [ValueType] = (purposeRef != nil && activePurposeRefs.contains(purposeRef!)) ? [.object(["purposeRef": .string(purposeRef!), "route": .string("direct"), "score": .float(1.0), "explanation": .string("The packet purpose matches an explicitly provided active Perspective purpose.")])] : []
        let viaInterestHits = activeInterestRefs.intersection(interestRefs).sorted().map { ValueType.object(["interestRef": .string($0), "route": .string("viaInterest"), "score": .float(0.7), "explanation": .string("The packet and Perspective share an explicit interest ref.")]) }
        return .object(["status": .string("ok"), "accessGranted": .bool(false), "mutatesPerspective": .bool(false), "directPurposeHits": .list(directHits), "viaInterestHits": .list(viaInterestHits), "count": .integer(directHits.count + viaInterestHits.count), "explanation": .string("Matching explains overlap only. Contracts and resolver policy still own access.")])
    }
}

private extension TrustPacketCell {
    func makeReceipt(status: String, explicitConsent: Bool, createdAt: String) -> TrustPacketReceipt {
        TrustPacketReceipt(
            id: "trust-packet-receipt-\(receipts.count + 1)",
            packetId: draft.id,
            packetType: draft.packetType,
            status: status,
            title: draft.title,
            summary: draft.message,
            purposeRef: draft.purposeRef,
            interestRefs: draft.interestRefs,
            audience: draft.audience ?? "unspecified",
            recipient: draft.recipient,
            duration: draft.duration ?? "unspecified",
            dataCategories: draft.dataCategories,
            aiUseSummary: draft.aiUseSummary,
            boundaries: draft.boundaries,
            evidenceRefs: draft.evidenceRefs,
            agreementReference: draft.agreementReference,
            explicitConsent: explicitConsent,
            revokeAvailable: draft.boundaries.allSatisfy(\.canRevoke),
            exportAvailable: draft.boundaries.allSatisfy(\.canExport),
            createdAt: createdAt
        )
    }

    func signReceipt(_ receipt: TrustPacketReceipt, signedAt: String) async -> TrustPacketReceipt {
        var unsigned = receipt
        unsigned.originSignature = nil
        guard let data = try? Self.canonicalData(unsigned),
              let signature = try? await owner.sign(data: data) else {
            var pending = receipt
            pending.originSignature = TrustPacketOriginSignature(signerIdentityId: owner.uuid, signerDisplayName: owner.displayName, signingKeyFingerprint: owner.signingPublicKeyFingerprint, payloadHash: Self.sha256Hex(data: (try? Self.canonicalData(unsigned)) ?? Data()), signature: "", signedAt: signedAt, verificationStatus: "pending", verificationMessage: "Owner identity did not produce a signature.")
            return pending
        }
        let verified = await owner.verify(signature: signature, for: data)
        var signed = receipt
        signed.originSignature = TrustPacketOriginSignature(
            signerIdentityId: owner.uuid,
            signerDisplayName: owner.displayName,
            signingKeyFingerprint: owner.signingPublicKeyFingerprint,
            payloadHash: Self.sha256Hex(data: data),
            signature: signature.base64EncodedString(),
            signedAt: signedAt,
            verificationStatus: verified ? "verified" : "failed",
            verificationMessage: verified ? "Signature verified against the origin identity." : "Signature could not be verified against the origin identity."
        )
        return signed
    }

    func verificationObject(for receipt: TrustPacketReceipt) async -> Object {
        guard let originSignature = receipt.originSignature,
              let signature = Data(base64Encoded: originSignature.signature) else {
            return ["status": .string("missing"), "message": .string("Receipt has no origin signature.")]
        }
        var unsigned = receipt
        unsigned.originSignature = nil
        guard let data = try? Self.canonicalData(unsigned) else {
            return ["status": .string("failed"), "message": .string("Could not canonicalize receipt payload.")]
        }
        let payloadHash = Self.sha256Hex(data: data)
        let hashMatches = payloadHash == originSignature.payloadHash
        let signatureValid = await owner.verify(signature: signature, for: data)
        return [
            "status": .string(hashMatches && signatureValid ? "verified" : "failed"),
            "signerIdentityId": .string(originSignature.signerIdentityId),
            "payloadHash": .string(payloadHash),
            "declaredPayloadHash": .string(originSignature.payloadHash),
            "hashMatches": .bool(hashMatches),
            "signatureValid": .bool(signatureValid),
            "message": .string(hashMatches && signatureValid ? "Origin signature is valid." : "Origin signature did not verify.")
        ]
    }

    func missingRequiredReceiptField() -> String? {
        if draft.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "message" }
        if draft.purposeRef?.isEmpty != false { return "purposeRef" }
        if draft.audience?.isEmpty != false { return "audience" }
        if draft.duration?.isEmpty != false { return "duration" }
        if draft.boundaries.isEmpty { return "boundaries" }
        return nil
    }

    func selectedReceipt(_ payload: ValueType) -> TrustPacketReceipt? {
        guard let object = ExploreContract.object(from: payload),
              let receiptId = Self.string(object["receiptId"]) else {
            return receipts.last
        }
        return receipts.first { $0.id == receiptId }
    }

    func selectedReceiptIndex(_ payload: ValueType) -> Int? {
        guard let object = ExploreContract.object(from: payload),
              let receiptId = Self.string(object["receiptId"]) else {
            return receipts.indices.last
        }
        return receipts.firstIndex { $0.id == receiptId }
    }

    func metricSnapshot(updatedAt: String) -> TrustPacketMetricSnapshot {
        let denominator = Double(max(receipts.count, 1))
        let complete = Double(receipts.filter(Self.isReceiptComplete).count) / denominator
        let grounded = Double(receipts.filter { $0.purposeRef?.isEmpty == false }.count) / denominator
        let sent = receipts.filter { $0.status == "sent" || $0.status == "revoked" }
        let consent = sent.isEmpty ? 1.0 : Double(sent.filter(\.explicitConsent).count) / Double(sent.count)
        let revokeExport = Double(receipts.filter { $0.revokeAvailable && $0.exportAvailable }.count) / denominator
        let signatures = Double(receipts.filter { $0.originSignature?.verificationStatus == "verified" }.count) / denominator
        let trustSupporting = (complete + grounded + consent + revokeExport + signatures) / 5.0
        return TrustPacketMetricSnapshot(receiptCompletenessRate: complete, purposeGroundingRate: grounded, consentIntegrityRate: consent, revokeExportReliability: revokeExport, signatureVerificationRate: signatures, privacyOverreachBlocks: privacyOverreachBlocks, trustSupportingInteractionRate: trustSupporting, receiptCount: receipts.count, updatedAt: updatedAt)
    }

    static func isReceiptComplete(_ receipt: TrustPacketReceipt) -> Bool {
        !receipt.summary.isEmpty && receipt.purposeRef?.isEmpty == false && !receipt.audience.isEmpty && !receipt.duration.isEmpty && receipt.revokeAvailable && receipt.exportAvailable && !receipt.boundaries.isEmpty && receipt.originSignature?.verificationStatus == "verified"
    }

    func statePayload() -> ValueType {
        .object([
            "status": .string("ok"),
            "draft": Self.encodeValue(draft),
            "receipts": Self.encodeValue(receipts),
            "confirmedPurposeCandidates": Self.encodeValue(confirmedPurposeCandidates),
            "disclosures": Self.encodeValue(disclosures),
            "metrics": Self.encodeValue(metricSnapshot(updatedAt: Self.iso8601(Date()))),
            "guardrails": .list([.string("no global reputation"), .string("no person score"), .string("no hidden profiling"), .string("explicit confirmation before Perspective mutation"), .string("signed origin receipts for sent/revoked packets")])
        ])
    }

    func emit(_ topic: String, _ title: String, _ payload: ValueType, _ requester: Identity) {
        var flowContent: FlowElementValueType = .string("")
        if case let .object(object) = payload {
            flowContent = .object(object)
        } else if case let .list(values) = payload {
            flowContent = .list(values)
        } else if let stringValue = Self.string(payload) {
            flowContent = .string(stringValue)
        }
        var flowElement = FlowElement(title: title, content: flowContent, properties: FlowElement.Properties(type: .event, contentType: .object))
        flowElement.topic = topic
        flowElement.origin = uuid
        pushFlowElement(flowElement, requester: requester)
    }
}

private extension TrustPacketCell {
    static func candidates(from text: String, draft: TrustPacketDraft, createdAt: String) -> [TrustPacketPurposeCandidate] {
        let normalized = text.lowercased()
        if normalized.contains("ai") || normalized.contains("modell") || normalized.contains("provider") {
            return [TrustPacketPurposeCandidate(id: "trust-purpose-ai-transparency", label: "AI- og datatransparens", purposeRef: "purpose://trust.ai-and-data-transparency", purposeDescription: "Gjor AI-bruk, input scope, lagring, kost/kvote og menneskelig godkjenning synlig.", interestRefs: ["interest://ai-transparency", "interest://privacy", "interest://auditability"], goalRefs: ["goal.trust.packet-complete", "goal.trust.scope-understood"], supportingText: text, evidenceRefs: draft.evidenceRefs.map(\.id), confidence: 0.82, createdAt: createdAt)]
        }
        if normalized.contains("intro") || normalized.contains("mote") || normalized.contains("meeting") || normalized.contains("event") {
            return [TrustPacketPurposeCandidate(id: "trust-purpose-contextual-intro", label: "Kontekstuell intro", purposeRef: "purpose://trust.contextual-intro", purposeDescription: "Stotter gjensidig intro med eksplisitt formal og uten sosial score.", interestRefs: ["interest://relationship-context", "interest://consent", "interest://collaboration"], goalRefs: ["goal.trust.purpose-confirmed", "goal.trust.no-overreach"], supportingText: text, evidenceRefs: draft.evidenceRefs.map(\.id), confidence: 0.78, createdAt: createdAt)]
        }
        return [TrustPacketPurposeCandidate(id: "trust-purpose-understandable-boundaries", label: "Forstaelige delingsgrenser", purposeRef: "purpose://trust.understandable-boundaries", purposeDescription: "Hjelper bruker og mottaker a forsta hva som deles, hvorfor, med hvem og hvor lenge.", interestRefs: ["interest://trust", "interest://privacy", "interest://auditability"], goalRefs: ["goal.trust.packet-complete", "goal.trust.scope-understood"], supportingText: text, evidenceRefs: draft.evidenceRefs.map(\.id), confidence: 0.64, createdAt: createdAt)]
    }

    static func containsNegativeIntent(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("ikke lagre") || normalized.contains("ikke del") || normalized.contains("ikke opprett") || normalized.contains("kun engangsdeling") || normalized.contains("one-time only")
    }

    static func timestamp(_ value: ValueType) -> String? {
        guard let object = ExploreContract.object(from: value) else { return nil }
        return string(object["createdAt"]) ?? string(object["updatedAt"]) ?? string(object["at"])
    }

    static func string(_ value: ValueType?) -> String? {
        switch value {
        case let .string(value)?: return value
        case let .integer(value)?: return String(value)
        case let .number(value)?: return String(value)
        case let .float(value)?: return String(value)
        case let .bool(value)?: return value ? "true" : "false"
        default: return nil
        }
    }

    static func bool(_ value: ValueType?) -> Bool? {
        switch value {
        case let .bool(value)?: return value
        case let .string(value)?:
            if ["true", "yes", "ja", "1"].contains(value.lowercased()) { return true }
            if ["false", "no", "nei", "0"].contains(value.lowercased()) { return false }
            return nil
        default: return nil
        }
    }

    static func double(_ value: ValueType?) -> Double? {
        switch value {
        case let .float(value)?: return value
        case let .integer(value)?: return Double(value)
        case let .number(value)?: return Double(value)
        case let .string(value)?: return Double(value)
        default: return nil
        }
    }

    static func stringList(_ value: ValueType?) -> [String]? {
        switch value {
        case let .list(values)?: return values.compactMap { string($0) }
        case let .string(value)?: return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        default: return nil
        }
    }

    static func boundaries(_ value: ValueType?) -> [TrustPacketBoundary]? {
        guard case let .list(values)? = value else { return nil }
        return values.compactMap { value in
            guard let object = ExploreContract.object(from: value), let label = string(object["label"]), let audience = string(object["audience"]), let duration = string(object["duration"]) else { return nil }
            return TrustPacketBoundary(label: label, purposeRef: string(object["purposeRef"]), audience: audience, duration: duration, dataCategories: stringList(object["dataCategories"]) ?? [], canRevoke: bool(object["canRevoke"]) ?? true, canExport: bool(object["canExport"]) ?? true)
        }
    }

    static func evidenceRefs(_ value: ValueType?) -> [TrustPacketEvidenceRef]? {
        guard case let .list(values)? = value else { return nil }
        return values.enumerated().compactMap { index, value in
            guard let object = ExploreContract.object(from: value) else { return nil }
            return TrustPacketEvidenceRef(id: string(object["id"]) ?? "evidence-\(index + 1)", type: string(object["type"]) ?? "declared", issuer: string(object["issuer"]), claim: string(object["claim"]), policyRef: string(object["policyRef"]), status: string(object["status"]) ?? "declared", evidenceRef: string(object["evidenceRef"]), verifiedAt: string(object["verifiedAt"]), summary: string(object["summary"]))
        }
    }

    static func agreementReference(_ value: ValueType?) -> AgreementReference? {
        guard let object = ExploreContract.object(from: value), let id = string(object["id"]), let label = string(object["label"]) else { return nil }
        return AgreementReference(id: id, label: label, counterparty: string(object["counterparty"]), purpose: string(object["purpose"]), dataPointer: string(object["dataPointer"]), savedAt: ExploreContract.int(from: object["savedAt"]), savedAtText: string(object["savedAtText"]), recordKeypath: string(object["recordKeypath"]), sourceEntityKeypath: string(object["sourceEntityKeypath"]))
    }

    static func encodeValue<T: Encodable>(_ value: T) -> ValueType {
        guard let data = try? JSONEncoder().encode(value), let encoded = try? JSONDecoder().decode(ValueType.self, from: data) else { return .null }
        return encoded
    }

    static func objectValue<T: Encodable>(_ value: T) throws -> Object {
        guard case let .object(object) = encodeValue(value) else { return [:] }
        return object
    }

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func sha256Hex(data: Data) -> String {
        FlowHasher.sha256Hex(data)
    }

    static func sha256Hex(_ value: ValueType) -> String {
        sha256Hex(data: (try? canonicalData(value)) ?? Data())
    }

    static func success(_ operation: String, _ result: ValueType) -> ValueType {
        .object(["status": .string("ok"), "operation": .string(operation), "result": result])
    }

    static func error(_ operation: String, _ code: String, _ message: String) -> ValueType {
        .object(["status": .string("error"), "operation": .string(operation), "code": .string(code), "message": .string(message)])
    }

    static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private extension TrustPacketCell {
    static func flowEffect(_ topic: String) -> ValueType { ExploreContract.flowEffect(trigger: .set, topic: topic, contentType: "object", minimumCount: 1) }
    static func stateSchema() -> ValueType { ExploreContract.objectSchema(properties: ["status": ExploreContract.schema(type: "string"), "draft": draftSchema(), "receipts": receiptListSchema(), "confirmedPurposeCandidates": ExploreContract.listSchema(item: purposeCandidateSchema()), "disclosures": ExploreContract.listSchema(item: disclosureSchema()), "metrics": metricsSchema(), "guardrails": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))], requiredKeys: ["status", "draft", "receipts", "metrics"]) }
    static func draftSchema() -> ValueType { ExploreContract.objectSchema(properties: ["id": ExploreContract.schema(type: "string"), "packetType": ExploreContract.schema(type: "string"), "title": ExploreContract.schema(type: "string"), "message": ExploreContract.schema(type: "string"), "purposeRef": ExploreContract.schema(type: "string"), "interestRefs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "audience": ExploreContract.schema(type: "string"), "recipient": ExploreContract.schema(type: "string"), "duration": ExploreContract.schema(type: "string"), "dataCategories": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "aiUseSummary": ExploreContract.schema(type: "string"), "boundaries": ExploreContract.listSchema(item: boundarySchema()), "evidenceRefs": ExploreContract.listSchema(item: evidenceRefSchema()), "agreementReference": agreementReferenceSchema(), "updatedAt": ExploreContract.schema(type: "string")], requiredKeys: ["id", "packetType", "title", "message", "interestRefs", "dataCategories", "boundaries", "evidenceRefs"]) }
    static func boundarySchema() -> ValueType { ExploreContract.objectSchema(properties: ["label": ExploreContract.schema(type: "string"), "purposeRef": ExploreContract.schema(type: "string"), "audience": ExploreContract.schema(type: "string"), "duration": ExploreContract.schema(type: "string"), "dataCategories": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "canRevoke": ExploreContract.schema(type: "bool"), "canExport": ExploreContract.schema(type: "bool")], requiredKeys: ["label", "audience", "duration", "dataCategories", "canRevoke", "canExport"]) }
    static func evidenceRefSchema() -> ValueType { ExploreContract.objectSchema(properties: ["id": ExploreContract.schema(type: "string"), "type": ExploreContract.schema(type: "string"), "issuer": ExploreContract.schema(type: "string"), "claim": ExploreContract.schema(type: "string"), "policyRef": ExploreContract.schema(type: "string"), "status": ExploreContract.schema(type: "string"), "evidenceRef": ExploreContract.schema(type: "string"), "verifiedAt": ExploreContract.schema(type: "string"), "summary": ExploreContract.schema(type: "string")], requiredKeys: ["id", "type", "status"]) }
    static func agreementReferenceSchema() -> ValueType { ExploreContract.objectSchema(properties: ["id": ExploreContract.schema(type: "string"), "label": ExploreContract.schema(type: "string"), "counterparty": ExploreContract.schema(type: "string"), "purpose": ExploreContract.schema(type: "string"), "dataPointer": ExploreContract.schema(type: "string"), "savedAt": ExploreContract.schema(type: "integer"), "savedAtText": ExploreContract.schema(type: "string"), "recordKeypath": ExploreContract.schema(type: "string"), "sourceEntityKeypath": ExploreContract.schema(type: "string")], requiredKeys: ["id", "label"]) }
    static func originSignatureSchema() -> ValueType { ExploreContract.objectSchema(properties: ["signerIdentityId": ExploreContract.schema(type: "string"), "signerDisplayName": ExploreContract.schema(type: "string"), "signingKeyFingerprint": ExploreContract.schema(type: "string"), "algorithm": ExploreContract.schema(type: "string"), "payloadHash": ExploreContract.schema(type: "string"), "signature": ExploreContract.schema(type: "string"), "signedAt": ExploreContract.schema(type: "string"), "verificationStatus": ExploreContract.schema(type: "string"), "verificationMessage": ExploreContract.schema(type: "string")], requiredKeys: ["signerIdentityId", "algorithm", "payloadHash", "signature", "signedAt", "verificationStatus", "verificationMessage"]) }
    static func receiptSchema() -> ValueType { ExploreContract.objectSchema(properties: ["id": ExploreContract.schema(type: "string"), "packetId": ExploreContract.schema(type: "string"), "packetType": ExploreContract.schema(type: "string"), "status": ExploreContract.schema(type: "string"), "title": ExploreContract.schema(type: "string"), "summary": ExploreContract.schema(type: "string"), "purposeRef": ExploreContract.schema(type: "string"), "interestRefs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "audience": ExploreContract.schema(type: "string"), "recipient": ExploreContract.schema(type: "string"), "duration": ExploreContract.schema(type: "string"), "dataCategories": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "aiUseSummary": ExploreContract.schema(type: "string"), "boundaries": ExploreContract.listSchema(item: boundarySchema()), "evidenceRefs": ExploreContract.listSchema(item: evidenceRefSchema()), "agreementReference": agreementReferenceSchema(), "explicitConsent": ExploreContract.schema(type: "bool"), "revokeAvailable": ExploreContract.schema(type: "bool"), "exportAvailable": ExploreContract.schema(type: "bool"), "createdAt": ExploreContract.schema(type: "string"), "revokedAt": ExploreContract.schema(type: "string"), "originSignature": originSignatureSchema()], requiredKeys: ["id", "packetId", "packetType", "status", "title", "summary", "interestRefs", "audience", "duration", "dataCategories", "boundaries", "evidenceRefs", "explicitConsent", "revokeAvailable", "exportAvailable", "createdAt"]) }
    static func receiptListSchema() -> ValueType { ExploreContract.listSchema(item: receiptSchema()) }
    static func purposeCandidateSchema() -> ValueType { ExploreContract.objectSchema(properties: ["id": ExploreContract.schema(type: "string"), "label": ExploreContract.schema(type: "string"), "purposeRef": ExploreContract.schema(type: "string"), "purposeDescription": ExploreContract.schema(type: "string"), "interestRefs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "goalRefs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "supportingText": ExploreContract.schema(type: "string"), "evidenceRefs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "confidence": ExploreContract.schema(type: "float"), "requiresApproval": ExploreContract.schema(type: "bool"), "reviewRequired": ExploreContract.schema(type: "bool"), "mutatesPerspective": ExploreContract.schema(type: "bool"), "status": ExploreContract.schema(type: "string"), "createdAt": ExploreContract.schema(type: "string"), "confirmedAt": ExploreContract.schema(type: "string")], requiredKeys: ["id", "label", "purposeRef", "purposeDescription", "interestRefs", "goalRefs", "supportingText", "confidence", "requiresApproval", "reviewRequired", "mutatesPerspective", "status"]) }
    static func disclosureSchema() -> ValueType { ExploreContract.objectSchema(properties: ["id": ExploreContract.schema(type: "string"), "receiptId": ExploreContract.schema(type: "string"), "recipient": ExploreContract.schema(type: "string"), "purposeRef": ExploreContract.schema(type: "string"), "dataCategories": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "sharedAt": ExploreContract.schema(type: "string"), "status": ExploreContract.schema(type: "string")], requiredKeys: ["id", "receiptId", "recipient", "dataCategories", "sharedAt", "status"]) }
    static func metricsSchema() -> ValueType { ExploreContract.objectSchema(properties: ["receiptCompletenessRate": ExploreContract.schema(type: "float"), "purposeGroundingRate": ExploreContract.schema(type: "float"), "consentIntegrityRate": ExploreContract.schema(type: "float"), "revokeExportReliability": ExploreContract.schema(type: "float"), "signatureVerificationRate": ExploreContract.schema(type: "float"), "privacyOverreachBlocks": ExploreContract.schema(type: "integer"), "trustSupportingInteractionRate": ExploreContract.schema(type: "float"), "receiptCount": ExploreContract.schema(type: "integer"), "updatedAt": ExploreContract.schema(type: "string")], requiredKeys: ["receiptCompletenessRate", "purposeGroundingRate", "consentIntegrityRate", "revokeExportReliability", "signatureVerificationRate", "privacyOverreachBlocks", "trustSupportingInteractionRate", "receiptCount", "updatedAt"]) }
    static func setMessageSchema() -> ValueType { ExploreContract.objectSchema(properties: ["message": ExploreContract.schema(type: "string"), "title": ExploreContract.schema(type: "string"), "packetType": ExploreContract.schema(type: "string"), "updatedAt": ExploreContract.schema(type: "string")], requiredKeys: ["message"]) }
    static func boundariesInputSchema() -> ValueType { ExploreContract.objectSchema(properties: ["purposeRef": ExploreContract.schema(type: "string"), "interestRefs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "audience": ExploreContract.schema(type: "string"), "recipient": ExploreContract.schema(type: "string"), "duration": ExploreContract.schema(type: "string"), "dataCategories": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "aiUseSummary": ExploreContract.schema(type: "string"), "boundaries": ExploreContract.listSchema(item: boundarySchema()), "evidenceRefs": ExploreContract.listSchema(item: evidenceRefSchema()), "agreementReference": agreementReferenceSchema(), "updatedAt": ExploreContract.schema(type: "string")], requiredKeys: ["purposeRef", "audience", "duration"]) }
    static func receiptActionInputSchema() -> ValueType { ExploreContract.objectSchema(properties: ["explicitConsent": ExploreContract.schema(type: "bool"), "createdAt": ExploreContract.schema(type: "string")]) }
    static func receiptSelectorSchema() -> ValueType { ExploreContract.objectSchema(properties: ["receiptId": ExploreContract.schema(type: "string"), "createdAt": ExploreContract.schema(type: "string")]) }
    static func revokeInputSchema() -> ValueType { ExploreContract.objectSchema(properties: ["receiptId": ExploreContract.schema(type: "string"), "reason": ExploreContract.schema(type: "string"), "createdAt": ExploreContract.schema(type: "string")]) }
    static func shareInputSchema() -> ValueType { ExploreContract.objectSchema(properties: ["receiptId": ExploreContract.schema(type: "string"), "projectRoom": ExploreContract.schema(type: "string"), "recipient": ExploreContract.schema(type: "string"), "explicitConsent": ExploreContract.schema(type: "bool"), "sharedAt": ExploreContract.schema(type: "string")], requiredKeys: ["explicitConsent"]) }
    static func extractPurposeInputSchema() -> ValueType { ExploreContract.objectSchema(properties: ["title": ExploreContract.schema(type: "string"), "message": ExploreContract.schema(type: "string"), "audience": ExploreContract.schema(type: "string"), "aiUseSummary": ExploreContract.schema(type: "string"), "createdAt": ExploreContract.schema(type: "string")]) }
    static func purposeCandidateResponseSchema() -> ValueType { ExploreContract.objectSchema(properties: ["status": ExploreContract.schema(type: "string"), "mutatesPerspective": ExploreContract.schema(type: "bool"), "blockedByNegativeIntent": ExploreContract.schema(type: "bool"), "candidates": ExploreContract.listSchema(item: purposeCandidateSchema()), "message": ExploreContract.schema(type: "string")], requiredKeys: ["status", "mutatesPerspective", "blockedByNegativeIntent", "candidates", "message"]) }
    static func confirmPurposeCandidateInputSchema() -> ValueType { ExploreContract.objectSchema(properties: ["id": ExploreContract.schema(type: "string"), "label": ExploreContract.schema(type: "string"), "purposeRef": ExploreContract.schema(type: "string"), "purposeDescription": ExploreContract.schema(type: "string"), "interestRefs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "goalRefs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "supportingText": ExploreContract.schema(type: "string"), "evidenceRefs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "confidence": ExploreContract.schema(type: "float"), "approved": ExploreContract.schema(type: "bool"), "createdAt": ExploreContract.schema(type: "string"), "confirmedAt": ExploreContract.schema(type: "string")], requiredKeys: ["label", "purposeRef", "approved"]) }
    static func evaluatePerspectiveInputSchema() -> ValueType { ExploreContract.objectSchema(properties: ["purposeRef": ExploreContract.schema(type: "string"), "interestRefs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "activePurposeRefs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "activeInterestRefs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))]) }
    static func evaluatePerspectiveResponseSchema() -> ValueType { ExploreContract.objectSchema(properties: ["status": ExploreContract.schema(type: "string"), "accessGranted": ExploreContract.schema(type: "bool"), "mutatesPerspective": ExploreContract.schema(type: "bool"), "directPurposeHits": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")), "viaInterestHits": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")), "count": ExploreContract.schema(type: "integer"), "explanation": ExploreContract.schema(type: "string")], requiredKeys: ["status", "accessGranted", "mutatesPerspective", "directPurposeHits", "viaInterestHits", "count", "explanation"]) }
    static func signatureVerificationSchema() -> ValueType { ExploreContract.objectSchema(properties: ["status": ExploreContract.schema(type: "string"), "signerIdentityId": ExploreContract.schema(type: "string"), "payloadHash": ExploreContract.schema(type: "string"), "declaredPayloadHash": ExploreContract.schema(type: "string"), "hashMatches": ExploreContract.schema(type: "bool"), "signatureValid": ExploreContract.schema(type: "bool"), "message": ExploreContract.schema(type: "string")], requiredKeys: ["status", "message"]) }
    static func exportManifestSchema() -> ValueType { ExploreContract.objectSchema(properties: ["recordType": ExploreContract.schema(type: "string"), "receiptId": ExploreContract.schema(type: "string"), "exportedAt": ExploreContract.schema(type: "string"), "recordCount": ExploreContract.schema(type: "integer"), "excludedSecrets": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "retentionPolicy": ExploreContract.schema(type: "string"), "checksum": ExploreContract.schema(type: "string"), "signatureStatus": ExploreContract.schema(type: "string"), "receipt": receiptSchema()], requiredKeys: ["recordType", "receiptId", "exportedAt", "recordCount", "excludedSecrets", "retentionPolicy", "checksum", "signatureStatus", "receipt"]) }
    static func resultOrErrorSchema(result: ValueType) -> ValueType { ExploreContract.oneOfSchema(options: [ExploreContract.objectSchema(properties: ["status": ExploreContract.schema(type: "string"), "operation": ExploreContract.schema(type: "string"), "result": result], requiredKeys: ["status", "operation", "result"]), ExploreContract.objectSchema(properties: ["status": ExploreContract.schema(type: "string"), "operation": ExploreContract.schema(type: "string"), "code": ExploreContract.schema(type: "string"), "message": ExploreContract.schema(type: "string")], requiredKeys: ["status", "operation", "code", "message"])]) }
}
