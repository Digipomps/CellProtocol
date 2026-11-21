import Foundation

/// Explicit join, independent of recording consent. Binds the encryption key
/// to the same signing principal proven by the authenticated bridge.
public struct MeetingJoinRequest: Codable, Sendable {
    public let domain: String
    public let invitation: MeetingNearbyInvitation
    public let admission: Contract
    public let signer: IdentityPublicKeyDescriptor
    public let agreementKey: Data
    public private(set) var signature: Data
    public var identity: Identity { ChatInvitationProofUtility.identity(from: signer, keyAgreementKey: agreementKey) }
    public static func make(invitation: MeetingNearbyInvitation, admission: Contract, identity: Identity) async throws -> Self {
        guard let key = identity.publicKeyAgreementSecureKey?.compressedKey, key.count == 32 else { throw MeetingSessionError.forbidden }
        var signer = try ChatInvitationProofUtility.signingDescriptor(for: identity); signer.displayName = nil
        var value = Self(domain: "haven.meeting.join.v1", invitation: invitation, admission: admission,
                         signer: signer, agreementKey: key, signature: Data())
        value.signature = try await MeetingEvidence.sign(value, identity: identity)
        return value
    }
    public func verify(owner: Identity, requester: Identity, cellID: String, now: Date = Date()) throws {
        guard domain == "haven.meeting.join.v1", invitation.cellID == cellID,
              admission.targetCellUUID == cellID, agreementKey.count == 32,
              identity.referencesSameSigningIdentity(as: requester),
              MeetingEvidence.verify(self, signature: signature, identity: identity) else { throw MeetingSessionError.forbidden }
        try invitation.verify(authenticatedPeer: owner, localRecipient: requester, now: now)
    }
}
