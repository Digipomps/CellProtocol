// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  PerspectiveEntityProjection.swift
//  CellProtocol
//
//  Entity CRUD for the perspective, and the projection contract that lets one
//  cell own a slice of the entity graph without owning the whole thing.
//
//  A projection is a *set*, not a stream of additions. `cell:///Relations`
//  says "these are the people, as of now" and the perspective makes that true:
//  nodes that source contributed before and did not contribute this time are
//  removed. That is what makes deletion in the source reach the graph at all —
//  without it, the perspective could only ever grow, and a relation the owner
//  deleted would keep matching forever.
//

import Foundation

// MARK: - Projection contract

/// One cell's claim on a slice of the entity graph.
public struct PerspectiveEntityProjection: Sendable {
    /// Endpoint of the cell that owns this slice, e.g. `cell:///Relations`.
    public let source: String
    /// Monotonic counter from the source. An older epoch is ignored, so a
    /// delayed write cannot resurrect entities a newer one removed.
    public let epoch: Int
    public let entities: [Weight<EntityRepresentation>]

    public init(source: String, epoch: Int, entities: [Weight<EntityRepresentation>]) {
        self.source = source
        self.epoch = epoch
        self.entities = entities
    }
}

public struct PerspectiveProjectionResult: Sendable, Equatable {
    public var source: String
    public var epoch: Int
    public var added: Int
    public var updated: Int
    public var removed: Int
    public var ignoredStaleEpoch: Bool

    public init(
        source: String,
        epoch: Int,
        added: Int = 0,
        updated: Int = 0,
        removed: Int = 0,
        ignoredStaleEpoch: Bool = false
    ) {
        self.source = source
        self.epoch = epoch
        self.added = added
        self.updated = updated
        self.removed = removed
        self.ignoredStaleEpoch = ignoredStaleEpoch
    }

    public var changedAnything: Bool { added + updated + removed > 0 }
}

// MARK: - Entity CRUD

extension Perspective {

    /// Add or replace one entity, keyed on its reference. Idempotent: calling
    /// it twice with the same node leaves one node, not two.
    public func upsertEntityRepresentation(_ entity: EntityRepresentation) -> Bool {
        let reference = entity.reference
        let existed = entityRepresentationReferencesDict[reference] != nil
        addEntityRepresentation(entity)
        return !existed
    }

    /// Removes an entity and every trace of it: the reference dictionary, the
    /// name index, the container, and any active weight pointing at it.
    @discardableResult
    public func removeEntityRepresentation(reference: String) -> Bool {
        guard let existing = entityRepresentationReferencesDict[reference] else { return false }

        entityRepresentationReferencesDict.removeValue(forKey: reference)

        if var references = entityRepresentationNameReferences[existing.name] {
            references.removeAll { $0 == reference }
            if references.isEmpty {
                entityRepresentationNameReferences.removeValue(forKey: existing.name)
            } else {
                entityRepresentationNameReferences[existing.name] = references
            }
        }

        entityRepresentation.removeAll { $0.reference == reference }
        detachEntityFromContainer(reference: reference)
        removeActiveEntity(reference: reference)
        return true
    }

    /// References currently contributed by one projecting cell.
    public func projectedEntityReferences(source: String) -> Set<String> {
        Set(
            entityRepresentationReferencesDict
                .filter { $0.value.projectionSource == source }
                .keys
        )
    }

    // MARK: Active weights

    /// Mirrors `upsertActivePurpose`: replace by reference, otherwise append.
    public func upsertActiveEntity(weighedEntity: Weight<EntityRepresentation>) {
        let incoming = weighedEntity.reference ?? weighedEntity.value?.reference
        if let incoming,
           let index = activeEntities.firstIndex(where: {
               ($0.reference ?? $0.value?.reference) == incoming
           }) {
            activeEntities[index] = weighedEntity
        } else {
            activeEntities.append(weighedEntity)
        }
        activeEntities = activeEntities.sorted(by: { $0.weight > $1.weight })
    }

    @discardableResult
    public func removeActiveEntity(reference: String) -> Bool {
        let before = activeEntities.count
        activeEntities.removeAll { ($0.reference ?? $0.value?.reference) == reference }
        return activeEntities.count != before
    }

    // MARK: Projection

    /// Applies a whole projected set from one source.
    ///
    /// Everything that source contributed before and is absent now is removed.
    /// Nodes from other sources, and nodes the owner made by hand, are never
    /// touched — the source only ever controls its own slice.
    @discardableResult
    public func applyEntityProjection(_ projection: PerspectiveEntityProjection) throws -> PerspectiveProjectionResult {
        let lastEpoch = projectionEpochs[projection.source] ?? Int.min
        guard projection.epoch >= lastEpoch else {
            // A late write must not undo a newer one.
            CellBase.diagnosticLog(
                "Perspective ignoring stale projection epoch \(projection.epoch) for \(projection.source), current \(lastEpoch)",
                domain: .semantics
            )
            return PerspectiveProjectionResult(
                source: projection.source,
                epoch: lastEpoch,
                ignoredStaleEpoch: true
            )
        }

        let previous = projectedEntityReferences(source: projection.source)
        var seen = Set<String>()
        var added = 0
        var updated = 0

        for weighted in projection.entities {
            guard let node = weighted.value as? EntityRepresentation else {
                // A reference-only weight cannot carry a projection source, so
                // it cannot participate in set replacement. Skip rather than
                // silently create an orphan we can never remove.
                continue
            }
            node.projectionSource = projection.source
            let reference = node.reference
            seen.insert(reference)
            if upsertEntityRepresentation(node) { added += 1 } else { updated += 1 }
            upsertActiveEntity(weighedEntity: Weight<EntityRepresentation>(weight: weighted.weight, value: node))
        }

        var removed = 0
        for reference in previous.subtracting(seen) {
            if removeEntityRepresentation(reference: reference) { removed += 1 }
        }

        projectionEpochs[projection.source] = projection.epoch

        let result = PerspectiveProjectionResult(
            source: projection.source,
            epoch: projection.epoch,
            added: added,
            updated: updated,
            removed: removed
        )
        if result.changedAnything {
            try persistContext()
        }
        return result
    }

    /// Drops an entire projection. Used when the owner turns a source off.
    @discardableResult
    public func clearEntityProjection(source: String) throws -> PerspectiveProjectionResult {
        let references = projectedEntityReferences(source: source)
        var removed = 0
        for reference in references where removeEntityRepresentation(reference: reference) {
            removed += 1
        }
        projectionEpochs.removeValue(forKey: source)
        if removed > 0 { try persistContext() }
        return PerspectiveProjectionResult(source: source, epoch: 0, removed: removed)
    }

    /// Every entity currently known, projected or not.
    public func allEntityRepresentations() -> [EntityRepresentation] {
        Array(entityRepresentationReferencesDict.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func entityProjectionSources() -> [String: Int] {
        projectionEpochs
    }
}
