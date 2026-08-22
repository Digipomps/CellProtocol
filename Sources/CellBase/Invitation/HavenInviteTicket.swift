// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  HavenInviteTicket.swift
//  CellProtocol
//
//  The invitation itself: a small signed statement that says "this person
//  invited you, at this time, and it stops being valid then".
//
//  This lives in CellBase, not in the app, because the invitee's side runs
//  somewhere else entirely — a landing page in CellScaffold, on a device that
//  has never seen HAVEN. Two implementations of "is this invitation valid"
//  would drift apart within a month; one shared type cannot.
//
//  What the ticket is NOT is just as important. It carries no grant, no key,
//  no access to anything the issuer holds. Its capability set is "create your
//  own entity" and "send a contact request back to me", and nothing else.
//
//  The wire format uses short coding keys and epoch seconds on purpose. A
//  self-contained ticket travels inside a URL, and every field name is paid
//  for twice — once in base64 expansion, once in whatever the recipient's mail
//  client does to a long line.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - Proof

/// A detached signature over a canonical payload. Shared by invitations and
/// residency receipts — both need the same "who signed this, with what" record.
public struct HavenSignatureProof: Codable, Equatable, Sendable {
    public var type: String
    public var byIdentityUUID: String
    public var algorithm: CurveAlgorithm
    public var curveType: CurveType
    public var signature: Data?

    public init(
        type: String = "signature",
        byIdentityUUID: String,
        algorithm: CurveAlgorithm,
        curveType: CurveType,
        signature: Data? = nil
    ) {
        self.type = type
        self.byIdentityUUID = byIdentityUUID
        self.algorithm = algorithm
        self.curveType = curveType
        self.signature = signature
    }

    public enum CodingKeys: String, CodingKey {
        case type = "ty"
        case byIdentityUUID = "by"
        case algorithm = "al"
        case curveType = "cv"
        case signature = "sg"
    }
}

// MARK: - Ticket

public struct HavenInviteTicket: Codable, Equatable, Sendable, CanonicalPayloadSignable {

    public static let schema = "haven.invite.ticket.v1"
    /// Exactly what this link permits. Anything not listed here, it does not do.
    public static let defaultCapabilities = [
        "create_own_entity",
        "send_contact_request_to_issuer"
    ]

    public var version: Int
    public var ticketID: String
    /// Everything a stranger's device needs to check the signature offline.
    public var issuer: IdentityPublicKeyDescriptor
    public var issuerDisplayName: String
    /// Where a contact request should be delivered back to. Empty means the
    /// issuer has no reachable endpoint yet, and the landing page says so
    /// rather than offering a reply that goes nowhere.
    public var issuerContactEndpoint: String?
    public var issuerEntityRef: String?
    /// Truncated hash of the endpoint this was addressed to. Lets the issuer
    /// confirm the link reached the intended person without the link itself
    /// carrying their address.
    public var audienceToken: String
    /// "email" or "phone".
    public var audienceKind: String
    /// Six characters a person can read aloud, and the key the scaffold
    /// resolves a short link on.
    public var humanCode: String
    /// First name only, so the landing page can greet without holding a record.
    public var greetingName: String?
    public var note: String?
    /// Epoch seconds. Ints rather than ISO strings: same meaning, ~40 fewer
    /// characters in a link that is already too long.
    public var createdAt: Int
    public var expiresAt: Int
    public var nonce: Data
    public var capabilities: [String]
    public var proof: HavenSignatureProof?

    public init(
        version: Int = 1,
        ticketID: String,
        issuer: IdentityPublicKeyDescriptor,
        issuerDisplayName: String,
        issuerContactEndpoint: String? = nil,
        issuerEntityRef: String? = nil,
        audienceToken: String,
        audienceKind: String,
        humanCode: String,
        greetingName: String? = nil,
        note: String? = nil,
        createdAt: Int,
        expiresAt: Int,
        nonce: Data,
        capabilities: [String] = HavenInviteTicket.defaultCapabilities,
        proof: HavenSignatureProof? = nil
    ) {
        self.version = version
        self.ticketID = ticketID
        self.issuer = issuer
        self.issuerDisplayName = issuerDisplayName
        self.issuerContactEndpoint = issuerContactEndpoint
        self.issuerEntityRef = issuerEntityRef
        self.audienceToken = audienceToken
        self.audienceKind = audienceKind
        self.humanCode = humanCode
        self.greetingName = greetingName
        self.note = note
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.capabilities = capabilities
        self.proof = proof
    }

    public enum CodingKeys: String, CodingKey {
        case version = "v"
        case ticketID = "t"
        case issuer = "is"
        case issuerDisplayName = "n"
        case issuerContactEndpoint = "ce"
        case issuerEntityRef = "er"
        case audienceToken = "au"
        case audienceKind = "ak"
        case humanCode = "hc"
        case greetingName = "gn"
        case note = "no"
        case createdAt = "ca"
        case expiresAt = "ea"
        case nonce = "nc"
        case capabilities = "cp"
        case proof = "pf"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        ticketID = try container.decode(String.self, forKey: .ticketID)
        issuer = try container.decode(IdentityPublicKeyDescriptor.self, forKey: .issuer)
        issuerDisplayName = try container.decode(String.self, forKey: .issuerDisplayName)
        issuerContactEndpoint = try container.decodeIfPresent(String.self, forKey: .issuerContactEndpoint)
        issuerEntityRef = try container.decodeIfPresent(String.self, forKey: .issuerEntityRef)
        audienceToken = try container.decode(String.self, forKey: .audienceToken)
        audienceKind = try container.decodeIfPresent(String.self, forKey: .audienceKind) ?? "email"
        humanCode = try container.decode(String.self, forKey: .humanCode)
        greetingName = try container.decodeIfPresent(String.self, forKey: .greetingName)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        createdAt = try container.decode(Int.self, forKey: .createdAt)
        expiresAt = try container.decode(Int.self, forKey: .expiresAt)
        nonce = try container.decodeIfPresent(Data.self, forKey: .nonce) ?? Data()
        // Absent means the default set, which is what every v1 ticket carries.
        // Encoding it only when it differs keeps the common link shorter.
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities)
            ?? HavenInviteTicket.defaultCapabilities
        proof = try container.decodeIfPresent(HavenSignatureProof.self, forKey: .proof)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(ticketID, forKey: .ticketID)
        try container.encode(issuer, forKey: .issuer)
        try container.encode(issuerDisplayName, forKey: .issuerDisplayName)
        try container.encodeIfPresent(issuerContactEndpoint, forKey: .issuerContactEndpoint)
        try container.encodeIfPresent(issuerEntityRef, forKey: .issuerEntityRef)
        try container.encode(audienceToken, forKey: .audienceToken)
        try container.encode(audienceKind, forKey: .audienceKind)
        try container.encode(humanCode, forKey: .humanCode)
        try container.encodeIfPresent(greetingName, forKey: .greetingName)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        if !nonce.isEmpty { try container.encode(nonce, forKey: .nonce) }
        if capabilities != HavenInviteTicket.defaultCapabilities {
            try container.encode(capabilities, forKey: .capabilities)
        }
        try container.encodeIfPresent(proof, forKey: .proof)
    }

    public func canonicalPayloadData() throws -> Data {
        // The excluded key is the *coded* name, not the property name.
        try CanonicalPayloadEncoder.data(for: self, excludingTopLevelKeys: ["pf"])
    }

    public var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
    public var expiryDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt)) }

    public func isExpired(at moment: Date = Date()) -> Bool {
        moment.timeIntervalSince1970 > TimeInterval(expiresAt)
    }

    /// True when the ticket promises a reply channel that actually exists.
    /// A capability with no receiver is a lie, and the composer must not
    /// advertise it.
    public var canReceiveContactRequest: Bool {
        capabilities.contains("send_contact_request_to_issuer")
            && (issuerContactEndpoint?.isEmpty == false)
    }
}

// MARK: - Links

public enum HavenInviteLink {

    public enum Failure: Error, CustomStringConvertible, Sendable {
        case notAHavenLink
        case malformedPayload
        case unsupportedVersion(Int)

        public var code: String {
            switch self {
            case .notAHavenLink: return "not_a_haven_link"
            case .malformedPayload: return "malformed_payload"
            case .unsupportedVersion: return "unsupported_version"
            }
        }

        public var description: String {
            switch self {
            case .notAHavenLink:
                return "Dette ser ikke ut som en HAVEN-invitasjon."
            case .malformedPayload:
                return "Invitasjonen er skadet eller ufullstendig."
            case .unsupportedVersion(let version):
                return "Invitasjonen bruker versjon \(version), som denne utgaven ikke kjenner."
            }
        }
    }

    /// Path segment used by both the universal link and the custom scheme.
    public static let pathSegment = "i"
    public static let customScheme = "haven"

    /// `.sortedKeys` is load-bearing, not cosmetics. `JSONEncoder` does not
    /// promise a key order, so without it the same ticket encodes to different
    /// tokens on different calls — and the token *is* the link. Two calls have
    /// to agree, or a published invitation stops matching the one the issuer
    /// has in hand.
    public static func encode(_ ticket: HavenInviteTicket) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return base64URL(try encoder.encode(ticket))
    }

    public static func decode(_ token: String) throws -> HavenInviteTicket {
        guard let data = dataFromBase64URL(token) else { throw Failure.malformedPayload }
        guard let ticket = try? JSONDecoder().decode(HavenInviteTicket.self, from: data) else {
            throw Failure.malformedPayload
        }
        guard ticket.version == 1 else { throw Failure.unsupportedVersion(ticket.version) }
        return ticket
    }

    /// Self-contained link: everything needed to verify travels in the URL, so
    /// it works even if the scaffold is unreachable when the invitee taps it.
    public static func universalLink(for ticket: HavenInviteTicket, landingBase: String) throws -> String? {
        let base = landingBase.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !base.isEmpty else { return nil }
        return "\(base)/\(pathSegment)/\(try encode(ticket))"
    }

    public static func appLink(for ticket: HavenInviteTicket) throws -> String {
        "\(customScheme)://invite/\(try encode(ticket))"
    }

    /// Short link. Requires the ticket to have been published to the scaffold
    /// first, because the code is a lookup key and nothing else.
    public static func shortLink(for ticket: HavenInviteTicket, landingBase: String) -> String? {
        let base = landingBase.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !base.isEmpty else { return nil }
        return "\(base)/\(pathSegment)/\(ticket.humanCode)"
    }

    /// A six-character code is a code, not a ticket. Used to tell the two
    /// apart when a request arrives at `/i/<something>`.
    public static func looksLikeHumanCode(_ candidate: String) -> Bool {
        candidate.count == humanCodeLength
            && candidate.allSatisfy { humanCodeAlphabet.contains($0) }
    }

    /// Pulls the token out of any of the shapes a link can arrive in.
    public static func token(fromLink link: String) throws -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.notAHavenLink }
        if trimmed.hasPrefix("\(customScheme)://invite/") {
            return String(trimmed.dropFirst("\(customScheme)://invite/".count))
        }
        guard let components = URLComponents(string: trimmed) else { return trimmed }
        if let queryToken = components.queryItems?.first(where: { $0.name == "t" })?.value {
            return queryToken
        }
        let parts = components.path.split(separator: "/").map(String.init)
        // Mail gateways rewrite links. Rather than insisting on the `/i/`
        // segment sitting where we put it, take the last path component that
        // could plausibly be a token — a rewritten URL still ends with ours.
        if let index = parts.lastIndex(of: pathSegment), index + 1 < parts.count {
            return parts[index + 1]
        }
        if let last = parts.last, last.count > 16 || looksLikeHumanCode(last) {
            return last
        }
        throw Failure.notAHavenLink
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func dataFromBase64URL(_ text: String) -> Data? {
        var value = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder > 0 { value += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: value)
    }

    static let humanCodeAlphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let humanCodeLength = 6

    /// Six characters from an alphabet with no 0/O or 1/I/L, so it survives
    /// being read aloud over a phone.
    public static func humanCode(from seed: String) -> String {
        let digest = sha256Hex(seed)
        var code = ""
        var index = digest.startIndex
        while code.count < humanCodeLength, index < digest.endIndex {
            let next = digest.index(index, offsetBy: 2, limitedBy: digest.endIndex) ?? digest.endIndex
            let byte = UInt8(digest[index..<next], radix: 16) ?? 0
            code.append(humanCodeAlphabet[Int(byte) % humanCodeAlphabet.count])
            index = next
        }
        return code
    }

    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Verification

public enum HavenInviteVerifier {

    public static let schema = "haven.invite.verdict.v1"

    public struct Verdict: Equatable, Sendable {
        public var isValid: Bool
        public var signatureValid: Bool
        public var expired: Bool
        public var revoked: Bool
        /// nil when the checking side does not know who the ticket was for.
        /// A landing page never knows; the issuer's own device always does.
        public var audienceMatches: Bool?
        public var reason: String
        public var code: String
        public var ticketID: String
        public var issuerDisplayName: String
        public var issuerIdentityUUID: String

        public init(
            isValid: Bool,
            signatureValid: Bool,
            expired: Bool,
            revoked: Bool,
            audienceMatches: Bool?,
            reason: String,
            code: String,
            ticketID: String,
            issuerDisplayName: String,
            issuerIdentityUUID: String
        ) {
            self.isValid = isValid
            self.signatureValid = signatureValid
            self.expired = expired
            self.revoked = revoked
            self.audienceMatches = audienceMatches
            self.reason = reason
            self.code = code
            self.ticketID = ticketID
            self.issuerDisplayName = issuerDisplayName
            self.issuerIdentityUUID = issuerIdentityUUID
        }
    }

    /// Checks the ticket on its own terms. Offline, no network, and no trust in
    /// the link's own claims beyond what the signature covers.
    public static func verify(
        ticket: HavenInviteTicket,
        revokedTicketIDs: Set<String> = [],
        expectedAudienceToken: String? = nil,
        now: Date = Date()
    ) -> Verdict {
        let issuerName = ticket.issuerDisplayName
        let issuerUUID = ticket.issuer.uuid
        let expired = ticket.isExpired(at: now)
        let revoked = revokedTicketIDs.contains(ticket.ticketID)

        func verdict(_ isValid: Bool, _ signatureValid: Bool, _ code: String, _ reason: String, _ audience: Bool?) -> Verdict {
            Verdict(
                isValid: isValid,
                signatureValid: signatureValid,
                expired: expired,
                revoked: revoked,
                audienceMatches: audience,
                reason: reason,
                code: code,
                ticketID: ticket.ticketID,
                issuerDisplayName: issuerName,
                issuerIdentityUUID: issuerUUID
            )
        }

        guard let proof = ticket.proof, let signature = proof.signature else {
            return verdict(false, false, "unsigned", "Invitasjonen er ikke signert.", nil)
        }
        // The proof must name the same identity the descriptor does, otherwise
        // a valid signature from some other key would look convincing.
        guard proof.byIdentityUUID == ticket.issuer.uuid else {
            return verdict(false, false, "issuer_mismatch",
                           "Signaturen tilhører en annen identitet enn avsenderen i invitasjonen.", nil)
        }
        guard let payload = try? ticket.canonicalPayloadData() else {
            return verdict(false, false, "uncanonical",
                           "Invitasjonen kunne ikke gjøres om til den formen signaturen dekker.", nil)
        }

        let signatureValid = IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: payload,
            descriptor: ticket.issuer
        )
        let audienceMatches = expectedAudienceToken.map { $0 == ticket.audienceToken }

        if !signatureValid {
            return verdict(false, false, "bad_signature",
                           "Signaturen stemmer ikke. Invitasjonen kan være endret underveis.", audienceMatches)
        }
        if revoked {
            return verdict(false, true, "revoked",
                           "\(issuerName) har trukket denne invitasjonen tilbake.", audienceMatches)
        }
        if expired {
            return verdict(false, true, "expired",
                           "Invitasjonen har gått ut. Be \(issuerName) om en ny.", audienceMatches)
        }
        if audienceMatches == false {
            return verdict(false, true, "wrong_audience",
                           "Invitasjonen var adressert til noen andre.", audienceMatches)
        }
        return verdict(true, true, "valid", "Gyldig invitasjon fra \(issuerName).", audienceMatches)
    }

    /// The one serialisation both Binding and the landing page use, so the same
    /// ticket cannot produce two different answers.
    public static func payload(for verdict: Verdict, ticket: HavenInviteTicket) -> Object {
        [
            "schema": .string(schema),
            "status": .string(verdict.isValid ? "valid" : "invalid"),
            "isValid": .bool(verdict.isValid),
            "signatureValid": .bool(verdict.signatureValid),
            "expired": .bool(verdict.expired),
            "revoked": .bool(verdict.revoked),
            "audienceMatches": verdict.audienceMatches.map(ValueType.bool) ?? .null,
            "reason": .string(verdict.reason),
            "code": .string(verdict.code),
            "ticketID": .string(verdict.ticketID),
            "issuerDisplayName": .string(verdict.issuerDisplayName),
            "issuerIdentityUUID": .string(verdict.issuerIdentityUUID),
            "capabilities": .list(ticket.capabilities.map(ValueType.string)),
            "canReceiveContactRequest": .bool(ticket.canReceiveContactRequest),
            "grantsAccess": .bool(false),
            "boundaryStatement": .string(HavenInviteCopy.boundaryLine),
            "humanCode": .string(ticket.humanCode),
            "greetingName": .string(ticket.greetingName ?? ""),
            "expiresAt": .integer(ticket.expiresAt),
            "sideEffect": .bool(false)
        ]
    }
}
