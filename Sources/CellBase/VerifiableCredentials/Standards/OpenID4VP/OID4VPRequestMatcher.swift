// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum OID4VPRequestMatcherError: Error, Equatable {
    case missingDCQLQuery
}

public struct OID4VPCredentialCandidate: Codable, Equatable, Sendable {
    public var id: String
    public var format: StandardsCredentialFormat
    public var meta: [String: OID4VPJSONValue]
    public var claims: OID4VPJSONValue
    public var presentation: OID4VPResponsePresentation?
    public var trustedAuthorities: [String: [String]]
    public var hasCryptographicHolderBinding: Bool

    public init(
        id: String,
        format: StandardsCredentialFormat,
        meta: [String: OID4VPJSONValue],
        claims: OID4VPJSONValue,
        presentation: OID4VPResponsePresentation? = nil,
        trustedAuthorities: [String: [String]] = [:],
        hasCryptographicHolderBinding: Bool = true
    ) {
        self.id = id
        self.format = format
        self.meta = meta
        self.claims = claims
        self.presentation = presentation
        self.trustedAuthorities = trustedAuthorities
        self.hasCryptographicHolderBinding = hasCryptographicHolderBinding
    }
}

public struct OID4VPCandidateMatch: Codable, Equatable, Sendable {
    public var candidate: OID4VPCredentialCandidate
    public var satisfiedClaimIDs: [String]
    public var satisfiedClaimSetIndices: [Int]

    public init(candidate: OID4VPCredentialCandidate, satisfiedClaimIDs: [String], satisfiedClaimSetIndices: [Int]) {
        self.candidate = candidate
        self.satisfiedClaimIDs = satisfiedClaimIDs
        self.satisfiedClaimSetIndices = satisfiedClaimSetIndices
    }
}

public struct OID4VPRequestMatchResult: Codable, Equatable, Sendable {
    public var matchesByCredentialID: [String: [OID4VPCandidateMatch]]
    public var satisfiedCredentialSetIndices: [Int]
    public var unsatisfiedRequiredCredentialQueryIDs: [String]
    public var unsatisfiedRequiredCredentialSetIndices: [Int]

    public init(
        matchesByCredentialID: [String: [OID4VPCandidateMatch]],
        satisfiedCredentialSetIndices: [Int],
        unsatisfiedRequiredCredentialQueryIDs: [String],
        unsatisfiedRequiredCredentialSetIndices: [Int]
    ) {
        self.matchesByCredentialID = matchesByCredentialID
        self.satisfiedCredentialSetIndices = satisfiedCredentialSetIndices
        self.unsatisfiedRequiredCredentialQueryIDs = unsatisfiedRequiredCredentialQueryIDs
        self.unsatisfiedRequiredCredentialSetIndices = unsatisfiedRequiredCredentialSetIndices
    }

    public var hasAnyMatches: Bool {
        matchesByCredentialID.values.contains(where: { !$0.isEmpty })
    }

    public var satisfiesRequiredConstraints: Bool {
        unsatisfiedRequiredCredentialQueryIDs.isEmpty && unsatisfiedRequiredCredentialSetIndices.isEmpty
    }

    public func matches(for credentialID: String) -> [OID4VPCandidateMatch] {
        matchesByCredentialID[credentialID] ?? []
    }
}

public enum OID4VPRequestMatcher {
    public static func match(
        requestObject: OID4VPRequestObject,
        candidates: [OID4VPCredentialCandidate]
    ) throws -> OID4VPRequestMatchResult {
        guard let dcqlQuery = requestObject.dcqlQuery else {
            throw OID4VPRequestMatcherError.missingDCQLQuery
        }
        return match(query: dcqlQuery, candidates: candidates)
    }

    public static func match(
        query: OID4VPDCQLQuery,
        candidates: [OID4VPCredentialCandidate]
    ) -> OID4VPRequestMatchResult {
        var matchesByCredentialID: [String: [OID4VPCandidateMatch]] = [:]
        var unsatisfiedRequiredCredentialQueryIDs: [String] = []
        let credentialIDsCoveredBySets = referencedCredentialIDs(in: query.credentialSets)

        for credentialQuery in query.credentials {
            let matches = candidates.compactMap { candidate in
                candidateMatch(for: candidate, query: credentialQuery)
            }
            matchesByCredentialID[credentialQuery.id] = matches
            if matches.isEmpty && !credentialIDsCoveredBySets.contains(credentialQuery.id) {
                unsatisfiedRequiredCredentialQueryIDs.append(credentialQuery.id)
            }
        }

        let credentialSetEvaluation = evaluateCredentialSets(
            query.credentialSets,
            matchesByCredentialID: matchesByCredentialID
        )

        return OID4VPRequestMatchResult(
            matchesByCredentialID: matchesByCredentialID,
            satisfiedCredentialSetIndices: credentialSetEvaluation.satisfiedIndices,
            unsatisfiedRequiredCredentialQueryIDs: unsatisfiedRequiredCredentialQueryIDs,
            unsatisfiedRequiredCredentialSetIndices: credentialSetEvaluation.unsatisfiedRequiredIndices
        )
    }

    private static func candidateMatch(
        for candidate: OID4VPCredentialCandidate,
        query: OID4VPDCQLCredentialQuery
    ) -> OID4VPCandidateMatch? {
        guard candidate.format == query.format else {
            return nil
        }
        guard metaMatches(query.meta, candidateMeta: candidate.meta) else {
            return nil
        }
        guard trustedAuthoritiesMatch(query.trustedAuthorities, candidateAuthorities: candidate.trustedAuthorities) else {
            return nil
        }
        if query.requiresCryptographicHolderBinding && !candidate.hasCryptographicHolderBinding {
            return nil
        }

        let claimEvaluation = evaluateClaims(
            claims: query.claims,
            claimSets: query.claimSets,
            against: candidate.claims
        )
        guard claimEvaluation.matches else {
            return nil
        }

        return OID4VPCandidateMatch(
            candidate: candidate,
            satisfiedClaimIDs: claimEvaluation.satisfiedClaimIDs,
            satisfiedClaimSetIndices: claimEvaluation.satisfiedClaimSetIndices
        )
    }

    private static func metaMatches(
        _ queryMeta: [String: OID4VPJSONValue],
        candidateMeta: [String: OID4VPJSONValue]
    ) -> Bool {
        for (key, queryValue) in queryMeta {
            guard let candidateValue = candidateMeta[key] else {
                return false
            }
            if !jsonValueMatches(queryValue, candidateValue: candidateValue) {
                return false
            }
        }
        return true
    }

    private static func trustedAuthoritiesMatch(
        _ queryAuthorities: [OID4VPDCQLTrustedAuthorityQuery]?,
        candidateAuthorities: [String: [String]]
    ) -> Bool {
        guard let queryAuthorities else {
            return true
        }

        for authority in queryAuthorities {
            guard let candidateValues = candidateAuthorities[authority.type] else {
                return false
            }
            if Set(candidateValues).isDisjoint(with: authority.values) {
                return false
            }
        }

        return true
    }

    private static func evaluateClaims(
        claims: [OID4VPDCQLClaimsQuery]?,
        claimSets: [[String]]?,
        against root: OID4VPJSONValue
    ) -> (matches: Bool, satisfiedClaimIDs: [String], satisfiedClaimSetIndices: [Int]) {
        guard let claims else {
            return (true, [], [])
        }

        var satisfactionByClaimID: [String: Bool] = [:]
        var satisfiedClaimIDs: [String] = []

        for claim in claims {
            let values = values(in: root, path: claim.path)
            let matches = claimMatches(claim, values: values)

            if let claimID = claim.id {
                satisfactionByClaimID[claimID] = matches
                if matches {
                    satisfiedClaimIDs.append(claimID)
                }
            } else if !matches {
                return (false, satisfiedClaimIDs.sorted(), [])
            }
        }

        guard let claimSets else {
            let allNamedClaimsSatisfied = satisfactionByClaimID.values.allSatisfy { $0 }
            return (allNamedClaimsSatisfied, satisfiedClaimIDs.sorted(), [])
        }

        let claimIDsCoveredBySets = Set(claimSets.flatMap { $0 })
        let uncoveredNamedClaimsSatisfied = satisfactionByClaimID.allSatisfy { claimID, isSatisfied in
            claimIDsCoveredBySets.contains(claimID) || isSatisfied
        }
        guard uncoveredNamedClaimsSatisfied else {
            return (false, satisfiedClaimIDs.sorted(), [])
        }

        var satisfiedClaimSetIndices: [Int] = []
        for (index, claimSet) in claimSets.enumerated() {
            let setSatisfied = claimSet.allSatisfy { satisfactionByClaimID[$0] == true }
            if setSatisfied {
                satisfiedClaimSetIndices.append(index)
            }
        }

        return (!satisfiedClaimSetIndices.isEmpty, satisfiedClaimIDs.sorted(), satisfiedClaimSetIndices)
    }

    private static func claimMatches(
        _ claim: OID4VPDCQLClaimsQuery,
        values: [OID4VPJSONValue]
    ) -> Bool {
        guard let expectedValues = claim.values else {
            return !values.isEmpty
        }

        return values.contains { candidateValue in
            expectedValues.contains { primitive in
                primitiveMatches(primitive, candidateValue: candidateValue)
            }
        }
    }

    private static func evaluateCredentialSets(
        _ credentialSets: [OID4VPDCQLCredentialSetQuery]?,
        matchesByCredentialID: [String: [OID4VPCandidateMatch]]
    ) -> (satisfiedIndices: [Int], unsatisfiedRequiredIndices: [Int]) {
        guard let credentialSets else {
            return ([], [])
        }

        var satisfiedIndices: [Int] = []
        var unsatisfiedRequiredIndices: [Int] = []

        for (index, credentialSet) in credentialSets.enumerated() {
            let setSatisfied = credentialSet.options.contains { option in
                option.allSatisfy { !(matchesByCredentialID[$0] ?? []).isEmpty }
            }
            if setSatisfied {
                satisfiedIndices.append(index)
            } else if credentialSet.isRequired {
                unsatisfiedRequiredIndices.append(index)
            }
        }

        return (satisfiedIndices, unsatisfiedRequiredIndices)
    }

    private static func referencedCredentialIDs(
        in credentialSets: [OID4VPDCQLCredentialSetQuery]?
    ) -> Set<String> {
        Set(credentialSets?.flatMap(\.options).flatMap { $0 } ?? [])
    }

    private static func primitiveMatches(
        _ primitive: OID4VPDCQLPrimitiveValue,
        candidateValue: OID4VPJSONValue
    ) -> Bool {
        switch (primitive, candidateValue) {
        case (.string(let lhs), .string(let rhs)):
            return lhs == rhs
        case (.integer(let lhs), .integer(let rhs)):
            return lhs == rhs
        case (.boolean(let lhs), .boolean(let rhs)):
            return lhs == rhs
        default:
            return false
        }
    }

    private static func jsonValueMatches(
        _ queryValue: OID4VPJSONValue,
        candidateValue: OID4VPJSONValue
    ) -> Bool {
        switch (queryValue, candidateValue) {
        case (.array(let queryItems), .array(let candidateItems)):
            return queryItems.allSatisfy { item in
                candidateItems.contains(where: { jsonValueMatches(item, candidateValue: $0) })
            }
        case (.array(let queryItems), _):
            return queryItems.contains(where: { jsonValueMatches($0, candidateValue: candidateValue) })
        case (_, .array(let candidateItems)):
            return candidateItems.contains(where: { jsonValueMatches(queryValue, candidateValue: $0) })
        default:
            return queryValue == candidateValue
        }
    }

    private static func values(
        in root: OID4VPJSONValue,
        path: [OID4VPDCQLPathSegment]
    ) -> [OID4VPJSONValue] {
        guard let first = path.first else {
            return [root]
        }
        let remainder = Array(path.dropFirst())

        switch first {
        case .key(let key):
            if case .object(let object) = root, let nested = object[key] {
                return values(in: nested, path: remainder)
            }
            return []
        case .index(let index):
            if case .array(let array) = root, array.indices.contains(index) {
                return values(in: array[index], path: remainder)
            }
            return []
        case .wildcard:
            switch root {
            case .array(let array):
                return array.flatMap { values(in: $0, path: remainder) }
            case .object(let object):
                return object.values.flatMap { values(in: $0, path: remainder) }
            default:
                return []
            }
        }
    }
}
