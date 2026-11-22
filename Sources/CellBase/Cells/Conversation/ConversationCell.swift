// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

/// One conversation as its own Cell: its own members, its own storage area
/// (`ConversationStore`) and its own feed on `haven.chat.conversation`.
///
/// Only accepted members can read, send, mark read or subscribe to the feed.
/// A pending invitee can read `preview` (title and inviter) and nothing else.
/// No umbrella or parent keypath grants anything here. Membership is set by
/// the owner, or by the hosting scaffold in-process through
/// `applyMembership`; never by a member.
///
/// Realtime is event driven: `message.appended` carries the whole message and
/// its `seq`. Clients call `messages.since` only on a gap in `seq`, after a
/// reconnect, or on return from background. Nothing here runs on a timer.
///
/// Provisioning mode is explicit: a cell made with `init(owner:)` or decoded
/// from disk has no storage until the host calls `provision`. Until then every
/// operation answers `storage_failed`.
public final class ConversationCell: GeneralCell, MeddleOperationAuthorizationRequirementProviding {
    public static let flowTopic = "haven.chat.conversation"
    public static let memberReadKeypaths: Set<String> = ["state", "messages.since", "feed"]
    public static let memberWriteKeypaths: Set<String> = ["messages.send", "read.mark"]

    public private(set) var conversationID: String = ""
    private var engineValue: ConversationEngine?
    private let engineLock = NSLock()
    private var membershipSnapshot = ConversationMeta(
        conversationID: "", generation: 0, title: "", ownerUUID: "", inviterDisplayName: "", members: [], updatedAt: ""
    )
    private var engine: ConversationEngine? {
        get { engineLock.withLock { engineValue } }
        set { engineLock.withLock { engineValue = newValue } }
    }

    private enum CodingKeys: String, CodingKey { case conversationID }

    /// A provisioned conversation. `members` should include the owner when the
    /// owner takes part.
    public init(
        owner: Identity,
        conversationID: String,
        title: String,
        members: [ConversationMember],
        pendingInviteeUUIDs: [String] = [],
        store: ConversationStore,
        index: ConversationIndex,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async {
        await super.init(owner: owner)
        self.conversationID = conversationID
        persistancy = .ephemeral
        let meta = ConversationMeta(
            conversationID: conversationID,
            generation: 1,
            title: title,
            ownerUUID: owner.uuid,
            inviterDisplayName: owner.displayName,
            members: members.sorted { $0.uuid < $1.uuid },
            pendingInviteeUUIDs: pendingInviteeUUIDs.sorted(),
            updatedAt: ConversationCodec.timestamp(now())
        )
        await attach(ConversationEngine(meta: meta, store: store, index: index, now: now))
        try? await ensureRuntimeReady()
    }

    /// Not provisioned: answers `storage_failed` until `provision` is called.
    public required init(owner: Identity) async {
        await super.init(owner: owner)
        persistancy = .ephemeral
        try? await ensureRuntimeReady()
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID) ?? ""
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversationID, forKey: .conversationID)
    }

    /// Host-side provisioning for a cell created without storage. The stored
    /// `meta/` generation wins over `title`/`members` when it exists.
    @_spi(HAVENRuntime)
    public func provision(
        conversationID: String,
        title: String,
        members: [ConversationMember],
        store: ConversationStore,
        index: ConversationIndex,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws {
        guard engine == nil else { return }
        self.conversationID = conversationID
        let meta = ConversationMeta(
            conversationID: conversationID, generation: 1, title: title, ownerUUID: owner.uuid,
            inviterDisplayName: owner.displayName, members: members.sorted { $0.uuid < $1.uuid },
            updatedAt: ConversationCodec.timestamp(now())
        )
        let engine = ConversationEngine(meta: meta, store: store, index: index, now: now)
        await attach(engine)
        try await engine.loadIfNeeded()
    }

    private func attach(_ engine: ConversationEngine) async {
        self.engine = engine
        await engine.setMembershipObserver { [weak self] meta in
            guard let self else { return }
            self.engineLock.withLock { self.membershipSnapshot = meta }
        }
    }

    /// Called after a message is committed, with the recipients (accepted
    /// members except the author). The host sends push notifications here.
    @_spi(HAVENRuntime)
    public func setMessageStoredHook(_ hook: (@Sendable (ConversationMessage, [String]) async -> Void)?) async {
        await engine?.setStoredHook(hook)
    }

    /// Host-side membership authority (invitation accepted, link redeemed,
    /// member left or blocked). A new generation and `member.changed` follow
    /// only when something changed.
    @_spi(HAVENRuntime)
    @discardableResult
    public func applyMembership(
        title: String,
        members: [ConversationMember],
        pendingInviteeUUIDs: [String],
        blockedUUIDs: [String] = []
    ) async throws -> Int {
        guard let engine else { throw ConversationStoreError.backend("conversation not provisioned") }
        return try await engine.applyMembership(title: title, members: members, pending: pendingInviteeUUIDs, blocked: blockedUUIDs)
    }

    /// Current membership as last applied (synchronous snapshot).
    public var membership: ConversationMeta { engineLock.withLock { membershipSnapshot } }

    // MARK: Runtime bindings

    public override func installCellRuntimeBindingsForAccess() async throws {
        if let engine, let emitter = await makeCellOwnedFlowEmitterForRuntimeBinding(requester: owner) {
            await engine.setEmitter(emitter)
        }
        try? await engine?.loadIfNeeded()
        await registerOperations()
    }

    public func meddleAuthorizationRequirement(for method: ExploreContractMethod, keypath: String) async throws -> String? {
        switch (method, keypath) {
        case (.get, "state"), (.get, "preview"), (.set, "messages.since"): return "r---"
        case (.set, "messages.send"), (.set, "read.mark"): return "-w--"
        case (.get, let path) where path.hasPrefix("messages.since."): return "r---"
        default: return nil
        }
    }

    public override func validateCellSpecificAccess(_ requestedAccess: String, at keypath: String, for identity: Identity) async -> Bool {
        guard !CellBase.debugValidateAccessForEverything, let engine else { return false }
        let path = keypath.hasPrefix("messages.since.") ? "messages.since" : keypath
        let allowed: Bool
        if path == "preview" {
            allowed = requestedAccess == "r---"
        } else if Self.memberReadKeypaths.contains(path) {
            allowed = requestedAccess == "r---"
        } else if Self.memberWriteKeypaths.contains(path) {
            allowed = requestedAccess == "-w--"
        } else {
            return false
        }
        guard allowed else { return false }
        let status = await engine.status(uuid: identity.uuid, signingFingerprint: identity.signingPublicKeyFingerprint)
        switch status {
        case .accepted: break
        case .pending where path == "preview": break
        default: return false
        }
        return await verifyRequesterIdentityControl(identity)
    }

    public override func authorizationDecision(requestedAccess: String, at keypath: String, for identity: Identity) async -> CellAuthorizationDecision {
        var decision = await super.authorizationDecision(requestedAccess: requestedAccess, at: keypath, for: identity)
        if decision.allowed == false, let engine {
            let status = await engine.status(uuid: identity.uuid, signingFingerprint: identity.signingPublicKeyFingerprint)
            if let reason = status.denial {
                decision.reasonCode = reason.rawValue
                decision.userMessage = "Only accepted members of this conversation can do this."
                decision.developerHint = "ConversationCell does not consult umbrella or parent keypaths."
            }
        }
        return decision
    }

    /// The feed is member-only, and stops delivering the moment a member
    /// leaves or is blocked.
    public override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
        let upstream = try await super.flow(requester: requester)
        let uuid = requester.uuid
        let fingerprint = requester.signingPublicKeyFingerprint
        let ownerUUID = owner.uuid
        return upstream.filter { [weak self] _ in
            guard let self else { return false }
            if uuid == ownerUUID { return true }
            let meta = self.membership
            guard let member = meta.acceptedMember(uuid) else { return false }
            return member.signingPublicKeyFingerprint == nil || member.signingPublicKeyFingerprint == fingerprint
        }.eraseToAnyPublisher()
    }

    public override func get(keypath: String, requester: Identity) async throws -> ValueType {
        if keypath.hasPrefix("messages.since.") {
            try await ensureRuntimeReady()
            guard await validateAccess("r---", at: "messages.since", for: requester) else {
                throw CellAuthorizationError.denied(await authorizationDecision(requestedAccess: "r---", at: "messages.since", for: requester))
            }
            let parts = keypath.dropFirst("messages.since.".count).split(separator: ".")
            let after = parts.first.flatMap { Int($0) } ?? 0
            let limit = parts.count > 1 ? Int(parts[1]) ?? ConversationEngine.maximumPageSize : ConversationEngine.maximumPageSize
            return await since(afterSeq: after, limit: limit)
        }
        return try await super.get(keypath: keypath, requester: requester)
    }

    private func member(for requester: Identity) async -> ConversationMember? {
        guard let engine else { return nil }
        if case .accepted(let member) = await engine.status(uuid: requester.uuid, signingFingerprint: requester.signingPublicKeyFingerprint) {
            return member
        }
        return nil
    }

    private func refusal(_ reason: ConversationDenialReason) -> ValueType {
        .object(["ok": .bool(false), "status": .string("error"), "code": .string(reason.rawValue)])
    }

    private func since(afterSeq: Int, limit: Int) async -> ValueType {
        guard let engine, let page = try? await engine.since(afterSeq: afterSeq, limit: limit),
              let value = try? ConversationCodec.value(page) else { return refusal(.storageFailed) }
        return value
    }

    private func registerOperations() async {
        let object = ExploreContract.schema(type: "object")
        await registerGet(key: "state", owner: owner, returns: object, permissions: ["r---"], required: true,
            description: .string("Member-only: title, members, lastSeq, unread, readUptoSeq and the last 50 messages."),
            handler: { [weak self] requester in
                guard let self else { return .null }
                guard let engine = self.engine, let member = await self.member(for: requester) else { return self.refusal(.notMember) }
                guard let state = try? await engine.state(for: member) else { return self.refusal(.storageFailed) }
                return .object(state)
            })
        await registerGet(key: "preview", owner: owner, returns: object, permissions: ["r---"], required: true,
            description: .string("Title and inviter only. The one thing a pending invitee can read."),
            handler: { [weak self] _ in
                guard let self, let engine = self.engine, let preview = try? await engine.preview() else { return .null }
                return .object(preview)
            })
        await registerSet(key: "messages.send", owner: owner, input: object, returns: object, permissions: ["-w--"], required: true,
            flowEffects: [.object(["topic": .string(Self.flowTopic), "title": .string("message.appended")])],
            description: .string("{clientMessageID, contentType, content}. Same clientMessageID never stores twice. sent only after storage and index."),
            handler: { [weak self] requester, payload in
                guard let self else { return .null }
                guard let engine = self.engine else { return self.refusal(.storageFailed) }
                guard let member = await self.member(for: requester) else { return self.refusal(.notMember) }
                guard case .object(let fields) = payload,
                      case .string(let clientID)? = fields["clientMessageID"],
                      case .string(let content)? = fields["content"] else { return self.refusal(.invalidPayload) }
                var contentType = "text/plain"
                if case .string(let declared)? = fields["contentType"] { contentType = declared }
                let result = await engine.send(author: member, clientMessageID: clientID, contentType: contentType, content: content)
                return (try? ConversationCodec.value(result)) ?? self.refusal(.storageFailed)
            })
        await registerSet(key: "messages.since", owner: owner, input: object, returns: object, permissions: ["r---"], required: true,
            description: .string("{afterSeq, limit<=200}. Only on a gap in seq, after reconnect, or on return from background. Never on a timer."),
            handler: { [weak self] _, payload in
                guard let self else { return .null }
                var after = 0, limit = ConversationEngine.maximumPageSize
                if case .object(let fields) = payload {
                    if case .integer(let value)? = fields["afterSeq"] { after = value }
                    if case .integer(let value)? = fields["limit"] { limit = value }
                }
                return await self.since(afterSeq: after, limit: limit)
            })
        await registerSet(key: "read.mark", owner: owner, input: object, returns: object, permissions: ["-w--"], required: true,
            flowEffects: [.object(["topic": .string(Self.flowTopic), "title": .string("read.updated")])],
            description: .string("{uptoSeq}. Read marks never move backwards; read.updated reaches the member's other devices."),
            handler: { [weak self] requester, payload in
                guard let self else { return .null }
                guard let engine = self.engine else { return self.refusal(.storageFailed) }
                guard let member = await self.member(for: requester) else { return self.refusal(.notMember) }
                guard case .object(let fields) = payload, case .integer(let upto)? = fields["uptoSeq"] else {
                    return self.refusal(.invalidPayload)
                }
                guard let marked = try? await engine.markRead(member: member, uptoSeq: upto) else { return self.refusal(.storageFailed) }
                return .object(["ok": .bool(true), "readUptoSeq": .integer(marked.readUpto), "unread": .integer(marked.unread)])
            })
    }
}
