// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

extension EntityRelationRecord {
    /// Reads the canonical graph, or adapts legacy fields without rewriting the
    /// stored record. Historical tag weights are retained only for legacy input.
    /// New authored graphs never pass through the tag approximation.
    public func perspectiveRepresentation() throws -> EntityRepresentation {
        if let entityRepresentation {
            return try EntityRepresentationDataCodec.copy(entityRepresentation, ownerPrivate: true)
        }
        var person: Entity = ["displayName": .string(subject.displayName)]
        var name: Object = [:]
        if let first = subject.givenName { name["first"] = .string(first) }
        if let last = subject.familyName { name["last"] = .string(last) }
        if !name.isEmpty { person["name"] = .object(name) }
        var work: Object = [:]
        if let organization = subject.organization { work["organizationName"] = .string(organization) }
        if let title = subject.jobTitle { work["title"] = .string(title) }
        if !work.isEmpty { person["work"] = .object(work) }

        let declared = interests.declared.map { ($0, 0.75) }
        let inferred = interests.inferred.map { ($0, 0.35) }
        let weightedInterests = (declared + inferred).map { name, weight in
            Weight<Interest>(weight: weight, value: Interest(name: name, types: [], parts: [], partOf: [], purposes: []))
        }
        return EntityRepresentation(
            interests: weightedInterests,
            purposes: purposeRefs.map { Weight<Purpose>(weight: 1, reference: $0) },
            name: subject.displayName,
            person: person,
            nodeIdentifier: subject.perspectiveRef ?? relationID
        )
    }

    /// Graph-derived matching view. The caller still chooses which records and
    /// fields may be disclosed and must use the authorized Perspective path.
    public func matchingRepresentation(reference: String, source: String, includeGraph: Bool = false) throws -> EntityRepresentation {
        let entity = try perspectiveRepresentation()
        // Existing projection consent covered names and direct interests only.
        // Full weighted graphs require an explicit choice by the caller.
        if !includeGraph {
            let interests: [Weight<Interest>] = entity.interests.compactMap { edge in
                guard let interest = edge.value as? Interest else {
                    return Weight<Interest>(weight: edge.weight, reference: edge.reference)
                }
                let leaf = Interest(name: interest.name, types: [], parts: [], partOf: [], purposes: [])
                leaf.nodeIdentifier = interest.nodeIdentifier
                return Weight<Interest>(weight: edge.weight, value: leaf)
            }
            return EntityRepresentation(interests: interests, name: entity.name, nodeIdentifier: reference, projectionSource: source)
        }
        let projection = try EntityRepresentationDataCodec.copy(entity, ownerPrivate: false)
        EntityRepresentationDataCodec.setRootReference(reference, in: projection)
        projection.projectionSource = source
        return projection
    }
}
