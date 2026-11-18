// SPDX-License-Identifier: Apache-2.0
import Foundation
import Crypto

public enum ContactOperationFailure: String, Error, Sendable {
    case invalidBinding, unsupportedSigner, unsupportedTransport, staleIntent
    case expired, cancelled, routeChanged, channelClosed, signingDenied
    case remoteOperationFailed, missingReceipt, invalidReceipt, timeout
}

public struct ContactInboxReferenceV1: Codable, Sendable {
    public static let profileName = "org.haven.contact-inbox-reference.v1"
    public let profile: String
    public let logicalEndpoint: String
    public let cellUUID: String
    public let identityDomain: String
    public let owner: BridgeChannelAuthentication.PublicIdentity
    public let subject: BridgeChannelAuthentication.PublicIdentity
    public let contractDigest: Data
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let signature: Data

    fileprivate struct Unsigned: Codable {
        let profile: String
        let logicalEndpoint: String
        let cellUUID: String
        let identityDomain: String
        let owner: BridgeChannelAuthentication.PublicIdentity
        let subject: BridgeChannelAuthentication.PublicIdentity
        let contractDigest: Data
        let issuedAtMilliseconds: Int64
        let expiresAtMilliseconds: Int64
    }

    fileprivate var unsigned: Unsigned {
        .init(profile: profile, logicalEndpoint: logicalEndpoint, cellUUID: cellUUID,
              identityDomain: identityDomain, owner: owner, subject: subject,
              contractDigest: contractDigest, issuedAtMilliseconds: issuedAtMilliseconds,
              expiresAtMilliseconds: expiresAtMilliseconds)
    }
    fileprivate func signingData() throws -> Data {
        var data = Data((Self.profileName + "\n").utf8)
        data.append(try ContactReferenceCodec.encode(unsigned))
        return data
    }
}

/// Created only by the verifier. Never deserialize this local decision or keep
/// a mutable Agreement/Identity as its authority snapshot.
public struct VerifiedContactBinding: Sendable {
    public let referenceBytes: Data
    public let contractBytes: Data
    public let bindingDigest: Data
    public let reference: ContactInboxReferenceV1
    public var expiresAt: Date {
        Date(timeIntervalSince1970: Double(reference.expiresAtMilliseconds) / 1000)
    }
    fileprivate init(referenceBytes: Data, contractBytes: Data, reference: ContactInboxReferenceV1) {
        self.referenceBytes = referenceBytes
        self.contractBytes = contractBytes
        self.reference = reference
        bindingDigest = Data(SHA256.hash(data: referenceBytes))
    }
}

public enum ContactReferenceCodec {
    public static let maximumReferenceBytes = 16 * 1024
    public static let maximumContractBytes = 64 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// Canonical equality also rejects duplicate/unknown JSON members, which
    /// JSONDecoder alone would otherwise ignore. There is no partial decode.
    public static func decode<T: Codable>(_ type: T.Type, from data: Data,
                                          maximumBytes: Int) throws -> T {
        guard maximumBytes > 0, data.count <= maximumBytes else { throw ContactOperationFailure.invalidBinding }
        let value = try JSONDecoder().decode(type, from: data)
        guard try encode(value) == data else { throw ContactOperationFailure.invalidBinding }
        return value
    }

    // Internal fixture/source scaffolding only. The application owner-export
    // API still needs its own final local-signing/commit admission; do not expose
    // this ordinary-signing helper as that API.
    static func issue(contractBytes: Data, endpoint: URL, owner: Identity,
                             issuedAt: Date, expiresAt: Date) async throws -> Data {
        let contract = try decode(Contract.self, from: contractBytes, maximumBytes: maximumContractBytes)
        let ownerDescriptor = try BridgeChannelAuthentication.PublicIdentity(owner)
        let subject = try BridgeChannelAuthentication.PublicIdentity(contract.subject)
        guard let cellUUID = contract.targetCellUUID else { throw ContactOperationFailure.invalidBinding }
        try validateEndpoint(endpoint.absoluteString, cellUUID: cellUUID)
        try await validateContract(contract, owner: ownerDescriptor, subject: subject,
                                   cellUUID: cellUUID, now: issuedAt)
        let issued = try milliseconds(issuedAt)
        let expiry = try milliseconds(expiresAt)
        guard expiry > issued, Double(issued) / 1000 >= contract.issuedAt,
              Double(expiry) / 1000 <= contract.expiresAt else { throw ContactOperationFailure.invalidBinding }
        let unsigned = ContactInboxReferenceV1(profile: ContactInboxReferenceV1.profileName,
            logicalEndpoint: endpoint.absoluteString, cellUUID: cellUUID, identityDomain: ContactInboxCell.domain,
            owner: ownerDescriptor, subject: subject, contractDigest: try contract.signedContentDigest(),
            issuedAtMilliseconds: issued, expiresAtMilliseconds: expiry, signature: Data())
        let signingData = try unsigned.signingData()
        guard let signature = try await owner.sign(data: signingData),
              IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: signingData,
                                                        identity: ownerDescriptor.makeIdentity()) else {
            throw ContactOperationFailure.signingDenied
        }
        let signed = ContactInboxReferenceV1(profile: unsigned.profile, logicalEndpoint: unsigned.logicalEndpoint,
            cellUUID: unsigned.cellUUID, identityDomain: unsigned.identityDomain, owner: ownerDescriptor,
            subject: subject, contractDigest: unsigned.contractDigest, issuedAtMilliseconds: issued,
            expiresAtMilliseconds: expiry, signature: signature)
        let bytes = try encode(signed)
        guard bytes.count <= maximumReferenceBytes else { throw ContactOperationFailure.invalidBinding }
        return bytes
    }

    /// expectedOwner/approvedEndpoint MUST come from host policy/independently
    /// verified relationship, never be copied from this untrusted reference.
    public static func verify(referenceBytes: Data, contractBytes: Data,
        expectedOwner: BridgeChannelAuthentication.PublicIdentity,
        expectedSubject: BridgeChannelAuthentication.PublicIdentity,
        approvedEndpoint: URL, now: Date = Date()) async throws -> VerifiedContactBinding {
        let reference = try decode(ContactInboxReferenceV1.self, from: referenceBytes,
                                   maximumBytes: maximumReferenceBytes)
        let contract = try decode(Contract.self, from: contractBytes, maximumBytes: maximumContractBytes)
        try expectedOwner.validate(); try expectedSubject.validate()
        try validateEndpoint(reference.logicalEndpoint, cellUUID: reference.cellUUID)
        guard reference.profile == ContactInboxReferenceV1.profileName,
              reference.identityDomain == ContactInboxCell.domain,
              reference.logicalEndpoint == approvedEndpoint.absoluteString,
              reference.owner == expectedOwner, reference.subject == expectedSubject,
              reference.contractDigest.count == 32,
              reference.contractDigest == (try contract.signedContentDigest()),
              reference.signature.count > 0, reference.signature.count <= 512,
              reference.expiresAtMilliseconds > reference.issuedAtMilliseconds,
              Double(reference.issuedAtMilliseconds) / 1000 >= contract.issuedAt,
              Double(reference.expiresAtMilliseconds) / 1000 <= contract.expiresAt,
              IdentityPublicKeySignatureVerifier.verify(signature: reference.signature,
                  messageData: try reference.signingData(), identity: expectedOwner.makeIdentity()) else {
            throw ContactOperationFailure.invalidBinding
        }
        let current = try milliseconds(now)
        guard reference.issuedAtMilliseconds <= current, current < reference.expiresAtMilliseconds else {
            throw ContactOperationFailure.expired
        }
        try await validateContract(contract, owner: expectedOwner, subject: expectedSubject,
                                   cellUUID: reference.cellUUID, now: now)
        return VerifiedContactBinding(referenceBytes: referenceBytes, contractBytes: contractBytes, reference: reference)
    }

    static func validateContract(_ contract: Contract, owner: BridgeChannelAuthentication.PublicIdentity,
        subject: BridgeChannelAuthentication.PublicIdentity, cellUUID: String, now: Date) async throws {
        let current = now.timeIntervalSince1970
        guard current.isFinite, contract.issuedAt <= current, current < contract.expiresAt,
              contract.targetCellUUID == cellUUID, contract.signaturePurpose == "haven.contract.admission.v2",
              contract.domain == ContactInboxCell.domain,
              try BridgeChannelAuthentication.PublicIdentity(contract.issuer) == owner,
              try BridgeChannelAuthentication.PublicIdentity(contract.agreement.owner) == owner,
              try BridgeChannelAuthentication.PublicIdentity(contract.subject) == subject,
              contract.agreement.conditions.isEmpty, contract.agreement.grants.count == 1,
              contract.agreement.grants[0].keypath == "contact.request",
              contract.agreement.grants[0].permission.fullPermissionString == "-w------",
              await contract.verifySignature(now: now) else { throw ContactOperationFailure.invalidBinding }
    }

    static func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1000
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { throw ContactOperationFailure.invalidBinding }
        return Int64(value.rounded(.down))
    }

    static func validateEndpoint(_ raw: String, cellUUID: String) throws {
        guard UUID(uuidString: cellUUID)?.uuidString == cellUUID, cellUUID.utf8.count == 36,
              let parts = URLComponents(string: raw), parts.scheme == "cell",
              let host = parts.host, !host.isEmpty, host == host.lowercased(), !host.hasSuffix("."),
              host != "localhost", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              let port = parts.port, (1...65535).contains(port),
              parts.path == "/Contact-" + cellUUID, parts.percentEncodedPath == parts.path,
              parts.string == raw, raw.utf8.count <= 1024 else { throw ContactOperationFailure.invalidBinding }
    }
}
