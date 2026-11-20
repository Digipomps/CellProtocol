import Foundation

/// Wire evidence contains public keys only. A host cannot create another person's
/// approval: the explicit client action must call `approve` with its own vault.
public struct MeetingSignedConsent: Codable, Equatable, Sendable {
    public let domain: String
    public let cellID: String
    public let operationID: UUID
    public let reference: MeetingPlanReference
    public let plan: MeetingPlan
    public let signer: IdentityPublicKeyDescriptor
    public let agreementKey: Data
    public let issuedAt: Date
    public let expiresAt: Date
    public private(set) var signature: Data

    public var identity: Identity { ChatInvitationProofUtility.identity(from: signer, keyAgreementKey: agreementKey) }
    public var principal: MeetingPrincipal { get throws { try MeetingEvidence.principal(identity) } }

    public static func approve(cellID: String, operationID: UUID = UUID(), reference: MeetingPlanReference,
                               plan: MeetingPlan, identity: Identity, now: Date = Date()) async throws -> Self {
        try plan.validate()
        let principal = try MeetingEvidence.principal(identity)
        guard !cellID.isEmpty, plan.participants.contains(principal),
              let key = identity.publicKeyAgreementSecureKey?.compressedKey, key.count == 32 else {
            throw MeetingSessionError.forbidden
        }
        var descriptor = try ChatInvitationProofUtility.signingDescriptor(for: identity)
        descriptor.displayName = nil
        var result = Self(domain: "haven.meeting.consent.v1", cellID: cellID, operationID: operationID,
                          reference: reference, plan: plan, signer: descriptor, agreementKey: key,
                          issuedAt: now, expiresAt: now.addingTimeInterval(plan.consentLifetime), signature: Data())
        result.signature = try await MeetingEvidence.sign(result, identity: identity)
        return result
    }

    public func verify(cellID: String, reference: MeetingPlanReference, plan: MeetingPlan, at time: Date) throws {
        try plan.validate()
        guard domain == "haven.meeting.consent.v1", self.cellID == cellID, self.reference == reference,
              self.plan == plan, agreementKey.count == 32, plan.participants.contains(try principal),
              [issuedAt, expiresAt, time].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              issuedAt <= time, expiresAt > time, expiresAt.timeIntervalSince(issuedAt) <= plan.consentLifetime,
              MeetingEvidence.verify(self, signature: signature, identity: identity) else { throw MeetingSessionError.forbidden }
    }
}

/// Sent over an already authenticated private scanner connection, never lobby or
/// advertisement. This grants neither membership nor recording permission.
public struct MeetingNearbyInvitation: Codable, Equatable, Sendable {
    public let domain: String
    public let nonce: UUID
    public let cellID: String
    public let endpoint: String
    public let inviter: IdentityPublicKeyDescriptor
    public let recipient: MeetingPrincipal
    public let issuedAt: Date
    public let expiresAt: Date
    public private(set) var signature: Data

    public static func make(cellID: String, endpoint: String, inviter: Identity, recipient: MeetingPrincipal,
                            now: Date = Date()) async throws -> Self {
        guard validEndpoint(endpoint, cellID: cellID) else { throw MeetingSessionError.invalidPlan }
        var descriptor = try ChatInvitationProofUtility.signingDescriptor(for: inviter); descriptor.displayName = nil
        var value = Self(domain: "haven.meeting.nearby-invitation.v1", nonce: UUID(), cellID: cellID,
                         endpoint: endpoint, inviter: descriptor, recipient: recipient,
                         issuedAt: now, expiresAt: now.addingTimeInterval(300), signature: Data())
        value.signature = try await MeetingEvidence.sign(value, identity: inviter)
        return value
    }
    public func verify(authenticatedPeer: Identity, localRecipient: Identity, now: Date = Date()) throws {
        let sender = ChatInvitationProofUtility.identity(from: inviter)
        guard domain == "haven.meeting.nearby-invitation.v1", validEndpoint(endpoint, cellID: cellID),
              authenticatedPeer.referencesSameSigningIdentity(as: sender),
              recipient == (try MeetingEvidence.principal(localRecipient)),
              [issuedAt, expiresAt, now].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              issuedAt <= now, now < expiresAt, expiresAt.timeIntervalSince(issuedAt) <= 300,
              MeetingEvidence.verify(self, signature: signature, identity: sender) else { throw MeetingSessionError.forbidden }
    }
    private static func validEndpoint(_ endpoint: String, cellID: String) -> Bool {
        guard UUID(uuidString: cellID) != nil, let url = URLComponents(string: endpoint), url.scheme == "cell",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return url.path == "/" + cellID
    }
    private func validEndpoint(_ endpoint: String, cellID: String) -> Bool { Self.validEndpoint(endpoint, cellID: cellID) }
}

public enum MeetingEvidence {
    public static func principal(_ identity: Identity) throws -> MeetingPrincipal {
        guard let fingerprint = identity.signingPublicKeyFingerprint else { throw MeetingSessionError.forbidden }
        return MeetingPrincipal(id: identity.uuid, signingKeyFingerprint: fingerprint)
    }
    public static func bytes<T: Encodable>(_ value: T) throws -> Data { try CanonicalPayloadEncoder.data(for: value) }
    public static func hash<T: Encodable>(_ value: T) throws -> String { FlowHasher.sha256Hex(try bytes(value)) }
    static func sign<T: Encodable>(_ value: T, identity: Identity) async throws -> Data {
        guard let signature = try await identity.sign(data: CanonicalPayloadEncoder.data(for: value, excludingTopLevelKeys: ["signature"])) else {
            throw MeetingSessionError.forbidden
        }
        return signature
    }
    static func verify<T: Encodable>(_ value: T, signature: Data, identity: Identity) -> Bool {
        guard let data = try? CanonicalPayloadEncoder.data(for: value, excludingTopLevelKeys: ["signature"]) else { return false }
        return IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: data, identity: identity)
    }
}
