// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  PerspectiveCell+Entities.swift
//  CellProtocol
//
//  The entity half of the perspective's cell surface: who is in my picture of
//  the world, how strongly, and which cell put them there.
//
//  Registration follows the rule the `perspective.perspective: notFound` bug
//  taught us the hard way: **get** intercepts go on the root key, because
//  `GeneralCell` resolves nested reads by walking down from the root. Only the
//  root key `entities` is registered for reading; `entities.<anything>` falls
//  out of that automatically. **Set** intercepts match exactly, so the query
//  and mutation keypaths are registered at their full paths, exactly as
//  `perspective.query.*` already is.
//

@_spi(HAVENRuntime) import CellBase
import Foundation

extension PerspectiveCell {

    // MARK: - Registration

    func setupEntityPermissions() {
        agreementTemplate.ensureGrant("rw--", for: "entities")
        agreementTemplate.ensureGrant("rw--", for: "addEntity")
        agreementTemplate.ensureGrant("rw--", for: "removeEntity")
        agreementTemplate.ensureGrant("rw--", for: "projectEntities")
    }

    func setupEntityKeys(owner: Identity) async {

        // Root key only. `entities.count`, `entities.entities[…]` and friends
        // resolve through GeneralCell's nested fallback from here.
        await addInterceptForGet(requester: owner, key: "entities", getValueIntercept: { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "entities", for: requester) else {
                return .string("denied")
            }
            return await self.entitiesPayload(minWeight: 0.0, limit: 200)
        })

        await addInterceptForSet(requester: owner, key: "addEntity", setValueIntercept: { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "addEntity", for: requester) else {
                return .string("denied")
            }
            return await self.addEntitiesPayload(from: value)
        })

        await addInterceptForSet(requester: owner, key: "removeEntity", setValueIntercept: { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "removeEntity", for: requester) else {
                return .string("denied")
            }
            return await self.removeEntityPayload(from: value)
        })

        // The whole-set write. This is the one `cell:///Relations` uses.
        await addInterceptForSet(requester: owner, key: "projectEntities", setValueIntercept: { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "projectEntities", for: requester) else {
                return .string("denied")
            }
            return await self.projectEntitiesPayload(from: value)
        })

        await addInterceptForSet(requester: owner, key: "perspective.query.activeEntities", setValueIntercept: { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "perspective", for: requester) else {
                return .string("denied")
            }
            let payload: Object = {
                if case let .object(object) = value { return object }
                return Object()
            }()
            let minWeight = PerspectiveCell.entityDouble(payload["minWeight"]) ?? 0.0
            let limit = max(1, PerspectiveCell.entityInt(payload["limit"]) ?? 50)
            return await self.entitiesPayload(minWeight: minWeight, limit: limit)
        })
    }

    // MARK: - Reads

    func entitiesPayload(minWeight: Double, limit: Int) async -> ValueType {
        let active = await context.getActiveEntities(minWeight: minWeight, limit: limit)
        let sources = await context.entityProjectionSources()

        var list = ValueTypeList()
        for weighted in active {
            guard let node = weighted.value as? EntityRepresentation else {
                if let reference = weighted.reference {
                    list.append(.object([
                        "reference": .string(reference),
                        "weight": .float(weighted.weight),
                        "resolved": .bool(false)
                    ]))
                }
                continue
            }
            list.append(.object(Self.entityObject(node, weight: weighted.weight)))
        }

        var sourceObject = Object()
        for (source, epoch) in sources {
            sourceObject[source] = .integer(epoch)
        }

        return .object([
            "entities": .list(list),
            "count": .integer(list.count),
            "minWeight": .float(minWeight),
            "projectionSources": .object(sourceObject),
            "privacyBoundary": .string("names_weights_and_interests_only_no_contact_detail")
        ])
    }

    /// What an entity looks like from outside the perspective.
    ///
    /// Deliberately narrow: name, opaque reference, weight, source, and the
    /// interests it carries. No contact detail, no endpoint hashes, no
    /// provenance about which spreadsheet a person came from. The perspective
    /// is compared and matched against other parties; anything in here should
    /// be safe to reason about in that setting.
    static func entityObject(_ node: EntityRepresentation, weight: Double) -> Object {
        var interests = ValueTypeList()
        for weighted in node.interests {
            guard let interest = weighted.value as? Interest else {
                if let reference = weighted.reference {
                    interests.append(.object(["reference": .string(reference), "weight": .float(weighted.weight)]))
                }
                continue
            }
            interests.append(.object([
                "name": .string(interest.name),
                "reference": .string(interest.reference),
                "weight": .float(weighted.weight)
            ]))
        }
        return [
            "name": .string(node.name),
            "reference": .string(node.reference),
            "weight": .float(weight),
            "interestCount": .integer(interests.count),
            "interests": .list(interests),
            "projectionSource": .string(node.projectionSource ?? ""),
            "resolved": .bool(true)
        ]
    }

    // MARK: - Writes

    private func addEntitiesPayload(from value: ValueType) async -> ValueType {
        do {
            let weighted = try await parseWeightedEntities(from: value)
            guard !weighted.isEmpty else {
                return .object([
                    "status": .string("error"),
                    "code": .string("no_entities"),
                    "message": .string("Fant ingen entiteter å legge til.")
                ])
            }
            var added = 0
            var updated = 0
            for entry in weighted {
                guard let node = entry.value as? EntityRepresentation else { continue }
                if await context.upsertEntityRepresentation(node) { added += 1 } else { updated += 1 }
                await context.upsertActiveEntity(weighedEntity: entry)
            }
            try await persistEntityProjection()
            return .object([
                "status": .string("ok"),
                "addedCount": .integer(added),
                "updatedCount": .integer(updated)
            ])
        } catch {
            return .object([
                "status": .string("error"),
                "code": .string("add_failed"),
                "message": .string("\(error)")
            ])
        }
    }

    private func removeEntityPayload(from value: ValueType) async -> ValueType {
        var references: [String] = []
        switch value {
        case let .string(reference):
            references = [reference]
        case let .object(object):
            if case let .string(reference)? = object["reference"] { references = [reference] }
            if case let .list(list)? = object["references"] {
                references.append(contentsOf: list.compactMap {
                    if case let .string(reference) = $0 { return reference }
                    return nil
                })
            }
        case let .list(list):
            references = list.compactMap {
                if case let .string(reference) = $0 { return reference }
                return nil
            }
        default:
            break
        }

        guard !references.isEmpty else {
            return .object([
                "status": .string("error"),
                "code": .string("missing_reference"),
                "message": .string("Oppgi `reference` eller `references`.")
            ])
        }

        var removed = 0
        for reference in references {
            if await context.removeEntityRepresentation(reference: reference) {
                removed += 1
            }
        }
        if removed > 0 { try? await persistEntityProjection() }
        return .object([
            "status": .string("ok"),
            "removedCount": .integer(removed),
            "requestedCount": .integer(references.count)
        ])
    }

    /// `{ source, epoch, entities: [Weight<EntityRepresentation>] }`
    ///
    /// The set replaces everything that source contributed before. Passing an
    /// empty list is the legitimate way to say "I no longer contribute
    /// anyone", and it removes them.
    private func projectEntitiesPayload(from value: ValueType) async -> ValueType {
        guard case let .object(payload) = value,
              case let .string(source)? = payload["source"],
              !source.isEmpty else {
            return .object([
                "status": .string("error"),
                "code": .string("missing_source"),
                "message": .string("`source` må være endepunktet til cellen som eier projeksjonen.")
            ])
        }
        let epoch = Self.entityInt(payload["epoch"]) ?? 0

        do {
            let entities = try await parseWeightedEntities(from: payload["entities"] ?? .list([]))
            let result = try await context.applyEntityProjection(
                PerspectiveEntityProjection(source: source, epoch: epoch, entities: entities)
            )
            if result.ignoredStaleEpoch {
                return .object([
                    "status": .string("ignored"),
                    "code": .string("stale_epoch"),
                    "message": .string("En nyere projeksjon fra \(source) er allerede tatt imot."),
                    "currentEpoch": .integer(result.epoch)
                ])
            }
            return .object([
                "status": .string("ok"),
                "source": .string(result.source),
                "epoch": .integer(result.epoch),
                "addedCount": .integer(result.added),
                "updatedCount": .integer(result.updated),
                "removedCount": .integer(result.removed),
                "message": .string(Self.projectionMessage(result))
            ])
        } catch {
            return .object([
                "status": .string("error"),
                "code": .string("projection_failed"),
                "message": .string("\(error)")
            ])
        }
    }

    private static func projectionMessage(_ result: PerspectiveProjectionResult) -> String {
        var parts: [String] = []
        if result.added > 0 { parts.append("\(result.added) nye") }
        if result.updated > 0 { parts.append("\(result.updated) oppdatert") }
        if result.removed > 0 { parts.append("\(result.removed) fjernet") }
        if parts.isEmpty { return "Ingen endring." }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Parsing

    func parseWeightedEntities(from value: ValueType) async throws -> [Weight<EntityRepresentation>] {
        if case let .list(list) = value {
            var result: [Weight<EntityRepresentation>] = []
            for item in list {
                if let weighted = try await parseWeightedEntity(from: item) {
                    result.append(weighted)
                }
            }
            return result
        }
        if let weighted = try await parseWeightedEntity(from: value) {
            return [weighted]
        }
        return []
    }

    private func parseWeightedEntity(from value: ValueType) async throws -> Weight<EntityRepresentation>? {
        guard case let .object(object) = value else { return nil }

        // The canonical shape is `Weight`'s own: { weight, value }. Anything
        // else would decode to a weight with no node, which is exactly the
        // silent-drop failure this contract exists to prevent.
        if object["value"] != nil || object["reference"] != nil {
            return try await transformObjectToWeightedEntity(entity: object)
        }

        // Tolerate a bare entity object by wrapping it, so a caller that sends
        // `{ name: … }` gets a clear node rather than nothing at all.
        if object["name"] != nil {
            let entity = try await transformObjectToEntity(entity: object)
            let weight = Self.entityDouble(object["weight"]) ?? 0.5
            return Weight<EntityRepresentation>(weight: weight, value: entity)
        }
        return nil
    }

    /// `persistPerpective()` is file-private to `PerspectiveCell.swift`, so this
    /// extension persists through the actor directly. Same file on disk, same
    /// encoder — see `Perspective.persistContext()`.
    private func persistEntityProjection() async throws {
        try await context.persistContext()
    }

    // MARK: - Small helpers

    static func entityDouble(_ value: ValueType?) -> Double? {
        switch value {
        case let .float(number)?: return number
        case let .integer(number)?: return Double(number)
        case let .number(number)?: return Double(number)
        default: return nil
        }
    }

    static func entityInt(_ value: ValueType?) -> Int? {
        switch value {
        case let .integer(number)?: return number
        case let .number(number)?: return number
        case let .float(number)?: return Int(number)
        default: return nil
        }
    }
}
