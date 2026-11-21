import Foundation

/// Local renderer endpoint: exactly the shared Skeleton, with approval signing
/// performed by this device's client. The remote recorder never signs for us.
public final class MeetingParticipantSurfaceCell: GeneralCell, @unchecked Sendable {
    private let bindingLock = NSLock()
    private var target: (any Meddle)?
    private var client: MeetingParticipantClient?
    private var connectionLost = false
    public required init(owner: Identity) async { await super.init(owner: owner) }
    public required init(from decoder: Decoder) throws { try super.init(from: decoder) }
    public override func installCellRuntimeBindingsForAccess() async throws {
        for key in ["state", "plan.current", "cellConfiguration"] {
            await registerExploreContract(requester: owner, key: key, method: .get, input: .null,
                returns: ExploreContract.schema(type: "object"), permissions: ["r---"], required: false,
                description: .string("Private local-owner view of the authenticated meeting; no remote signing authority."))
        }
        for key in ["consent.approve", "consent.decline", "consent.revoke", "recording.start", "recording.stop", "segment.revoke"] {
            await registerExploreContract(requester: owner, key: key, method: .set, input: ExploreContract.schema(type: "object"),
                returns: ExploreContract.schema(type: "object"), permissions: ["-w--"], required: false,
                description: .string("Explicit local-owner action bound to the currently displayed plan. Only this device signs its own approval."))
        }
    }
    public func bind(target: any Meddle, client: MeetingParticipantClient) { bindingLock.withLock { self.target = target; self.client = client } }
    public override func get(keypath: String, requester: Identity) async throws -> ValueType {
        guard requester.referencesSameSigningIdentity(as: owner), await checkIdentityOrigin(requester, against: owner),
              let target = bindingLock.withLock({ self.target }) else { throw MeetingSessionError.forbidden }
        if keypath == "cellConfiguration" { return MeetingSurfaceConfiguration.encode(try MeetingSurfaceConfiguration.make(endpoint: "cell:///" + uuid)) }
        if keypath == "state", bindingLock.withLock({ connectionLost }) {
            var state: Object = ["title": .string("Møtekoblingen er brutt"),
                "notice": .string("Opptakstillatelsen fornyes ikke. Koble til igjen fra Nearby.")]
            for key in ["purpose", "captureTerms", "deliveryTerms", "retentionTerms"] { state[key] = .string("") }
            for key in ["participants", "approveActions", "declineActions", "revokeActions", "startActions", "stopOnlyActions", "newParticipantActions", "actions", "stopActions"] { state[key] = .list([]) }
            return .object(state)
        }
        guard ["state", "plan.current"].contains(keypath) else { return try await super.get(keypath: keypath, requester: requester) }
        return try await target.get(keypath: keypath, requester: owner)
    }
    public override func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? {
        guard requester.referencesSameSigningIdentity(as: owner), await checkIdentityOrigin(requester, against: owner),
              let (target, client) = bindingLock.withLock({ () -> ((any Meddle), MeetingParticipantClient)? in
                  guard let target = self.target, let client = self.client else { return nil }; return (target, client)
              }) else { throw MeetingSessionError.forbidden }
        let allowed = ["consent.approve", "consent.decline", "consent.revoke", "recording.start", "recording.stop", "segment.revoke"]
        guard allowed.contains(keypath) else { throw MeetingSessionError.forbidden }
        let input = try JSONDecoder().decode(MeetingActionInput.self, from: JSONEncoder().encode(value))
        switch keypath {
        case "consent.approve": try await client.approve(expected: input.expected, operationID: input.operationID)
        case "recording.start": try await client.start(expected: input.expected, operationID: input.operationID)
        case "recording.stop": try await client.stop(expected: input.expected, operationID: input.operationID)
        default: return try await target.set(keypath: keypath, value: value, requester: owner) ?? .null
        }
        return .object(["status": .string("ok")])
    }
    public func pulse() async throws {
        guard let client = bindingLock.withLock({ self.client }) else { throw MeetingSessionError.unavailable }
        do {
            try await client.pulse()
            bindingLock.withLock { connectionLost = false }
        } catch {
            bindingLock.withLock { connectionLost = true }
            refreshed()
            throw error
        }
        refreshed()
    }
    private func refreshed() {
        var event = FlowElement(title: "Meeting refreshed", content: .object(["reload": .bool(true)]), properties: .init(type: .event, contentType: .object))
        event.topic = "meeting.changed"; event.origin = uuid
        pushFlowElement(event, requester: owner)
    }
    public func synchronizeDelivery() async throws {
        guard let client = bindingLock.withLock({ self.client }) else { throw MeetingSessionError.unavailable }
        _ = try await client.synchronizeDelivery()
    }
}
