import Foundation
import CellBase

/// Conditions use Agreement's typed JSON representation. This is a disclosure
/// policy, not an identity, group-name allowlist, or a grant to the whole scanner.
public struct NearbyAccessAgreement: Codable, Equatable {
    public static let readKeypath = "nearby.advertisement.read"
    public var title: String
    public var domain: String
    public var verifierDID: String
    public var conditions: [Object]
    public init(title: String, domain: String, verifierDID: String, conditions: [Object]) {
        self.title = title; self.domain = domain; self.verifierDID = verifierDID
        self.conditions = conditions
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        (try? canonical(lhs)) == (try? canonical(rhs))
    }

    public var conditionNames: [String] {
        conditions.compactMap { row in
            guard case let .object(condition)? = row["condition"], case let .string(name)? = condition["name"] else { return nil }
            return name
        }
    }

    public func validate() throws {
        guard !title.isEmpty, title.utf8.count <= 120, !domain.isEmpty, domain.utf8.count <= 160,
              verifierDID.hasPrefix("did:key:"), verifierDID.utf8.count <= 512,
              !conditions.isEmpty, conditions.count <= 16, try Self.canonical(self).count <= 32_768 else { throw AccessError.invalidPolicy }
        // Agreement's legacy decoder can discard an undecodable condition array.
        // Require a lossless roundtrip before this policy can protect any data.
        let template = Agreement(owner: Identity())
        var object = try Self.object(template)
        object["conditions"] = .list(conditions.map(ValueType.object))
        let decoded = try JSONDecoder().decode(Agreement.self, from: Self.canonical(object))
        let roundtrip = try Self.typedConditions(decoded)
        guard try Self.canonical(roundtrip) == Self.canonical(conditions) else { throw AccessError.unsupportedCondition }
        var ids = Set<String>()
        for row in conditions {
            guard case let .string(type)? = row["type"],
                  case let .object(condition)? = row["condition"],
                  case let .string(id)? = condition["uuid"], !id.isEmpty, ids.insert(id).inserted,
                  case let .string(name)? = condition["name"], !name.isEmpty else { throw AccessError.invalidPolicy }
            // These legacy evaluators contain placeholders/demonstration grants.
            guard type != "httpRequest", type != "grant", type != "engagement" else { throw AccessError.unsupportedCondition }
        }
    }

    public static func importing(_ data: Data, domain: String, verifierDID: String) throws -> Self {
        guard data.count <= 65_536 else { throw AccessError.invalidPolicy }
        if let policy = try? JSONDecoder().decode(Self.self, from: data) { try policy.validate(); return policy }
        let raw = try JSONDecoder().decode(Object.self, from: data)
        guard case let .list(rows)? = raw["conditions"], rows.allSatisfy({ if case .object = $0 { return true }; return false }) else { throw AccessError.invalidPolicy }
        let result = Self(title: raw["name"]?.stringValue ?? "Vilkår for deling", domain: domain, verifierDID: verifierDID,
            conditions: rows.compactMap { if case let .object(row) = $0 { return row }; return nil })
        try result.validate(); return result
    }

    static func typedConditions(_ agreement: Agreement) throws -> [Object] {
        guard case let .list(rows)? = try object(agreement)["conditions"] else { return [] }
        return rows.compactMap { if case let .object(row) = $0 { return row }; return nil }
    }
    static func object<T: Encodable>(_ value: T) throws -> Object { try JSONDecoder().decode(Object.self, from: canonical(value)) }
    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    public var digest: String { (try? FlowHasher.sha256Hex(Self.canonical(self))) ?? "" }
    public enum AccessError: Error { case invalidPolicy, unsupportedCondition, invalidProof }
}

/// Imported explicitly by the reader. Never read automatically from a profile,
/// EntityRepresentation graph, credential store, or private Agreement history.
public struct NearbyAccessEvidence: Codable {
    public var contracts: [Contract]
    public init(contracts: [Contract] = []) { self.contracts = contracts }
    public static func importing(_ data: Data) throws -> Self {
        guard data.count <= 196_608 else { throw NearbyAccessAgreement.AccessError.invalidProof }
        let result: Self
        if let bundle = try? JSONDecoder().decode(Self.self, from: data) { result = bundle }
        else if let contract = try? JSONDecoder().decode(Contract.self, from: data) { result = Self(contracts: [contract]) }
        else { throw NearbyAccessAgreement.AccessError.invalidProof }
        guard result.contracts.count <= 4, !result.contracts.isEmpty else { throw NearbyAccessAgreement.AccessError.invalidProof }
        return result
    }
}

/// Cell-owned decision layer. The transport only carries challenge and proof bytes.
enum NearbyAgreementAuthorization {
    static func allows(_ evidence: NearbyAccessEvidence, policy: NearbyAccessAgreement, reader: Identity, now: Date = Date()) async -> Bool {
        guard (try? policy.validate()) != nil, (try? reader.did()) != nil,
              !evidence.contracts.isEmpty, evidence.contracts.count <= 4 else { return false }
        // An authority-issued Agreement authorization is an explicit short lease.
        // Arbitrary Conditions are evaluated by that authority, not guessed here.
        for contract in evidence.contracts {
            guard (try? contract.issuer.did()) == policy.verifierDID,
                  contract.issuedAt >= now.timeIntervalSince1970 - 300,
                  contract.issuedAt <= now.timeIntervalSince1970 + 5,
                  contract.expiresAt - contract.issuedAt <= 300,
                  contract.agreement.checkGrant(requestedGrant: Grant(keypath: NearbyAccessAgreement.readKeypath, permission: "r---")),
                  let conditions = try? NearbyAccessAgreement.typedConditions(contract.agreement),
                  (try? NearbyAccessAgreement.canonical(conditions)) == (try? NearbyAccessAgreement.canonical(policy.conditions)),
                  await contract.verifyAuthorizationBinding(expectedIssuer: contract.issuer, expectedSubject: reader, expectedDomain: policy.domain, now: now) else { continue }
            return true
        }
        // A TrustedIssuer evaluation receipt does not attest the entire native
        // Condition expression. Only exact Agreement authorization grants access.
        return false
    }
}

private extension ValueType {
    var stringValue: String? { if case let .string(value) = self { return value }; return nil }
}
