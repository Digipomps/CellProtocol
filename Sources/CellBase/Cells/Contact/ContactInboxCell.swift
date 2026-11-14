// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One independently owned contact address. A reference locates this Cell; an
/// owner-signed, subject-and-cell-bound Agreement authorizes posting to it.
/// Chat membership and permission to read this inbox are separate authorities.
public final class ContactInboxCell: GeneralCell, MeddleOperationAuthorizationRequirementProviding {
    public static let domain = "domain:contact-inbox:v1"
    public enum Context: String, Codable { case available, quiet, offline }
    public enum Failure: Error { case invalidRequest, denied, retired, conflictingRequest }
    private struct Entry: Codable {
        let id: String
        let requestID: String
        let sender: Identity
        let payload: ValueType
        let expiresAt: Double
        let acceptedAt: Double
    }
    private struct Inbox: Codable {
        var label = "Kontaktcelle"
        var context: Context = .available
        var retired = false
        var entries: [Entry] = []
        var issuedContracts: [Contract]?
        var revokedContracts: [Contract]?
        var renewAfter: [String: Double]?
    }
    private enum CodingKeys: String, CodingKey { case contactInbox }
    private let stateLock = NSLock()
    private var inbox = Inbox()

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        configure()
    }
    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inbox = try values.decode(Inbox.self, forKey: .contactInbox)
        configure()
    }
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(stateLock.withLock { inbox }, forKey: .contactInbox)
    }
    private func configure() {
        cellScope = .template
        persistancy = .persistant
        identityDomain = Self.domain
        agreementAdmissionPolicy = .ownerApprovalRequired
        agreementTemplate = Agreement(owner: storedOwnerIdentity)
        agreementTemplate.conditions = []
        agreementTemplate.grants = [Grant(keypath: "contact.request", permission: "-w--")]
        agreementTemplate.duration = Int(Contract.maximumDuration)
    }
    public func meddleAuthorizationRequirement(for method: ExploreContractMethod, keypath: String) async throws -> String? {
        // Explicit requirements prevent the generic root-key fallback from
        // turning a grant for `contact` into inbox/read/admin authority.
        method == .get ? "r---" : "-w--"
    }
    public override func validateCellSpecificAccess(_ requestedAccess: String, at keypath: String, for identity: Identity) async -> Bool {
        guard !CellBase.debugValidateAccessForEverything, requestedAccess == "-w--",
              keypath == "agreement.accept" || keypath == "agreement.revoke" else { return false }
        return await verifyRequesterIdentityControl(identity)
    }
    public override func installCellRuntimeBindingsForAccess() async throws {
        configure()
        await registerGet(key: "state", owner: owner, returns: Self.outputSchema("state"), permissions: ["r---"],
                          description: .string("Owner-only contact settings and inbox.")) { [weak self] _ in
            self?.snapshot() ?? .null
        }
        for key in ["contact.request", "settings.update", "retire", "inbox.clear", "agreement.issue", "agreement.accept", "agreement.revoke", "access.revoke"] {
            await registerSet(key: key, owner: owner, input: Self.inputSchema(key), returns: Self.outputSchema(key),
                              permissions: ["-w--"], description: .string(Self.summary(key))) { [weak self] requester, payload in
                guard let self else { throw Failure.denied }
                return try await self.perform(key, payload: payload, requester: requester)
            }
        }
    }
    public override func state(requester: Identity) async throws -> ValueType {
        try await ensureRuntimeReady()
        guard await validateAccess("r---", at: "state", for: requester) else { throw Failure.denied }
        return snapshot()
    }
    /// The owner can share a subject-bound grant with the reference. Presenting
    /// it on first use eliminates a separate enrollment action without making
    /// possession of that reference (or a forwarded card) sufficient authority.
    public override func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? {
        if keypath == "contact.request", case let .object(object) = value,
           let grant = object["agreement"] {
            let contract = try Self.decode(grant, as: Contract.self)
            guard await acceptExternallySignedAgreement(contract, for: requester) == .signed else { throw Failure.denied }
        }
        return try await super.set(keypath: keypath, value: value, requester: requester)
    }
    private func perform(_ key: String, payload: ValueType, requester: Identity) async throws -> ValueType {
        guard case let .object(object) = payload else { throw Failure.invalidRequest }
        switch key {
        case "agreement.accept":
            let contract = try Self.decode(payload, as: Contract.self)
            guard await acceptExternallySignedAgreement(contract, for: requester) == .signed else { throw Failure.denied }
            return .object(["status": .string("accepted")])
        case "agreement.revoke":
            let revocation = try Self.decode(payload, as: ContractRevocation.self)
            guard await acceptExternallySignedRevocation(revocation) else { throw Failure.denied }
            stateLock.withLock {
                let removed = (inbox.issuedContracts ?? []).filter { $0.subject.uuid == revocation.subjectUUID && $0.issuedAt <= revocation.issuedAt }
                inbox.revokedContracts = (inbox.revokedContracts ?? []) + removed
                inbox.issuedContracts?.removeAll { $0.subject.uuid == revocation.subjectUUID && $0.issuedAt <= revocation.issuedAt }
                var renewal = inbox.renewAfter ?? [:]
                renewal[revocation.subjectUUID] = max(renewal[revocation.subjectUUID] ?? 0,
                    Date().timeIntervalSince1970 + Self.externalAdmissionClockTolerance)
                inbox.renewAfter = renewal
            }
            return .object(["status": .string("revoked")])
        case "agreement.issue":
            guard await requesterProvesOwnership(requester), let subjectValue = object["subject"],
                  case let .integer(duration)? = object["durationSeconds"], duration > 0,
                  duration <= Int(Contract.maximumDuration) else { throw Failure.denied }
            let subject: Identity
            if case let .identity(identity) = subjectValue { subject = identity.publicIdentitySnapshot() }
            else { subject = try Self.decode(subjectValue, as: Identity.self).publicIdentitySnapshot() }
            guard subject.signingPublicKeyFingerprint != nil else { throw Failure.invalidRequest }
            let agreement = Agreement(owner: storedOwnerIdentity)
            agreement.state = .signed
            agreement.conditions = []
            agreement.grants = [Grant(keypath: "contact.request", permission: "-w--")]
            agreement.signatories = [storedOwnerIdentity, subject]
            agreement.duration = duration
            let contract = try await Contract.signed(agreement: agreement, issuer: requester,
                subject: subject, domain: identityDomain,
                issuedAt: Date(timeIntervalSince1970: stateLock.withLock { max(Date().timeIntervalSince1970, inbox.renewAfter?[subject.uuid] ?? 0) }),
                targetCellUUID: uuid)
            stateLock.withLock { inbox.issuedContracts = (inbox.issuedContracts ?? []) + [contract] }
            return try Self.encode(contract)
        case "access.revoke":
            guard await requesterProvesOwnership(requester),
                  case let .string(subject)? = object["subjectUUID"], !subject.isEmpty,
                  await validateAccess("-w--", at: "members", for: requester) else { throw Failure.denied }
            // Canonical GeneralCell removal advances the durable admission
            // cutoff even if the signed offer has never been presented.
            await removeMember(uuid: subject, requester: requester)
            stateLock.withLock {
                inbox.revokedContracts = (inbox.revokedContracts ?? []) + (inbox.issuedContracts ?? []).filter { $0.subject.uuid == subject }
                inbox.issuedContracts?.removeAll { $0.subject.uuid == subject }
                var renewal = inbox.renewAfter ?? [:]
                renewal[subject] = Date().timeIntervalSince1970 + Self.externalAdmissionClockTolerance
                inbox.renewAfter = renewal
            }
            return .object(["status": .string("revoked")])
        case "contact.request":
            return try post(object, requester: requester)
        default:
            guard await requesterProvesOwnership(requester) else { throw Failure.denied }
            return try stateLock.withLock {
                switch key {
                case "settings.update":
                    var updated = inbox
                    if let value = object["label"] {
                        guard case let .string(label) = value,
                              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              label.count <= 160 else { throw Failure.invalidRequest }
                        updated.label = label
                    }
                    if let value = object["context"] {
                        guard case let .string(raw) = value, let context = Context(rawValue: raw) else { throw Failure.invalidRequest }
                        updated.context = context
                    }
                    inbox = updated
                case "retire": inbox.retired = true
                case "inbox.clear": inbox.entries.removeAll()
                default: throw Failure.invalidRequest
                }
                return .object(["status": .string("updated")])
            }
        }
    }
    private func post(_ object: Object, requester: Identity) throws -> ValueType {
        guard case let .string(requestID)? = object["requestID"], !requestID.isEmpty, requestID.utf8.count <= 128,
              case let .float(expiresAt)? = object["expiresAt"], expiresAt.isFinite,
              let payload = object["payload"], try JSONEncoder().encode(payload).count <= 32768,
              requester.signingPublicKeyFingerprint != nil else { throw Failure.invalidRequest }
        let now = Date().timeIntervalSince1970
        guard expiresAt > now, expiresAt <= now + 7 * 24 * 3600 else { throw Failure.invalidRequest }
        return try stateLock.withLock {
            guard !inbox.retired else { throw Failure.retired }
            // Do not purge idempotency evidence when the owner reads or when
            // context changes. Only explicit owner cleanup removes entries.
            if let old = inbox.entries.first(where: {
                $0.requestID == requestID && $0.sender.referencesSameSigningIdentity(as: requester)
            }) {
                guard try Self.canonicalPayload(old.payload) == Self.canonicalPayload(payload),
                      old.expiresAt == expiresAt else { throw Failure.conflictingRequest }
                return receipt(old)
            }
            let entry = Entry(id: UUID().uuidString, requestID: requestID,
                sender: requester.publicIdentitySnapshot(), payload: payload,
                expiresAt: expiresAt, acceptedAt: now)
            inbox.entries.append(entry)
            return receipt(entry)
        }
    }
    /// Trusted host routing metadata. It is not exposed by Meddle to senders.
    public var contactDeliveryContext: Context { stateLock.withLock { inbox.context } }

    /// A registry may disclose only references explicitly issued to the caller's
    /// proven key. Routes, inbox contents and other grants stay private.
    public func sharedReferences(requester: Identity) async throws -> [ValueType] {
        guard await verifyRequesterIdentityControl(requester) else { throw Failure.denied }
        let (contracts, title) = stateLock.withLock { (inbox.retired ? [] : (inbox.issuedContracts ?? []), inbox.label) }
        return try contracts.filter { $0.subject.referencesSameSigningIdentity(as: requester) && $0.temporalStatus() == .active }.map {
            .object(["title": .string(title), "ownerUUID": .string(storedOwnerIdentity.uuid), "endpointID": .string(uuid),
                "endpointCell": .string("cell:///Contact-" + uuid),
                "contactAgreement": try Self.encode($0)])
        }
    }

    /// Registry hint only: prevents silently replacing a known revoked,
    /// expired or retired address with an unrelated external delivery route.
    /// Cell authorization continues to be enforced by GeneralCell contracts.
    public func hasUnavailableSharedReference(requester: Identity) async throws -> Bool {
        guard await verifyRequesterIdentityControl(requester) else { throw Failure.denied }
        return stateLock.withLock {
            let belongs: (Contract) -> Bool = { $0.subject.referencesSameSigningIdentity(as: requester) }
            return (inbox.revokedContracts ?? []).contains(where: belongs)
                || (inbox.issuedContracts ?? []).contains { belongs($0) && (inbox.retired || $0.temporalStatus() != .active) }
        }
    }

    private func receipt(_ entry: Entry) -> ValueType {
        // Never disclose the owner's context or routes to a posting subject,
        // and never label enqueue as transport delivery or recipient receipt.
        .object(["ticketId": .string(entry.id), "status": .string("queued"),
                 "contactCell": .string("cell:///Contact-" + uuid), "requestID": .string(entry.requestID)])
    }
    private func snapshot() -> ValueType {
        stateLock.withLock {
            let now = Date().timeIntervalSince1970
            return .object(["id": .string(uuid), "reference": .string("cell:///Contact-" + uuid),
                "label": .string(inbox.label), "context": .string(inbox.context.rawValue),
                "retired": .bool(inbox.retired),
                "access": .list((inbox.issuedContracts ?? []).filter { $0.temporalStatus() == .active }.map {
                    .object(["id": .string($0.subject.uuid), "displayName": .string($0.subject.displayName),
                        "contractID": .string($0.uuid), "expiresAt": .float($0.expiresAt)])
                }), "entries": .list(inbox.entries.filter { $0.expiresAt > now }.map {
                    .object(["id": .string($0.id), "requestID": .string($0.requestID),
                        "sender": .identity($0.sender), "payload": $0.payload,
                        "expiresAt": .float($0.expiresAt), "status": .string("queued")])
                })])
        }
    }
    private static func fields(_ names: [String], type: String = "string") -> Object {
        Dictionary(uniqueKeysWithValues: names.map { ($0, ExploreContract.schema(type: type)) })
    }
    /// The payload is deliberately opaque to contact routing. Size, expiry,
    /// author and authorization are enforced; chat interprets its own body.
    private static var payloadSchema: ValueType {
        ExploreContract.unknownSchema(description: "Opaque JSON ValueType, at most 32 KiB encoded; never interpreted as authority.")
    }
    public static func inputSchema(_ key: String) -> ValueType {
        var properties: Object = [:]
        var required: [String] = []
        switch key {
        case "contact.request":
            properties = fields(["requestID"])
            properties["expiresAt"] = ExploreContract.schema(type: "float")
            properties["payload"] = payloadSchema
            properties["agreement"] = signedContractSchema
            required = ["requestID", "expiresAt", "payload"]
        case "settings.update": properties = fields(["label", "context"])
        case "agreement.issue":
            properties["subject"] = ExploreContract.oneOfSchema(options: [ExploreContract.schema(type: "identity"), ExploreContract.objectSchema()], description: "Public identity with signing key; never a private key.")
            properties["durationSeconds"] = ExploreContract.schema(type: "integer")
            required = ["subject", "durationSeconds"]
        case "agreement.accept": return signedContractSchema
        case "agreement.revoke":
            properties = fields(["cellUUID", "subjectUUID", "contractUUID", "agreementUUID", "domain", "nonce", "signature"])
            properties["issuedAt"] = ExploreContract.schema(type: "float")
            required = Array(properties.keys)
        case "access.revoke": properties = fields(["subjectUUID"]); required = ["subjectUUID"]
        default: break
        }
        return ExploreContract.objectSchema(properties: properties, requiredKeys: required.sorted(), description: summary(key))
    }
    private static var signedContractSchema: ValueType {
        var properties = fields(["uuid", "domain", "targetCellUUID", "signaturePurpose", "signature"])
        properties["issuedAt"] = ExploreContract.schema(type: "float")
        properties["expiresAt"] = ExploreContract.schema(type: "float")
        for key in ["agreement", "issuer", "subject"] { properties[key] = ExploreContract.objectSchema() }
        return ExploreContract.objectSchema(properties: properties, requiredKeys: Array(properties.keys).sorted(),
            description: "Canonical signed Contract v2; signature, exact Cell, domain, subject and post-only grants are independently verified.")
    }
    public static func outputSchema(_ key: String) -> ValueType {
        if key == "agreement.issue" { return signedContractSchema }
        if key == "contact.request" {
            return ExploreContract.objectSchema(properties: fields(["ticketId", "status", "contactCell", "requestID"]), requiredKeys: ["ticketId", "status", "contactCell", "requestID"])
        }
        if ["agreement.accept", "agreement.revoke", "access.revoke", "settings.update", "retire", "inbox.clear"].contains(key) {
            return ExploreContract.objectSchema(properties: fields(["status"]), requiredKeys: ["status"])
        }
        var properties = fields(["id", "reference", "label", "context"])
        properties["retired"] = ExploreContract.schema(type: "bool")
        var entry = fields(["id", "requestID", "status"])
        entry["sender"] = ExploreContract.schema(type: "identity")
        entry["payload"] = payloadSchema
        entry["expiresAt"] = ExploreContract.schema(type: "float")
        properties["entries"] = ExploreContract.listSchema(item: ExploreContract.objectSchema(properties: entry, requiredKeys: Array(entry.keys).sorted()))
        var access = fields(["id", "displayName", "contractID"])
        access["expiresAt"] = ExploreContract.schema(type: "float")
        properties["access"] = ExploreContract.listSchema(item: ExploreContract.objectSchema(properties: access, requiredKeys: Array(access.keys).sorted()))
        return ExploreContract.objectSchema(properties: properties, requiredKeys: Array(properties.keys).sorted(), description: "Owner-only contact settings, grants and non-expired inbox entries.")
    }

    private static func summary(_ key: String) -> String {
        switch key {
        case "contact.request": return "Post to this exact contact cell using a subject-bound Agreement; does not grant chat membership."
        case "agreement.issue": return "Owner signs a post-only grant for one subject and this cell."
        case "agreement.accept": return "Present an owner-signed exact-cell grant as its subject."
        case "agreement.revoke": return "Apply an owner-signed revocation for this cell."
        default: return "Owner-only contact-cell administration."
        }
    }
    private static func canonicalPayload(_ value: ValueType) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func encode<T: Encodable>(_ value: T) throws -> ValueType {
        try JSONDecoder().decode(ValueType.self, from: JSONEncoder().encode(value))
    }
    private static func decode<T: Decodable>(_ value: ValueType, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}
