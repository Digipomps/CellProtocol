import Foundation

/// Private, resolver-authorized meeting policy. No capture route is registered
/// until a host installs a real recorder; a rendered Start button is not authority.
public final class MeetingSessionCell: GeneralCell, @unchecked Sendable {
    private let stateLock = NSLock()
    private var session: MeetingConsentSession?
    private var restored: MeetingConsentSnapshot?
    private var journal: MeetingEncryptedJournal?
    private var signedConsents: [MeetingSignedConsent] = []
    private var startOperations: Set<UUID> = []
    private var coordinator: MeetingCaptureCoordinator?
    private var delivery: MeetingDeliveryService?
    private var presence: [MeetingPrincipal: (MeetingPlanReference, Date)] = [:]
    /// The explicit owner invitation carries an ordinary Cell-bound admission
    /// contract. It never grants recording consent.
    public func makeAdmission(for recipient: Identity) async throws -> Contract {
        let signer = owner.publicIdentitySnapshot(); signer.identityVault = owner.identityVault
        let snapshot = try await Contract.ownerSignedSnapshot(agreement: agreementTemplate, signer: signer, domain: identityDomain)
        snapshot.agreement.signatories = [signer.publicIdentitySnapshot(), recipient.publicIdentitySnapshot()]
        return try await Contract.signed(agreement: snapshot.agreement, issuer: signer,
            subject: recipient.publicIdentitySnapshot(), domain: identityDomain, targetCellUUID: uuid)
    }
    public override func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? {
        if keypath == "meeting.join" {
            let bytes = try JSONEncoder().encode(value)
            guard bytes.count <= 65536 else { throw MeetingSessionError.invalidPlan }
            let request = try JSONDecoder().decode(MeetingJoinRequest.self, from: bytes)
            try request.verify(owner: owner, requester: requester, cellID: uuid)
            // Standard admission verifies the owner contract and fresh subject
            // key proof through the original bridge. No host vault is attached.
            let admitted = await acceptExternallySignedAgreement(request.admission, for: requester)
            guard admitted == .signed else { throw MeetingSessionError.forbidden }
            try request.verify(owner: owner, requester: requester, cellID: uuid)
            let principal = try Self.principal(requester)
            try mutate {
                guard let session else { throw MeetingSessionError.unavailable }
                let state = try session.snapshot(now: Date())
                if !state.plan.participants.contains(principal) {
                    let p = state.plan
                    let next = MeetingPlan(purpose: p.purpose, participants: p.participants + [principal], recorder: p.recorder,
                        locale: p.locale, processingRoute: p.processingRoute, rawAudioLifetime: p.rawAudioLifetime,
                        deliveryLifetime: p.deliveryLifetime, recipientLifetime: p.recipientLifetime, consentLifetime: p.consentLifetime)
                    try session.replacePlan(next, by: Self.principal(owner), operationID: request.invitation.nonce, expected: state.reference, now: Date())
                }
            }
            if let capture = locked({ coordinator }) { await capture.checkAdmission() }
            changed(requester)
            return .object(["status": .string("ok"), "recordingConsent": .bool(false)])
        }
        if keypath == "agreement.accept" {
            let bytes = try JSONEncoder().encode(value)
            guard bytes.count <= 65536 else { throw MeetingSessionError.invalidPlan }
            let contract = try JSONDecoder().decode(Contract.self, from: bytes)
            // Reconnect only an existing roster member; an old admission cannot
            // put a removed person back into the recording plan.
            guard try durableSnapshot().plan.participants.contains(Self.principal(requester)),
                  await acceptExternallySignedAgreement(contract, for: requester) == .signed else { throw MeetingSessionError.forbidden }
            return .object(["status": .string("ok")])
        }
        return try await super.set(keypath: keypath, value: value, requester: requester) ?? .null
    }
    public func purgeDelivery() async throws {
        guard let service = locked({ delivery }) else { throw MeetingSessionError.unavailable }
        try await service.purgeExpired()
    }
    public func hasTranscript(for segmentID: UUID) async throws -> Bool {
        guard let service = locked({ delivery }) else { throw MeetingSessionError.unavailable }
        return try await service.containsPacket(segmentID.uuidString + "-v1")
    }
    public func installDelivery(store: any MeetingDurableStore, recorder: Identity, provider: any IdentityKeyRoleProviderProtocol) throws {
        try locked {
            guard journal != nil, let snapshot = try session?.snapshot(now: Date()),
                  snapshot.plan.recorder == (try Self.principal(recorder)), delivery == nil else { throw MeetingSessionError.forbidden }
            delivery = MeetingDeliveryService(identity: recorder, provider: provider, store: store, authorizeRelease: { [weak self] id in
                guard let self else { throw MeetingSessionError.unavailable }
                let state = try self.durableSnapshot()
                guard state.segments.contains(where: { $0.id == id && $0.stoppedAt != nil }),
                      !(state.processingRevokedSegments ?? []).contains(id) else { throw MeetingSessionError.forbidden }
            })
        }
    }
    /// Capture completion hands off only stopped, non-revoked segments. The
    /// original signed recipient set is read from the durable meeting authority.
    public func completeSegment(_ id: UUID, transcript: String, incomplete: Bool, uncertainties: [String]) async throws -> MeetingDeliveryPacket {
        let (segment, evidence, service) = try locked { () throws -> (MeetingSegment, [MeetingSignedConsent], MeetingDeliveryService) in
            guard journal != nil, let session, let delivery else { throw MeetingSessionError.unavailable }
            let state = try session.snapshot(now: Date())
            guard let segment = state.segments.first(where: { $0.id == id }), segment.stoppedAt != nil,
                  !(state.processingRevokedSegments ?? []).contains(id) else { throw MeetingSessionError.forbidden }
            try commit()
            return (segment, signedConsents.filter { $0.reference == segment.reference }, delivery)
        }
        let package = MeetingTranscriptPackage(cellID: uuid, segment: segment, consents: evidence,
            transcript: transcript, incomplete: incomplete, uncertainties: uncertainties, createdAt: segment.stoppedAt!)
        return try await service.enqueue(package)
    }


    /// Local bootstrap only, after the original owner vault is available.
    /// No resolver endpoint accepts a caller-selected store or key.
    public func installDurability(store: any MeetingDurableStore, key: Data) throws {
        try locked {
            guard journal == nil, coordinator == nil else { throw MeetingSessionError.operationConflict }
            let ownerPrincipal = try Self.principal(owner)
            let log = try MeetingEncryptedJournal(store: store, key: key, cellID: uuid, owner: ownerPrincipal)
            if let record = log.latest {
                session = try record.snapshot.map { try MeetingConsentSession(owner: ownerPrincipal, restoring: $0) }
                signedConsents = record.consents
                startOperations = Set(record.startOperations)
                initialOperations = record.initialOperations
            }
            journal = log
            try commit()
        }
    }
    public func installCaptureDevice(_ device: any MeetingCaptureDevice) throws {
        try locked {
            guard journal != nil, let session, coordinator == nil else { throw MeetingSessionError.unavailable }
            coordinator = MeetingCaptureCoordinator(session: session, device: device, beforeCapture: { [weak self] permit in
                guard let self else { throw MeetingSessionError.unavailable }
                try self.locked {
                    guard let snapshot = try self.session?.snapshot(now: Date()), snapshot.recording == permit else { throw MeetingSessionError.staleEpoch }
                    guard snapshot.plan.participants.allSatisfy({ member in
                        guard let seen = self.presence[member] else { return false }
                        let age = Date().timeIntervalSince(seen.1)
                        return seen.0 == permit.plan && age >= 0 && age < 1.5
                    }) else { throw MeetingSessionError.consentIncomplete }
                    for proof in self.signedConsents where proof.reference == permit.plan {
                        try proof.verify(cellID: self.uuid, reference: permit.plan, plan: snapshot.plan, at: Date())
                    }
                    try self.commit()
                }
            })
        }
    }
    public func durableSnapshot() throws -> MeetingConsentSnapshot {
        try locked { guard journal != nil, let session else { throw MeetingSessionError.unavailable }; return try session.snapshot(now: Date()) }
    }
    public func consentEvidence(for segment: MeetingSegment) throws -> [MeetingSignedConsent] {
        try locked {
            guard journal != nil else { throw MeetingSessionError.unavailable }
            return signedConsents.filter { $0.reference == segment.reference }
        }
    }
    private func commit() throws {
        guard let journal else { return }
        do { try journal.commit(snapshot: session?.snapshot(now: Date()), consents: signedConsents, startOperations: startOperations.sorted { $0.uuidString < $1.uuidString }, initialOperations: initialOperations) }
        catch {
            // Persistence failure must never leave positive recording authority.
            try? session?.stop(by: Self.principal(owner), now: Date(), reason: "storageFailed")
            throw error
        }
    }
    private func mutate<T>(_ body: () throws -> T) throws -> T {
        try locked {
            do { let result = try body(); try commit(); return result }
            catch { try? commit(); throw error }
        }
    }
    private var durabilityLabel: String { locked { journal == nil ? "runtime-only" : "committed-readback" } }

    private var initialOperations: [UUID: MeetingOperationRecord] = [:]
    private enum CodingKeys: String, CodingKey { case meetingSnapshot, meetingInitialOperations }

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        try? await ensureRuntimeReady()
    }
    public required init(from decoder: Decoder) throws {
        restored = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(MeetingConsentSnapshot.self, forKey: .meetingSnapshot)
        initialOperations = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(
            [UUID: MeetingOperationRecord].self, forKey: .meetingInitialOperations) ?? [:]
        try super.init(from: decoder)
    }
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        let (snapshot, initialRecords) = try locked { (try session?.snapshot(now: Date()) ?? restored, initialOperations) }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(snapshot, forKey: .meetingSnapshot)
        try container.encode(initialRecords, forKey: .meetingInitialOperations)
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock(); defer { stateLock.unlock() }; return try body()
    }
    private static func principal(_ identity: Identity) throws -> MeetingPrincipal {
        guard let fingerprint = identity.signingPublicKeyFingerprint else { throw MeetingSessionError.forbidden }
        return MeetingPrincipal(id: identity.uuid, signingKeyFingerprint: fingerprint)
    }
    public override func installCellRuntimeBindingsForAccess() async throws {
        // A private meeting uses explicit owner admission plus subject-key proof.
        // GeneralCell's placeholder identity-grant condition cannot be evaluated
        // against a stripped public subject, and its default grants are not this
        // cell's policy. Declare only this cell's actual participant operations.
        agreementTemplate = Agreement(owner: owner)
        agreementTemplate.name = "Private meeting participant admission"
        agreementTemplate.conditions = []
        agreementTemplate.grants = []
        agreementAdmissionPolicy = .ownerApprovalRequired
        for key in ["meeting.join", "agreement.accept"] {
            await registerExploreContract(requester: owner, key: key, method: .set,
                input: ExploreContract.schema(type: "object"), returns: Self.resultSchema,
                permissions: [], required: false,
                description: .string("Explicit participant admission using an owner-signed cell-bound contract and fresh subject-key proof. meeting.join also requires a live signed invitation; neither operation grants recording consent."))
        }
        let ownerPrincipal = try Self.principal(owner)
        try locked {
            if let saved = restored {
                session = try MeetingConsentSession(owner: ownerPrincipal, restoring: saved)
                restored = nil
            }
        }
        // Public operation grants must match resolver preflight keypaths. An
        // umbrella "meeting" grant is not an alias for consent.approve/state.
        for key in ["state", "cellConfiguration", "delivery.pending", "delivery.index", "plan.current"] { agreementTemplate.ensureGrant("r---", for: key) }
        for key in ["consent.approve", "consent.decline", "consent.revoke", "segment.revoke", "recording.stop", "recording.start", "consent.submit", "delivery.receipt", "delivery.fetch", "presence.confirm", "recording.renew"] {
            agreementTemplate.ensureGrant("-w--", for: key)
        }
        await registerGet(key: "state", owner: owner, returns: Self.stateSchema,
            permissions: ["r---"], description: .string("Private meeting view; requester must be an authorized participant. No audio or secrets.")) { [weak self] requester in
            guard let self, await self.validateAccess("r---", at: "state", for: requester) else { return .string("denied") }
            do { return try self.readState(requester) } catch { return Self.failure(error) }
        }
        await registerGet(key: "cellConfiguration", owner: owner, returns: ExploreContract.schema(type: "object"),
            permissions: ["r---"], description: .string("Shared portable meeting Skeleton for web and Binding; no platform-specific copy.")) { [weak self] requester in
            guard let self, await self.validateAccess("r---", at: "cellConfiguration", for: requester) else { return .string("denied") }
            do {
                _ = try self.readState(requester)
                return MeetingSurfaceConfiguration.encode(try MeetingSurfaceConfiguration.make(endpoint: "cell:///" + self.uuid))
            } catch { return Self.failure(error) }
        }
        await registerGet(key: "plan.current", owner: owner, returns: ExploreContract.schema(type: "object"),
            permissions: ["r---"], description: .string("Exact current plan for local participant signature; only an authenticated current member may read.")) { [weak self] requester in
            guard let self, await self.validateAccess("r---", at: "plan.current", for: requester) else { return .string("denied") }
            do {
                return try self.locked {
                    let principal = try Self.principal(requester)
                    guard let state = try self.session?.snapshot(now: Date()), state.plan.participants.contains(principal) else { throw MeetingSessionError.forbidden }
                    return .object(["plan": MeetingSurfaceConfiguration.encode(state.plan), "reference": MeetingSurfaceConfiguration.encode(state.reference)])
                }
            } catch { return Self.failure(error) }
        }
        await registerSet(key: "plan.propose", owner: owner, input: Self.planInputSchema, returns: Self.resultSchema,
            permissions: ["-w--"], description: .string("Owner proposes a complete plan. Existing plan changes require expected reference, stop capture and invalidate every consent.")) { [weak self] requester, value in
            guard let self, await self.validateAccess("-w--", at: "plan.propose", for: requester) else { return .string("denied") }
            do {
                guard requester.referencesSameSigningIdentity(as: self.owner) else { throw MeetingSessionError.forbidden }
                let input = try JSONDecoder().decode(PlanInput.self, from: JSONEncoder().encode(value))
                // A rejected proposal can still stop capture and invalidate consent.
                // Notify subscribers on both success and failure after this point.
                defer { self.changed(requester) }
                try self.mutate {
                    let principal = try Self.principal(requester)
                    guard !self.startOperations.contains(input.operationID) else { throw MeetingSessionError.operationConflict }
                    let digest = try MeetingConsentSession.commandDigest("plan.propose", by: principal, expected: input.expected, plan: input.plan)
                    if let previous = self.initialOperations[input.operationID] {
                        guard previous.digest == digest else { throw MeetingSessionError.operationConflict }
                        throw previous.failure ?? MeetingSessionError.unavailable
                    }
                    if let session = self.session {
                        try session.replacePlan(input.plan, by: principal, operationID: input.operationID, expected: input.expected, now: Date())
                    } else {
                        do {
                            guard input.expected == nil else { throw MeetingSessionError.stalePlan }
                            self.session = try MeetingConsentSession(owner: principal, plan: input.plan, initialOperationID: input.operationID)
                        } catch let error as MeetingSessionError {
                            self.initialOperations[input.operationID] = MeetingOperationRecord(digest: digest, failure: error)
                            throw error
                        }
                    }
                }
                if let capture = self.locked({ self.coordinator }) { await capture.checkAdmission() }
                return .object(["status": .string("ok"), "durability": .string(self.durabilityLabel)])
            } catch { return Self.failure(error) }
        }
        for action in ["consent.approve", "consent.decline", "consent.revoke", "recording.stop"] {
            await registerSet(key: action, owner: owner, input: Self.actionSchema, returns: Self.resultSchema,
                permissions: ["-w--"], description: .string("\(action) for the authenticated requester and exact current plan; no proxy approval.")) { [weak self] requester, value in
                guard let self, await self.validateAccess("-w--", at: action, for: requester) else { return .string("denied") }
                do {
                    let input = try JSONDecoder().decode(MeetingActionInput.self, from: JSONEncoder().encode(value))
                    let ref = input.expected
                    let principal = try Self.principal(requester)
                    var evidence: MeetingSignedConsent?
                    if action == "consent.approve", self.locked({ self.journal != nil }) {
                        let plan = try self.locked { () throws -> MeetingPlan in
                            guard let snapshot = try self.session?.snapshot(now: Date()), snapshot.reference == ref else { throw MeetingSessionError.stalePlan }
                            return snapshot.plan
                        }
                        if let original = self.locked({ self.signedConsents.first { $0.operationID == input.operationID } }) {
                            guard original.identity.referencesSameSigningIdentity(as: requester), original.reference == ref else { throw MeetingSessionError.operationConflict }
                            evidence = original
                        } else {
                            evidence = try await MeetingSignedConsent.approve(cellID: self.uuid, operationID: input.operationID,
                                reference: ref, plan: plan, identity: requester)
                        }
                    }
                    defer { self.changed(requester) }
                    try self.mutate {
                        guard let session = self.session else { throw MeetingSessionError.unavailable }
                        guard self.initialOperations[input.operationID] == nil, !self.startOperations.contains(input.operationID) else { throw MeetingSessionError.operationConflict }
                        // Revoke and decline deliberately have the same policy
                        // semantics and idempotency namespace.
                        switch action {
                        case "consent.approve":
                            if let evidence { try evidence.verify(cellID: self.uuid, reference: ref, plan: session.snapshot(now: Date()).plan, at: Date()) }
                            try session.approve(by: principal, operationID: input.operationID, expected: ref, now: Date(), signedExpiry: evidence?.expiresAt)
                            self.presence[principal] = (ref, Date())
                            if let evidence, !self.signedConsents.contains(where: { $0.reference == evidence.reference && (try? $0.principal) == (try? evidence.principal) }) { self.signedConsents.append(evidence) }
                        case "consent.decline", "consent.revoke": try session.decline(by: principal, operationID: input.operationID, expected: ref, now: Date())
                        default: try session.stop(by: principal, operationID: input.operationID, expected: ref, now: Date())
                        }
                    }
                    if let capture = self.locked({ self.coordinator }) { await capture.checkAdmission() }
                return .object(["status": .string("ok"), "durability": .string(self.durabilityLabel)])
                } catch { return Self.failure(error) }
            }
        }
        await registerSet(key: "presence.confirm", owner: owner, input: Self.referenceSchema, returns: Self.resultSchema,
            permissions: ["-w--"], description: .string("Fresh connection presence for this authenticated participant only, bound to the exact current plan.")) { [weak self] requester, value in
            guard let self, await self.validateAccess("-w--", at: "presence.confirm", for: requester) else { return .string("denied") }
            do {
                let ref = try JSONDecoder().decode(MeetingPlanReference.self, from: JSONEncoder().encode(value))
                let principal = try Self.principal(requester)
                try self.locked {
                    guard let state = try self.session?.snapshot(now: Date()), state.reference == ref,
                          state.plan.participants.contains(principal) else { throw MeetingSessionError.stalePlan }
                    self.presence[principal] = (ref, Date())
                }
                return .object(["status": .string("ok")])
            } catch { return Self.failure(error) }
        }
        await registerSet(key: "recording.renew", owner: owner, input: ExploreContract.schema(type: "object"), returns: Self.resultSchema,
            permissions: ["-w--"], description: .string("Renew at most three seconds using fresh individually authenticated connection presence; the recorder cannot supply the participant list.")) { [weak self] requester, value in
            guard let self, await self.validateAccess("-w--", at: "recording.renew", for: requester) else { return .string("denied") }
            do {
                let permit = try JSONDecoder().decode(MeetingRecordingPermit.self, from: JSONEncoder().encode(value))
                let principal = try Self.principal(requester)
                let renewed = try self.locked { () throws -> MeetingRecordingPermit in
                    guard self.journal != nil, self.coordinator != nil, let session = self.session else { throw MeetingSessionError.unavailable }
                    let now = Date()
                    let present = Set(self.presence.compactMap { member, seen in
                        seen.0 == permit.plan && now.timeIntervalSince(seen.1) >= 0 && now.timeIntervalSince(seen.1) < 1.5 ? member : nil
                    })
                    return try session.renew(permit, by: principal, present: present, now: now)
                }
                return MeetingSurfaceConfiguration.encode(renewed)
            } catch { return Self.failure(error) }
        }
        await registerGet(key: "delivery.index", owner: owner, returns: ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
            permissions: ["r---"], description: .string("Bounded list of encrypted packages for this exact recipient.")) { [weak self] requester in
            guard let self, await self.validateAccess("r---", at: "delivery.index", for: requester) else { return .string("denied") }
            do {
                guard let service = self.locked({ self.delivery }) else { throw MeetingSessionError.unavailable }
                let packets = try await service.pending(for: Self.principal(requester))
                let index = try packets.prefix(16).map { packet -> MeetingDeliveryIndex in
                    let bytes = try MeetingEvidence.bytes(packet)
                    return MeetingDeliveryIndex(id: packet.id, byteCount: bytes.count, packetHash: FlowHasher.sha256Hex(bytes))
                }
                return MeetingSurfaceConfiguration.encode(index)
            } catch { return Self.failure(error) }
        }
        await registerSet(key: "delivery.fetch", owner: owner, input: ExploreContract.schema(type: "object"), returns: ExploreContract.schema(type: "object"),
            permissions: ["-w--"], description: .string("Read a bounded encrypted package part; rechecks recipient, expiry and revocation on every request.")) { [weak self] requester, value in
            guard let self, await self.validateAccess("-w--", at: "delivery.fetch", for: requester) else { return .string("denied") }
            do {
                guard let service = self.locked({ self.delivery }) else { throw MeetingSessionError.unavailable }
                let request = try JSONDecoder().decode(MeetingDeliveryFetch.self, from: JSONEncoder().encode(value))
                let pending = try await service.pending(for: Self.principal(requester))
                guard let packet = pending.first(where: { $0.id == request.id }) else { throw MeetingSessionError.forbidden }
                let bytes = try MeetingEvidence.bytes(packet)
                guard request.offset >= 0, request.offset < bytes.count else { throw MeetingSessionError.wrongPackage }
                let end = min(bytes.count, request.offset + MeetingDeliveryChunk.maximumBytes)
                return MeetingSurfaceConfiguration.encode(MeetingDeliveryChunk(id: packet.id, offset: request.offset,
                    byteCount: bytes.count, packetHash: FlowHasher.sha256Hex(bytes), bytes: bytes.subdata(in: request.offset..<end)))
            } catch { return Self.failure(error) }
        }
        await registerGet(key: "delivery.pending", owner: owner, returns: ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
            permissions: ["r---"], description: .string("Encrypted packets for this original authenticated participant only; a later join grants no old segment.")) { [weak self] requester in
            guard let self, await self.validateAccess("r---", at: "delivery.pending", for: requester) else { return .string("denied") }
            do {
                guard let service = self.locked({ self.delivery }) else { throw MeetingSessionError.unavailable }
                let principal = try Self.principal(requester)
                let packets = try await service.pending(for: principal)
                var page: [MeetingDeliveryPacket] = []; var size = 2
                for packet in packets {
                    let bytes = try MeetingEvidence.bytes(packet).count + 1
                    guard bytes <= MeetingFileStore.maximumBytes - size else { break }
                    page.append(packet); size += bytes
                    if page.count == 16 { break }
                }
                return MeetingSurfaceConfiguration.encode(page)
            } catch { return Self.failure(error) }
        }
        await registerSet(key: "delivery.receipt", owner: owner, input: ExploreContract.schema(type: "object"), returns: Self.resultSchema,
            permissions: ["-w--"], description: .string("Accept an exact package/recipient signed durable-storage receipt. Transport success is not receipt.")) { [weak self] requester, value in
            guard let self, await self.validateAccess("-w--", at: "delivery.receipt", for: requester) else { return .string("denied") }
            do {
                guard let service = self.locked({ self.delivery }) else { throw MeetingSessionError.unavailable }
                let receipt = try JSONDecoder().decode(MeetingStoredReceipt.self, from: JSONEncoder().encode(value))
                try await service.acknowledge(receipt, authenticatedRecipient: requester)
                self.changed(requester)
                return .object(["status": .string("ok"), "durability": .string("committed-readback")])
            } catch { return Self.failure(error) }
        }
        await registerSet(key: "consent.submit", owner: owner, input: ExploreContract.schema(type: "object"), returns: Self.resultSchema,
            permissions: ["-w--"], description: .string("Participant-signed exact-plan approval; authenticated requester must match the signature.")) { [weak self] requester, value in
            guard let self, await self.validateAccess("-w--", at: "consent.submit", for: requester) else { return .string("denied") }
            do {
                let proof = try JSONDecoder().decode(MeetingSignedConsent.self, from: JSONEncoder().encode(value))
                guard proof.identity.referencesSameSigningIdentity(as: requester) else { throw MeetingSessionError.forbidden }
                try self.mutate {
                    guard self.journal != nil, let session = self.session else { throw MeetingSessionError.unavailable }
                    let snapshot = try session.snapshot(now: Date())
                    guard self.initialOperations[proof.operationID] == nil, !self.startOperations.contains(proof.operationID) else { throw MeetingSessionError.operationConflict }
                    try proof.verify(cellID: self.uuid, reference: snapshot.reference, plan: snapshot.plan, at: Date())
                    try session.approve(by: proof.principal, operationID: proof.operationID, expected: proof.reference, now: Date(), signedExpiry: proof.expiresAt)
                    self.presence[try proof.principal] = (proof.reference, Date())
                    if !self.signedConsents.contains(where: { $0.reference == proof.reference && (try? $0.principal) == (try? proof.principal) }) { self.signedConsents.append(proof) }
                }
                self.changed(requester)
                return .object(["status": .string("ok"), "durability": .string(self.durabilityLabel)])
            } catch { return Self.failure(error) }
        }
        await registerSet(key: "recording.start", owner: owner, input: Self.actionSchema, returns: Self.resultSchema,
            permissions: ["-w--"], description: .string("Explicit recorder start after durable participant approvals. Retry never starts a new segment.")) { [weak self] requester, value in
            guard let self, await self.validateAccess("-w--", at: "recording.start", for: requester) else { return .string("denied") }
            do {
                let input = try JSONDecoder().decode(MeetingActionInput.self, from: JSONEncoder().encode(value))
                let principal = try Self.principal(requester)
                let capture = try self.mutate { () throws -> MeetingCaptureCoordinator in
                    guard self.journal != nil, let session = self.session, let capture = self.coordinator else { throw MeetingSessionError.unavailable }
                    let snapshot = try session.snapshot(now: Date())
                    guard snapshot.plan.recorder == principal, snapshot.reference == input.expected else { throw MeetingSessionError.forbidden }
                    guard !self.startOperations.contains(input.operationID), self.initialOperations[input.operationID] == nil, snapshot.operations?[input.operationID] == nil, snapshot.stopOperations[input.operationID] == nil else { throw MeetingSessionError.operationConflict }
                    let proofs = self.signedConsents.filter { $0.reference == input.expected }
                    guard Set(try proofs.map { try $0.principal }) == Set(snapshot.plan.participants) else { throw MeetingSessionError.consentIncomplete }
                    for proof in proofs { try proof.verify(cellID: self.uuid, reference: input.expected, plan: snapshot.plan, at: Date()) }
                    guard snapshot.plan.participants.allSatisfy({ member in
                        guard let seen = self.presence[member] else { return false }
                        return seen.0 == input.expected && Date().timeIntervalSince(seen.1) < 1.5
                    }) else { throw MeetingSessionError.consentIncomplete }
                    self.startOperations.insert(input.operationID)
                    return capture
                }
                let permit = try await capture.start(by: principal, expected: input.expected)
                self.changed(requester)
                return .object(["status": .string("ok"), "durability": .string(self.durabilityLabel), "permit": MeetingSurfaceConfiguration.encode(permit)])
            } catch { return Self.failure(error) }
        }
        await registerSet(key: "segment.revoke", owner: owner, input: Self.segmentActionSchema, returns: Self.resultSchema,
            permissions: ["-w--"], description: .string("Stop further processing of an original segment as its authenticated participant, including after leaving the current roster.")) { [weak self] requester, value in
            guard let self, await self.validateAccess("-w--", at: "segment.revoke", for: requester) else { return .string("denied") }
            do {
                let input = try JSONDecoder().decode(SegmentInput.self, from: JSONEncoder().encode(value))
                let principal = try Self.principal(requester)
                defer { self.changed(requester) }
                try self.mutate {
                    guard let session = self.session else { throw MeetingSessionError.unavailable }
                    guard self.initialOperations[input.operationID] == nil, !self.startOperations.contains(input.operationID) else { throw MeetingSessionError.operationConflict }
                    try session.revokeProcessing(segmentID: input.segmentID, by: principal,
                        operationID: input.operationID, expected: input.expected, now: Date())
                }
                if let capture = self.locked({ self.coordinator }) { await capture.checkAdmission() }
                return .object(["status": .string("ok"), "durability": .string(self.durabilityLabel)])
            } catch { return Self.failure(error) }
        }
    }
    private struct PlanInput: Decodable { let operationID: UUID; let plan: MeetingPlan; let expected: MeetingPlanReference? }
    private struct SegmentInput: Decodable { let operationID: UUID; let segmentID: UUID; let expected: MeetingPlanReference }
    private func readState(_ requester: Identity) throws -> ValueType {
        let principal = try Self.principal(requester)
        return try locked {
            guard let session else {
                guard requester.referencesSameSigningIdentity(as: owner) else { throw MeetingSessionError.forbidden }
                return .object(["title": .string("Opprett et privat møte"), "notice": .string("Mikrofonen er av. Ingen møteplan er opprettet."), "terms": .string("Legg til alle deltakere før du sender planen."), "participants": .list([]), "actions": .list([]), "stopActions": .list([])])
            }
            let snapshot = try session.snapshot(now: Date())
            guard snapshot.plan.participants.contains(principal) else { throw MeetingSessionError.forbidden }
            return MeetingSurfaceConfiguration.state(snapshot, viewer: principal, mediaAvailable: journal != nil && coordinator != nil)
        }
    }
    private func changed(_ requester: Identity) {
        // Only an invalidation notice goes into Flow, not private plan/transcript.
        var event = FlowElement(title: "Meeting changed", content: .object(["reload": .bool(true)]),
            properties: FlowElement.Properties(type: .event, contentType: .object))
        event.topic = "meeting.changed"; event.origin = uuid
        pushFlowElement(event, requester: requester)
    }
    private static func failure(_ error: Error) -> ValueType {
        .object(["status": .string("error"), "code": .string((error as? MeetingSessionError)?.rawValue ?? "invalidInput")])
    }
    private static let resultSchema = ExploreContract.schema(type: "object")
    private static let stateSchema = ExploreContract.schema(type: "object")
    private static let referenceSchema = ExploreContract.objectSchema(properties: [
        "sessionID": ExploreContract.schema(type: "string"), "revision": ExploreContract.schema(type: "integer"), "hash": ExploreContract.schema(type: "string")
    ], requiredKeys: ["sessionID", "revision", "hash"])
    private static let actionSchema = ExploreContract.objectSchema(properties: [
        "operationID": ExploreContract.schema(type: "string"), "expected": referenceSchema
    ], requiredKeys: ["operationID", "expected"])
    private static let segmentActionSchema = ExploreContract.objectSchema(properties: [
        "operationID": ExploreContract.schema(type: "string"),
        "segmentID": ExploreContract.schema(type: "string"), "expected": referenceSchema
    ], requiredKeys: ["operationID", "segmentID", "expected"])
    private static let principalSchema = ExploreContract.objectSchema(properties: [
        "id": ExploreContract.schema(type: "string"), "signingKeyFingerprint": ExploreContract.schema(type: "string")
    ], requiredKeys: ["id", "signingKeyFingerprint"])
    private static let planSchema = ExploreContract.objectSchema(properties: [
        "purpose": ExploreContract.schema(type: "string"),
        "participants": ExploreContract.listSchema(item: principalSchema),
        "recorder": principalSchema, "locale": ExploreContract.schema(type: "string"),
        "processingRoute": ExploreContract.schema(type: "string"),
        "rawAudioLifetime": ExploreContract.schema(type: "number"),
        "deliveryLifetime": ExploreContract.schema(type: "number"),
        "recipientLifetime": ExploreContract.schema(type: "number"),
        "consentLifetime": ExploreContract.schema(type: "number")
    ], requiredKeys: ["purpose", "participants", "recorder", "locale", "processingRoute",
                      "rawAudioLifetime", "deliveryLifetime", "recipientLifetime", "consentLifetime"])
    private static let planInputSchema = ExploreContract.objectSchema(properties: [
        "operationID": ExploreContract.schema(type: "string"), "plan": planSchema, "expected": referenceSchema
    ], requiredKeys: ["operationID", "plan"])
}
