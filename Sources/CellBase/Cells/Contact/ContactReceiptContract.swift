// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Untrusted wire data until the actual Bridge owner completes its registered
/// RPC. A standalone ContactInboxCell cannot assert host persistence.
public struct ContactHostReceiptV1: Codable, Sendable {
    public static let profileName = "org.haven.contact-inbox-host-receipt.v1"
    public let profile: String
    public let ticketId: String
    public let status: String
    public let requestID: String
    public let bindingDigest: Data
    public let logicalEndpoint: String
    public let cellUUID: String
    public let identityDomain: String
    public let ownerSigningFingerprint: String
    public let subjectSigningFingerprint: String
    public let persistence: String

    /// Receiving host only: invoke after encrypted save and state publication.
    /// Construction is data, not evidence that either happened.
    public init(ticketId: String, requestID: String, binding: VerifiedContactBinding) {
        profile = Self.profileName; self.ticketId = ticketId; status = "queued"
        self.requestID = requestID; bindingDigest = binding.bindingDigest
        logicalEndpoint = binding.reference.logicalEndpoint; cellUUID = binding.reference.cellUUID
        identityDomain = binding.reference.identityDomain
        ownerSigningFingerprint = binding.reference.owner.makeIdentity().signingPublicKeyFingerprint ?? ""
        subjectSigningFingerprint = binding.reference.subject.makeIdentity().signingPublicKeyFingerprint ?? ""
        persistence = "host_encrypted_commit"
    }

    func validate(for snapshot: ContactOperationSnapshot) throws {
        let expected = ContactHostReceiptV1(ticketId: ticketId, requestID: snapshot.requestID, binding: snapshot.binding)
        guard !ticketId.isEmpty, ticketId.utf8.count <= 128,
              try ContactReferenceCodec.encode(self) == ContactReferenceCodec.encode(expected) else {
            throw ContactOperationFailure.invalidReceipt
        }
    }
}
