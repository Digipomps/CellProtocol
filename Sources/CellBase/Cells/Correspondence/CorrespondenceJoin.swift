// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum CorrespondenceJoinCode {
    /// UTF-8 cell UUID, UTF-8 invitation ID, raw signing key, raw X25519 key, concatenated in this order.
    public static func code(cellUUID: String, invitationID: String, signingPublicKey: Data, agreementPublicKey: Data) -> String {
        let digest = SHA256.hash(data: Data(cellUUID.utf8) + Data(invitationID.utf8) + signingPublicKey + agreementPublicKey)
        let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", number % 1_000_000)
    }
}

public struct CorrespondenceJoinInvitation: Codable, CanonicalPayloadSignable {
    public var version = 1
    public var purpose = "haven.correspondence.join.invitation.v1"
    public var cellUUID: String
    public var invitationID: String
    public var issuedAt: TimeInterval
    public var expiresAt: TimeInterval
    public var signature: Data?
    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["signature"])
    }
    public static func signed(cellUUID: String, owner: Identity, invitationID: String = UUID().uuidString,
                              issuedAt: Date = Date(), expiresAt: Date) async throws -> Self {
        var value = Self(cellUUID: cellUUID, invitationID: invitationID, issuedAt: issuedAt.timeIntervalSince1970,
                         expiresAt: expiresAt.timeIntervalSince1970)
        guard let signature = try await owner.sign(data: value.canonicalPayloadData()) else { throw ContractError.signingFailed }
        value.signature = signature
        return value
    }
}

public struct CorrespondenceJoinRequest: Codable, CanonicalPayloadSignable {
    public var version = 1
    public var purpose = "haven.correspondence.join.request.v1"
    public var invitation: CorrespondenceJoinInvitation
    public var identityUUID: String
    public var signingPublicKey: Data
    public var signingAlgorithm: CurveAlgorithm
    public var signingCurve: CurveType
    public var agreementPublicKey: Data
    public var requestedAt: TimeInterval
    public var signature: Data?
    public var identity: Identity {
        ChatInvitationProofUtility.identity(from: IdentityPublicKeyDescriptor(uuid: identityUUID, displayName: nil,
            publicKey: signingPublicKey, algorithm: signingAlgorithm, curveType: signingCurve), keyAgreementKey: agreementPublicKey)
    }
    public func canonicalPayloadData() throws -> Data {
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["signature"])
    }
    public static func signed(invitation: CorrespondenceJoinInvitation, invitee: Identity, at: Date = Date()) async throws -> Self {
        let descriptor = try ChatInvitationProofUtility.signingDescriptor(for: invitee)
        var value = Self(invitation: invitation, identityUUID: descriptor.uuid, signingPublicKey: descriptor.publicKey,
            signingAlgorithm: descriptor.algorithm, signingCurve: descriptor.curveType,
            agreementPublicKey: invitee.publicKeyAgreementSecureKey?.compressedKey ?? Data(), requestedAt: at.timeIntervalSince1970)
        guard let signature = try await invitee.sign(data: value.canonicalPayloadData()) else { throw ContractError.signingFailed }
        value.signature = signature
        return value
    }
    func validate(cellUUID: String, owner: Identity, requester: Identity, now: Date = Date()) async -> String? {
        let time = now.timeIntervalSince1970
        guard version == 1, purpose == "haven.correspondence.join.request.v1",
              invitation.version == 1, invitation.purpose == "haven.correspondence.join.invitation.v1",
              invitation.cellUUID == cellUUID, UUID(uuidString: invitation.invitationID) != nil,
              UUID(uuidString: identityUUID) != nil,
              invitation.issuedAt.isFinite, invitation.expiresAt.isFinite, requestedAt.isFinite,
              invitation.expiresAt > invitation.issuedAt,
              invitation.expiresAt - invitation.issuedAt <= 7 * 86400,
              invitation.issuedAt <= time + 5 else { return "invitation.invalid" }
        guard invitation.expiresAt > time else { return "invitation.expired" }
        guard abs(requestedAt - time) <= 300, requestedAt >= invitation.issuedAt - 5,
              identityUUID != owner.uuid, agreementPublicKey.count == 32,
              requester.uuid == identityUUID,
              requester.signingPublicKeyFingerprint == identity.signingPublicKeyFingerprint,
              requester.publicKeyAgreementSecureKey?.compressedKey == agreementPublicKey,
              let ownerDescriptor = try? ChatInvitationProofUtility.signingDescriptor(for: owner),
              let invitationSignature = invitation.signature,
              let invitationBytes = try? invitation.canonicalPayloadData(),
              IdentityPublicKeySignatureVerifier.verify(signature: invitationSignature, messageData: invitationBytes, descriptor: ownerDescriptor),
              let signature, let bytes = try? canonicalPayloadData(),
              let descriptor = try? ChatInvitationProofUtility.signingDescriptor(for: identity),
              IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: bytes, descriptor: descriptor)
        else { return "join.proof.invalid" }
        return nil
    }
}

public struct CorrespondenceJoinDecision: Codable {
    public var requestID: String
    public var approve: Bool
    public var contract: Contract?
    public init(requestID: String, approve: Bool, contract: Contract? = nil) {
        self.requestID = requestID; self.approve = approve; self.contract = contract
    }
}
public struct CorrespondenceJoinResult: Codable {
    public var requestID: String
    public var status: String
    public var code: String?
    public var contract: Contract?
}
public struct CorrespondenceJoinPending: Codable {
    public var requestID: String
    public var invitationID: String
    public var identityUUID: String
    public var signingPublicKey: Data
    public var signingAlgorithm: CurveAlgorithm
    public var signingCurve: CurveType
    public var agreementPublicKey: Data
    public var receivedAt: TimeInterval
}
struct CorrespondenceJoinRecord: Codable {
    var requestID: String
    var request: CorrespondenceJoinRequest
    var receivedAt: TimeInterval
    var status: String
    var contract: Contract?
}
final class CorrespondenceJoinLedger: Codable {
    private let lock = NSLock()
    private var records: [String: CorrespondenceJoinRecord] = [:]
    init() {}
    required init(from decoder: Decoder) throws {
        let restored = try CorrespondenceIdentityStateCodec.decoderRestoringIdentityFallbacks(decoder)
        records = try restored.singleValueContainer().decode([String: CorrespondenceJoinRecord].self)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let bytes = try JSONEncoder().encode(lock.withLock { records })
        let object = try JSONSerialization.jsonObject(with: bytes)
        let safe = try JSONSerialization.data(withJSONObject: CorrespondenceIdentityStateCodec.compact(object), options: [.sortedKeys])
        try container.encode(JSONDecoder().decode(ValueType.self, from: safe))
    }
    func record(id: String) -> CorrespondenceJoinRecord? { lock.withLock { records[id] } }
    func insert(_ request: CorrespondenceJoinRequest, now: Date) -> CorrespondenceJoinResult {
        lock.withLock {
            guard !records.values.contains(where: { $0.request.invitation.invitationID == request.invitation.invitationID }) else {
                return CorrespondenceJoinResult(requestID: "", status: "rejected", code: "invitation.used")
            }
            guard request.invitation.expiresAt > now.timeIntervalSince1970 else {
                return CorrespondenceJoinResult(requestID: "", status: "rejected", code: "invitation.expired")
            }
            let id = UUID().uuidString
            records[id] = CorrespondenceJoinRecord(requestID: id, request: request, receivedAt: now.timeIntervalSince1970, status: "pending")
            return CorrespondenceJoinResult(requestID: id, status: "pending")
        }
    }
    func pending(now: Date) -> [CorrespondenceJoinPending] {
        lock.withLock {
            records.values.filter { $0.status == "pending" && $0.request.invitation.expiresAt > now.timeIntervalSince1970 }
                .sorted { $0.receivedAt < $1.receivedAt }.map {
                    CorrespondenceJoinPending(requestID: $0.requestID, invitationID: $0.request.invitation.invitationID,
                        identityUUID: $0.request.identityUUID, signingPublicKey: $0.request.signingPublicKey,
                        signingAlgorithm: $0.request.signingAlgorithm, signingCurve: $0.request.signingCurve,
                        agreementPublicKey: $0.request.agreementPublicKey, receivedAt: $0.receivedAt)
                }
        }
    }
    func result(id: String, requester: Identity, now: Date) -> CorrespondenceJoinResult? {
        lock.withLock {
            guard let record = records[id], requester.uuid == record.request.identityUUID,
                  requester.signingPublicKeyFingerprint == record.request.identity.signingPublicKeyFingerprint else { return nil }
            let expired = record.status == "pending" && record.request.invitation.expiresAt <= now.timeIntervalSince1970
            return CorrespondenceJoinResult(requestID: id, status: expired ? "expired" : record.status, contract: record.contract)
        }
    }
    func decide(_ decision: CorrespondenceJoinDecision, now: Date) -> CorrespondenceJoinResult? {
        lock.withLock {
            guard var record = records[decision.requestID], record.status == "pending" else { return nil }
            if record.request.invitation.expiresAt <= now.timeIntervalSince1970 {
                record.status = "expired"
            } else { record.status = decision.approve ? "approved" : "denied"; record.contract = decision.contract }
            records[decision.requestID] = record
            return CorrespondenceJoinResult(requestID: record.requestID, status: record.status)
        }
    }
}
