import Foundation
import CryptoKit
import CellBase

/// Application lifetime composition, scoped to one real local vault identity.
/// Nearby carries only invitations and an authenticated private Cell channel.
@MainActor public final class MeetingNearbyAppRuntime {
    public static let shared = MeetingNearbyAppRuntime()
    struct Offer: Codable { let invitation: MeetingNearbyInvitation; let admission: Contract }
    private struct Host {
        let cell: MeetingSessionCell
        let pipeline: MeetingRecordingPipeline
        let surface: MeetingParticipantSurfaceCell
    }
    private var hosts: [String: Host] = [:]
    private var surfaces: [String: MeetingParticipantSurfaceCell] = [:]
    private var surfaceByMeeting: [String: MeetingParticipantSurfaceCell] = [:]
    private var offers: [UUID: (Offer, ScannerConsumerContext)] = [:]
    private var relays: [UUID: ScannerMeetingRelay] = [:]
    private var bound: MeetingPrincipal?
    private var owner: Identity?
    private var root: URL?
    private var key: Data?
    private var provider: (any IdentityKeyRoleProviderProtocol)?
    private var selectedHost: String?
    private var opening: Set<UUID> = []
    private var initializing = false
    private var inboxCell: MeetingInboxCell?
    private var maintenance: Task<Void, Never>?
    public private(set) var lastError: String?

    private func bind(_ identity: Identity) async throws {
        let principal = try MeetingEvidence.principal(identity)
        guard !initializing else { throw MeetingSessionError.unavailable }
        if let bound { guard bound == principal else { throw MeetingSessionError.forbidden }; return }
        initializing = true; defer { initializing = false }
        guard let vault = identity.identityVault as? any IdentityKeyRoleProviderProtocol,
              let secretProvider = identity.identityVault as? any ScopedSecretProviderProtocol else { throw MeetingSessionError.unavailable }
        let secret = try await secretProvider.scopedSecretData(tag: "meeting-" + principal.signingKeyFingerprint, minimumLength: 32)
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("HAVEN/PrivateMeetings/" + principal.signingKeyFingerprint, isDirectory: true)
        _ = try MeetingFileStore(directory: directory)
        owner = identity; provider = vault; root = directory; key = secret
        let inboxCell = await MeetingInboxCell(owner: identity)
        self.inboxCell = inboxCell
        try await CellBase.defaultCellResolver?.registerNamedEmitCell(name: inboxCell.uuid, emitCell: inboxCell, scope: .identityUnique, identity: identity)
        // Only our UUID-named meeting directories are considered. A restored
        // journal revokes all old approvals before any device is installed.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ UUID(uuidString: $0.lastPathComponent) != nil }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(32) {
            let metadata = try MeetingFileStore(directory: url)
            if let sealed = try metadata.read("sender") {
                do {
                    let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: secret), authenticating: Data(url.lastPathComponent.utf8))
                    let descriptor = try JSONDecoder().decode(IdentityPublicKeyDescriptor.self, from: bytes)
                    let inbox = MeetingDeliveryService(identity: identity, provider: vault, store: try storage(url.lastPathComponent, "inbox"))
                    inboxCell.add(cellID: url.lastPathComponent, inbox: inbox, sender: ChatInvitationProofUtility.identity(from: descriptor))
                    try await inbox.purgeExpired()
                } catch { lastError = "En lagret møtekobling kunne ikke verifiseres." }
            }
            let marker = url.appendingPathComponent("host.meeting")
            guard FileManager.default.fileExists(atPath: marker.path) else { continue }
            do { try await restoreHost(id: url.lastPathComponent, identity: identity) }
            catch { lastError = "Et lagret møte kunne ikke gjenopprettes. Opptak er av." }
        }
        bound = principal
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self else { return }
                for host in self.hosts.values { try? await host.pipeline.maintain() }
                // Delivery can continue after leaving the meeting view, but
                // this maintenance loop never sends presence or renews capture.
                for surface in self.surfaces.values { try? await surface.synchronizeDelivery() }
                self.relays = self.relays.filter { $0.value.context.isLive }
            }
        }
    }
    /// Authenticated app bootstrap resumes local retention/processing only when
    /// this identity already has a meeting store. It never starts a microphone.
    public func restoreIfPresent(identity: Identity) async throws {
        let principal = try MeetingEvidence.principal(identity)
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("HAVEN/PrivateMeetings/" + principal.signingKeyFingerprint)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try await bind(identity)
    }
    public func prepare(identity: Identity) async throws { try await bind(identity) }
    public func inboxConfiguration(identity: Identity) async throws -> CellConfiguration {
        try await bind(identity)
        guard let inboxCell else { throw MeetingSessionError.unavailable }
        return try inboxCell.configuration()
    }
    private func storage(_ id: String, _ component: String) throws -> MeetingFileStore {
        guard UUID(uuidString: id) != nil, let root else { throw MeetingSessionError.invalidPlan }
        return try MeetingFileStore(directory: root.appendingPathComponent(id).appendingPathComponent(component))
    }
    private func surface(cellID: String, target: any Meddle, recorder: Identity, identity: Identity) async throws -> MeetingParticipantSurfaceCell {
        guard let provider, let resolver = CellBase.defaultCellResolver else { throw MeetingSessionError.unavailable }
        let inbox = MeetingDeliveryService(identity: identity, provider: provider, store: try storage(cellID, "inbox"))
        guard let root, let key else { throw MeetingSessionError.unavailable }
        let metadata = try MeetingFileStore(directory: root.appendingPathComponent(cellID))
        var descriptor = try ChatInvitationProofUtility.signingDescriptor(for: recorder); descriptor.displayName = nil
        if let sealed = try metadata.read("sender") {
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: key), authenticating: Data(cellID.utf8))
            guard try JSONDecoder().decode(IdentityPublicKeyDescriptor.self, from: bytes) == descriptor else { throw MeetingSessionError.forbidden }
        } else {
            let sealed = try AES.GCM.seal(JSONEncoder().encode(descriptor), using: SymmetricKey(data: key), authenticating: Data(cellID.utf8))
            guard let bytes = sealed.combined else { throw MeetingSessionError.unavailable }
            try metadata.commit(bytes, key: "sender")
        }
        inboxCell?.add(cellID: cellID, inbox: inbox, sender: recorder)
        let client = MeetingParticipantClient(cellID: cellID, target: target, identity: identity, recorder: recorder, inbox: inbox)
        if let existing = surfaceByMeeting[cellID] {
            existing.bind(target: target, client: client)
            return existing
        }
        guard surfaces.count < 32 else { throw MeetingSessionError.unavailable }
        let surface = await MeetingParticipantSurfaceCell(owner: identity)
        surface.bind(target: target, client: client)
        try await resolver.registerNamedEmitCell(name: surface.uuid, emitCell: surface, scope: .identityUnique, identity: identity)
        surfaces[surface.uuid] = surface; surfaceByMeeting[cellID] = surface
        return surface
    }
    private func install(_ cell: MeetingSessionCell, identity: Identity) async throws -> Host {
        guard let key, let provider, let resolver = CellBase.defaultCellResolver else { throw MeetingSessionError.unavailable }
        try cell.installDelivery(store: storage(cell.uuid, "outbox"), recorder: identity, provider: provider)
        let pipeline = MeetingRecordingPipeline(cell: cell, store: try storage(cell.uuid, "audio"), key: SymmetricKey(data: key))
        try cell.installCaptureDevice(pipeline.makeCaptureDevice())
        try await resolver.registerNamedEmitCell(name: cell.uuid, emitCell: cell, scope: .identityUnique, identity: identity)
        let view = try await surface(cellID: cell.uuid, target: cell, recorder: identity, identity: identity)
        let host = Host(cell: cell, pipeline: pipeline, surface: view)
        hosts[cell.uuid] = host; selectedHost = cell.uuid
        try await pipeline.maintain(recoverInterrupted: true)
        return host
    }
    private func restoreHost(id: String, identity: Identity) async throws {
        guard let key else { throw MeetingSessionError.unavailable }
        let cell = await MeetingSessionCell(owner: identity); cell.uuid = id
        try cell.installDurability(store: storage(id, "journal"), key: key)
        _ = try cell.durableSnapshot()
        _ = try await install(cell, identity: identity)
    }
    /// Called only by the owner's explicit Nearby invite action. A new invite
    /// first stops an existing recording; it does not silently enlarge its plan.
    func invite(service: ScannerService, context: ScannerConsumerContext, identity: Identity, purpose: String) async throws -> CellConfiguration {
        try await bind(identity); try context.check()
        guard context.localIdentity.makeIdentity().referencesSameSigningIdentity(as: identity), let key, let root else { throw MeetingSessionError.forbidden }
        let host: Host
        if let selectedHost, let existing = hosts[selectedHost] {
            host = existing
            let state = try host.cell.durableSnapshot()
            let stop = MeetingActionInput(expected: state.reference)
            try requireOK(try await host.cell.set(keypath: "recording.stop", value: encode(stop), requester: identity))
        } else {
            guard hosts.count < 32, !purpose.isEmpty, purpose.utf8.count <= 512 else { throw MeetingSessionError.invalidPlan }
            let cell = await MeetingSessionCell(owner: identity)
            try cell.installDurability(store: storage(cell.uuid, "journal"), key: key)
            let plan = MeetingPlan(purpose: purpose, participants: [try MeetingEvidence.principal(identity), try MeetingEvidence.principal(context.identity.makeIdentity())], recorder: try MeetingEvidence.principal(identity))
            try requireOK(try await cell.set(keypath: "plan.propose", value: .object(["operationID": .string(UUID().uuidString), "plan": encode(plan)]), requester: identity))
            host = try await install(cell, identity: identity)
            // No private data in the discoverability marker. Authority is in the
            // encrypted journal and the owner's real vault.
            try MeetingFileStore(directory: root.appendingPathComponent(cell.uuid)).commit(Data("v1".utf8), key: "host")
        }
        let invite = try await MeetingNearbyInvitation.make(cellID: host.cell.uuid, endpoint: "cell:///" + host.cell.uuid,
            inviter: identity, recipient: MeetingEvidence.principal(context.identity.makeIdentity()))
        let admission = try await host.cell.makeAdmission(for: context.identity.makeIdentity())
        let relay = try await service.makeMeetingRelay(context: context, cellID: host.cell.uuid, channelID: invite.nonce, inbound: true)
        relays[invite.nonce] = relay
        let offer = Offer(invitation: invite, admission: admission)
        let content = try JSONDecoder().decode(FlowElementValueType.self, from: JSONEncoder().encode(offer))
        var event = FlowElement(title: "Private meeting invitation", content: content, properties: .init(type: .event, contentType: .object))
        event.topic = "scanner.meeting.offer.v1"
        try await service.sendScannerFlowElement(event, context: context)
        return try MeetingSurfaceConfiguration.make(endpoint: "cell:///" + host.surface.uuid)
    }
    func receiveOffer(_ value: FlowElementValueType, context: ScannerConsumerContext) throws {
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 65536 else { throw MeetingSessionError.invalidPlan }
        let offer = try JSONDecoder().decode(Offer.self, from: bytes)
        try offer.invitation.verify(authenticatedPeer: context.identity.makeIdentity(), localRecipient: context.localIdentity.makeIdentity())
        guard offer.admission.targetCellUUID == offer.invitation.cellID, offers.count < 32 else { throw MeetingSessionError.invalidPlan }
        try context.perform { offers[offer.invitation.nonce] = (offer, context) }
    }
    func pending(identity: Identity) -> ValueType {
        offers = offers.filter { $0.value.0.invitation.expiresAt > Date() && $0.value.1.isLive }
        return .list(offers.values.filter { $0.1.localIdentity.makeIdentity().referencesSameSigningIdentity(as: identity) }.map {
            .object(["id": .string($0.0.invitation.nonce.uuidString), "inviter": .string($0.0.invitation.inviter.uuid)])
        })
    }
    func accept(_ nonce: UUID, service: ScannerService, identity: Identity) async throws -> CellConfiguration {
        guard !opening.contains(nonce), let (offer, context) = offers[nonce] else { throw MeetingSessionError.forbidden }
        opening.insert(nonce); defer { opening.remove(nonce) }
        try await bind(identity)
        try offer.invitation.verify(authenticatedPeer: context.identity.makeIdentity(), localRecipient: identity)
        let relay = try await service.makeMeetingRelay(context: context, cellID: offer.invitation.cellID, channelID: nonce, inbound: false)
        relays[nonce] = relay
        guard let bridge = relay.bridge else { throw MeetingSessionError.unavailable }
        let request = try await MeetingJoinRequest.make(invitation: offer.invitation, admission: offer.admission, identity: identity)
        try requireOK(try await bridge.set(keypath: "meeting.join", value: encode(request), requester: identity))
        let view = try await surface(cellID: offer.invitation.cellID, target: bridge, recorder: context.identity.makeIdentity(), identity: identity)
        offers[nonce] = nil
        return try MeetingSurfaceConfiguration.make(endpoint: "cell:///" + view.uuid)
    }
    public func visibleMeetingPulse(endpoint: String) async throws {
        guard let owner, let vault = CellBase.defaultIdentityVault,
              let active = await vault.identity(for: "private", makeNewIfNotFound: false), active.referencesSameSigningIdentity(as: owner) else { throw MeetingSessionError.forbidden }
        // Only local clients pulse; a recorder cannot manufacture remote presence.
        guard endpoint.hasPrefix("cell:///"), let surface = surfaces[String(endpoint.dropFirst(8))] else { throw MeetingSessionError.unavailable }
        try await surface.pulse()
        for host in hosts.values { try await host.pipeline.maintain() }
    }
    private func encode<T: Encodable>(_ value: T) -> ValueType {
        (try? JSONDecoder().decode(ValueType.self, from: JSONEncoder().encode(value))) ?? .null
    }
    private func requireOK(_ value: ValueType?) throws {
        guard case let .object(object)? = value, object["status"] == .string("ok") else { throw MeetingSessionError.unavailable }
    }
}
