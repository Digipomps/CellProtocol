// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct EntityAtlasProjectionContext {
    public var resolver: CellResolverProtocol
    public var requester: Identity
    public var scaffoldConfigurations: [CellConfiguration]
    public var documents: AtlasVaultDocumentSnapshot

    public init(
        resolver: CellResolverProtocol,
        requester: Identity,
        scaffoldConfigurations: [CellConfiguration] = [],
        documents: AtlasVaultDocumentSnapshot = AtlasVaultDocumentSnapshot()
    ) {
        self.resolver = resolver
        self.requester = requester
        self.scaffoldConfigurations = scaffoldConfigurations
        self.documents = documents
    }
}

public struct EntityAtlasProjection {
    public init() {}

    public func build(context: EntityAtlasProjectionContext) async throws -> EntityAtlasSnapshot {
        let registrySnapshot = await context.resolver.resolverRegistrySnapshot(requester: context.requester)
        var cellsByID = [String: EntityAtlasCellRecord]()
        var scaffolds = [EntityAtlasScaffoldRecord]()
        var relations = [EntityAtlasRelation]()

        let resolveByName = Dictionary(uniqueKeysWithValues: registrySnapshot.resolves.map { ($0.name, $0) })

        for resolve in registrySnapshot.resolves {
            let endpoint = normalizeCellReference(resolve.name)
            upsertCell(id: endpoint, cellsByID: &cellsByID) { cell in
                cell.name = displayName(from: resolve.name)
                cell.endpoint = endpoint
                cell.typeName = cell.typeName ?? resolve.cellType
                cell.controlState.resolverScope = resolve.cellScope
                cell.controlState.scaffoldAvailable = true
                appendProvenance(&cell.provenance, .init(source: .resolverRegistration, detail: resolve.name, confidence: 0.7))
            }
        }

        for configuration in context.scaffoldConfigurations.sorted(by: { $0.uuid < $1.uuid }) {
            let scaffoldID = "scaffold.config:\(configuration.uuid)"
            let flattenedReferences = flattenReferences(from: configuration.cellReferences ?? [])
            let referencedEndpoints = flattenedReferences.map { normalizeCellReference($0.endpoint) }
            let scaffold = EntityAtlasScaffoldRecord(
                scaffoldID: scaffoldID,
                name: configuration.name,
                description: configuration.description,
                purposeRef: configuration.discovery?.purpose,
                purposeDescription: configuration.discovery?.purposeDescription,
                sourceCellEndpoint: configuration.discovery?.sourceCellEndpoint.map(normalizeCellReference),
                sourceCellName: configuration.discovery?.sourceCellName,
                referencedCellEndpoints: referencedEndpoints,
                provenance: [.init(source: .cellConfiguration, detail: configuration.uuid, confidence: 0.6)]
            )
            scaffolds.append(scaffold)

            if let primaryEndpoint = primaryEndpoint(for: configuration, references: flattenedReferences) {
                upsertCell(id: primaryEndpoint, cellsByID: &cellsByID) { cell in
                    cell.name = displayName(from: configuration.discovery?.sourceCellName ?? configuration.name)
                    cell.endpoint = primaryEndpoint
                    cell.controlState.scaffoldAvailable = true
                    if let purpose = configuration.discovery?.purpose, !purpose.isEmpty {
                        insertUnique(&cell.purposes, purpose)
                    }
                    if let summary = configuration.discovery?.purposeDescription, !summary.isEmpty {
                        cell.summary = cell.summary ?? summary
                    }
                    appendProvenance(&cell.provenance, .init(source: .cellConfiguration, detail: configuration.uuid, confidence: 0.6))
                }

                relations.append(
                    EntityAtlasRelation(
                        fromID: scaffoldID,
                        kind: .derivedFromScaffold,
                        toID: primaryEndpoint,
                        explanation: "Scaffold configuration points at this cell as the source target.",
                        provenance: [.init(source: .cellConfiguration, detail: configuration.uuid, confidence: 0.6)]
                    )
                )

                if let purpose = configuration.discovery?.purpose, !purpose.isEmpty {
                    relations.append(
                        EntityAtlasRelation(
                            fromID: primaryEndpoint,
                            kind: .solves,
                            toID: "purpose:\(purpose)",
                            explanation: "Scaffold discovery metadata declares purpose coverage.",
                            provenance: [.init(source: .cellConfiguration, detail: configuration.uuid, confidence: 0.55)]
                        )
                    )
                }

                for referencedEndpoint in referencedEndpoints where referencedEndpoint != primaryEndpoint {
                    upsertCell(id: referencedEndpoint, cellsByID: &cellsByID) { cell in
                        cell.name = displayName(from: referencedEndpoint)
                        cell.endpoint = referencedEndpoint
                        cell.controlState.persistedAttachment = true
                        appendProvenance(&cell.provenance, .init(source: .cellConfiguration, detail: configuration.uuid, confidence: 0.5))
                    }
                    upsertCell(id: primaryEndpoint, cellsByID: &cellsByID) { cell in
                        insertUnique(&cell.dependencyRefs, referencedEndpoint)
                    }
                    relations.append(
                        EntityAtlasRelation(
                            fromID: primaryEndpoint,
                            kind: .dependsOn,
                            toID: referencedEndpoint,
                            explanation: "Scaffold cell configuration references this dependency.",
                            provenance: [.init(source: .cellConfiguration, detail: configuration.uuid, confidence: 0.6)]
                        )
                    )
                }
            }
        }

        let activeInstances = registrySnapshot.sharedNamedInstances + registrySnapshot.identityNamedInstances.filter { $0.identityUUID == context.requester.uuid }
        for instance in activeInstances.sorted(by: { $0.endpoint < $1.endpoint }) {
            let endpoint = instance.endpoint
            let resolve = resolveByName[instance.name]
            upsertCell(id: endpoint, cellsByID: &cellsByID) { cell in
                cell.name = displayName(from: instance.name)
                cell.endpoint = endpoint
                cell.runtimeUUID = instance.uuid
                cell.controlState.runtimeAvailable = true
                cell.controlState.owned = cell.controlState.owned || instance.identityUUID == context.requester.uuid
                if let resolve {
                    cell.controlState.resolverScope = resolve.cellScope
                    cell.controlState.scaffoldAvailable = true
                    cell.typeName = cell.typeName ?? resolve.cellType
                }
                appendProvenance(&cell.provenance, .init(source: .runtimeObservation, detail: instance.uuid, confidence: 0.95))
            }

            guard let emit = try? await context.resolver.cellAtEndpoint(endpoint: endpoint, requester: context.requester) else {
                continue
            }

            upsertCell(id: endpoint, cellsByID: &cellsByID) { cell in
                cell.typeName = String(describing: type(of: emit))
            }

            if let owner = try? await emit.getOwner(requester: context.requester), owner.uuid == context.requester.uuid {
                upsertCell(id: endpoint, cellsByID: &cellsByID) { cell in
                    cell.controlState.owned = true
                }
            }

            if let cellProtocol = emit as? any CellProtocol,
               let catalog = try? await cellProtocol.exploreContractCatalog(requester: context.requester) {
                upsertCell(id: endpoint, cellsByID: &cellsByID) { cell in
                    mergeUnique(into: &cell.capabilities, values: catalog.records.map(\.key))
                }
                for record in catalog.records {
                    relations.append(
                        EntityAtlasRelation(
                            fromID: endpoint,
                            kind: .providesCapability,
                            toID: "capability:\(record.key)",
                            explanation: "Capability derived from the cell's explore contract.",
                            provenance: [.init(source: .runtimeObservation, detail: record.id, confidence: 0.9)]
                        )
                    )
                }
            } else if let explorable = emit as? any Explore,
                      let keys = try? await explorable.keys(requester: context.requester) {
                upsertCell(id: endpoint, cellsByID: &cellsByID) { cell in
                    mergeUnique(into: &cell.capabilities, values: keys)
                }
            }

            if let describable = emit as? any EntityAtlasDescribing,
               let descriptor = try? await describable.entityAtlasDescriptor(requester: context.requester) {
                upsertCell(id: endpoint, cellsByID: &cellsByID) { cell in
                    if let title = descriptor.title, !title.isEmpty {
                        cell.title = title
                    }
                    if let summary = descriptor.summary, !summary.isEmpty {
                        cell.summary = summary
                    }
                    mergeUnique(into: &cell.purposes, values: descriptor.purposeRefs)
                    mergeUnique(into: &cell.dependencyRefs, values: descriptor.dependencyRefs.map(normalizeCellReference))
                    mergeUnique(into: &cell.requiredCredentialClasses, values: descriptor.requiredCredentialClasses)
                    mergeUnique(into: &cell.capabilities, values: descriptor.capabilityHints)
                    mergeUnique(into: &cell.knowledgeRoles, values: descriptor.knowledgeRoles)
                    appendProvenance(&cell.provenance, .init(source: .cellDescriptor, detail: descriptor.title ?? endpoint, confidence: 0.85))
                }
            }

            if let absorber = emit as? any Absorb,
               let statuses = try? await absorber.attachedStatuses(requester: context.requester) {
                let activeStatuses = statuses.filter { $0.active || $0.connected }
                if !activeStatuses.isEmpty {
                    upsertCell(id: endpoint, cellsByID: &cellsByID) { cell in
                        cell.controlState.runtimeAttached = true
                    }
                }
                for status in activeStatuses {
                    let dependencyID = normalizeCellReference(status.name)
                    upsertCell(id: endpoint, cellsByID: &cellsByID) { cell in
                        insertUnique(&cell.dependencyRefs, dependencyID)
                    }
                    relations.append(
                        EntityAtlasRelation(
                            fromID: endpoint,
                            kind: .runtimeAttached,
                            toID: dependencyID,
                            explanation: "Runtime attachment was observed on the absorber.",
                            provenance: [.init(source: .runtimeObservation, detail: status.name, confidence: 0.9)]
                        )
                    )
                }
            }
        }

        for cell in cellsByID.values.sorted(by: { $0.cellID < $1.cellID }) {
            if cell.controlState.owned {
                relations.append(
                    EntityAtlasRelation(
                        fromID: "entity:self",
                        kind: .owns,
                        toID: cell.cellID,
                        explanation: "The cell is controlled by the current identity.",
                        provenance: [.init(source: .runtimeObservation, detail: cell.runtimeUUID, confidence: 0.95)]
                    )
                )
            }
            if cell.controlState.scaffoldAvailable {
                relations.append(
                    EntityAtlasRelation(
                        fromID: "entity:self",
                        kind: .scaffoldAvailable,
                        toID: cell.cellID,
                        explanation: "The cell is discoverable through resolver registration or scaffold configuration.",
                        provenance: cell.provenance.filter { $0.source == .resolverRegistration || $0.source == .cellConfiguration }
                    )
                )
            }
            if cell.controlState.persistedAttachment {
                relations.append(
                    EntityAtlasRelation(
                        fromID: "entity:self",
                        kind: .persistedAttachment,
                        toID: cell.cellID,
                        explanation: "A persisted scaffold/configuration references this cell.",
                        provenance: cell.provenance.filter { $0.source == .cellConfiguration }
                    )
                )
            }
            for purpose in cell.purposes {
                relations.append(
                    EntityAtlasRelation(
                        fromID: cell.cellID,
                        kind: .solves,
                        toID: "purpose:\(purpose)",
                        explanation: "Purpose coverage declared by descriptor or configuration metadata.",
                        provenance: cell.provenance.filter { $0.source == .cellDescriptor || $0.source == .cellConfiguration }
                    )
                )
            }
            for dependency in cell.dependencyRefs {
                relations.append(
                    EntityAtlasRelation(
                        fromID: cell.cellID,
                        kind: .dependsOn,
                        toID: dependency,
                        explanation: "Dependency inferred from descriptor, runtime attachments, or cell configuration.",
                        provenance: cell.provenance
                    )
                )
            }
            for credentialClass in cell.requiredCredentialClasses {
                relations.append(
                    EntityAtlasRelation(
                        fromID: cell.cellID,
                        kind: .requiresCredential,
                        toID: "credentialClass:\(credentialClass)",
                        explanation: "Cell descriptor declares a required credential class.",
                        provenance: cell.provenance.filter { $0.source == .cellDescriptor }
                    )
                )
            }
            for role in cell.knowledgeRoles {
                relations.append(
                    EntityAtlasRelation(
                        fromID: cell.cellID,
                        kind: .knowsAbout,
                        toID: "knowledgeRole:\(role.rawValue)",
                        explanation: "Cell explicitly declares that it knows about or indexes other cells.",
                        provenance: cell.provenance.filter { $0.source == .cellDescriptor }
                    )
                )
            }
        }

        relations.append(contentsOf: documentRelations(from: context.documents))

        return EntityAtlasSnapshot(
            generatedAtEpochMs: Int(Date().timeIntervalSince1970 * 1000.0),
            cells: Array(cellsByID.values),
            scaffolds: scaffolds,
            promptDocuments: context.documents.promptDocuments,
            contextDocuments: context.documents.contextDocuments,
            assistantProfiles: context.documents.assistantProfiles,
            providerProfiles: context.documents.providerProfiles,
            credentialHandles: context.documents.credentialHandles,
            relations: dedupeRelations(relations)
        )
    }

    public func cells(forPurpose purposeRef: String, in snapshot: EntityAtlasSnapshot) -> [EntityAtlasCellRecord] {
        snapshot.cells
            .filter { $0.purposes.contains(purposeRef) }
            .sorted { $0.cellID < $1.cellID }
    }

    public func purposes(forCellID cellID: String, in snapshot: EntityAtlasSnapshot) -> [String] {
        snapshot.cells.first(where: { $0.cellID == cellID })?.purposes ?? []
    }

    public func cellsRequiringCredentials(in snapshot: EntityAtlasSnapshot) -> [EntityAtlasCellRecord] {
        snapshot.cells
            .filter { !$0.requiredCredentialClasses.isEmpty }
            .sorted { $0.cellID < $1.cellID }
    }

    public func scaffoldCandidates(forPurpose purposeRef: String, in snapshot: EntityAtlasSnapshot) -> [EntityAtlasCellRecord] {
        snapshot.cells
            .filter {
                $0.purposes.contains(purposeRef) &&
                $0.controlState.scaffoldAvailable &&
                !$0.controlState.owned
            }
            .sorted { $0.cellID < $1.cellID }
    }

    public func cellsKnowingAboutOtherCells(in snapshot: EntityAtlasSnapshot) -> [EntityAtlasCellRecord] {
        snapshot.cells
            .filter { !$0.knowledgeRoles.isEmpty }
            .sorted { $0.cellID < $1.cellID }
    }

    public func dependencies(forCellID cellID: String, in snapshot: EntityAtlasSnapshot) -> [EntityAtlasCellRecord] {
        guard let cell = snapshot.cells.first(where: { $0.cellID == cellID }) else {
            return []
        }
        let dependencySet = Set(cell.dependencyRefs)
        return snapshot.cells
            .filter { dependencySet.contains($0.cellID) }
            .sorted { $0.cellID < $1.cellID }
    }

    public func explainCoverage(for purposeRef: String, in snapshot: EntityAtlasSnapshot) -> EntityAtlasPurposeCoverageExplanation {
        let purposeCells = cells(forPurpose: purposeRef, in: snapshot)
        let supporting = purposeCells.filter { $0.controlState.owned || $0.controlState.runtimeAvailable }
        let scaffoldOnly = purposeCells.filter { !$0.controlState.owned && $0.controlState.scaffoldAvailable }

        if !supporting.isEmpty {
            return EntityAtlasPurposeCoverageExplanation(
                purposeRef: purposeRef,
                status: .covered,
                supportingCellIDs: supporting.map(\.cellID),
                scaffoldCandidateCellIDs: scaffoldOnly.map(\.cellID),
                blockedReasons: [],
                explanation: "The purpose is covered by owned or active cells."
            )
        }

        if !scaffoldOnly.isEmpty {
            return EntityAtlasPurposeCoverageExplanation(
                purposeRef: purposeRef,
                status: .partial,
                supportingCellIDs: [],
                scaffoldCandidateCellIDs: scaffoldOnly.map(\.cellID),
                blockedReasons: ["Only scaffold-available cells currently advertise this purpose."],
                explanation: "The purpose is only covered structurally and has not been validated by an owned active cell."
            )
        }

        let scaffoldRecords = snapshot.scaffolds.filter { $0.purposeRef == purposeRef }
        if !scaffoldRecords.isEmpty {
            return EntityAtlasPurposeCoverageExplanation(
                purposeRef: purposeRef,
                status: .partial,
                supportingCellIDs: [],
                scaffoldCandidateCellIDs: scaffoldRecords.compactMap { scaffold in
                    scaffold.sourceCellEndpoint ?? scaffold.sourceCellName.map(normalizeCellReference)
                },
                blockedReasons: ["Only scaffold configuration metadata references this purpose."],
                explanation: "The purpose is referenced in scaffold metadata, but no concrete cell descriptor or active cell currently covers it."
            )
        }

        return EntityAtlasPurposeCoverageExplanation(
            purposeRef: purposeRef,
            status: .blocked,
            supportingCellIDs: [],
            scaffoldCandidateCellIDs: [],
            blockedReasons: ["No resolver registration, cell descriptor, or scaffold configuration advertises this purpose."],
            explanation: "No evidence of purpose coverage was found in the current topology."
        )
    }

    private func documentRelations(from documents: AtlasVaultDocumentSnapshot) -> [EntityAtlasRelation] {
        var relations = [EntityAtlasRelation]()

        for profile in documents.assistantProfiles {
            let fromID = profile.nodeID
            if let providerProfileRef = profile.providerProfileRef, !providerProfileRef.isEmpty {
                relations.append(
                    EntityAtlasRelation(
                        fromID: fromID,
                        kind: .usesModelProvider,
                        toID: AtlasVaultDocumentKind.modelProviderProfile.nodePrefix + ":" + providerProfileRef,
                        explanation: "Assistant profile references a provider profile.",
                        provenance: [.init(source: .vaultDocument, detail: profile.id, confidence: 0.9)]
                    )
                )
            }
            for promptRef in profile.promptRefs {
                relations.append(
                    EntityAtlasRelation(
                        fromID: fromID,
                        kind: .usesPrompt,
                        toID: AtlasVaultDocumentKind.prompt.nodePrefix + ":" + promptRef,
                        explanation: "Assistant profile references a prompt document.",
                        provenance: [.init(source: .vaultDocument, detail: profile.id, confidence: 0.9)]
                    )
                )
            }
            for contextRef in profile.contextRefs {
                relations.append(
                    EntityAtlasRelation(
                        fromID: fromID,
                        kind: .usesContext,
                        toID: AtlasVaultDocumentKind.context.nodePrefix + ":" + contextRef,
                        explanation: "Assistant profile references a context document.",
                        provenance: [.init(source: .vaultDocument, detail: profile.id, confidence: 0.9)]
                    )
                )
            }
        }

        for provider in documents.providerProfiles {
            let fromID = provider.nodeID
            for handleRef in provider.credentialHandleRefs {
                relations.append(
                    EntityAtlasRelation(
                        fromID: fromID,
                        kind: .requiresCredential,
                        toID: AtlasVaultDocumentKind.credentialHandle.nodePrefix + ":" + handleRef,
                        explanation: "Provider profile references a credential handle.",
                        provenance: [.init(source: .vaultDocument, detail: provider.id, confidence: 0.9)]
                    )
                )
            }
        }

        return relations
    }

    private func primaryEndpoint(for configuration: CellConfiguration, references: [CellReference]) -> String? {
        if let endpoint = configuration.discovery?.sourceCellEndpoint, !endpoint.isEmpty {
            return normalizeCellReference(endpoint)
        }
        if let name = configuration.discovery?.sourceCellName, !name.isEmpty {
            return normalizeCellReference(name)
        }
        if references.count == 1, let endpoint = references.first?.endpoint {
            return normalizeCellReference(endpoint)
        }
        return nil
    }

    private func flattenReferences(from references: [CellReference]) -> [CellReference] {
        var flattened = [CellReference]()
        for reference in references {
            flattened.append(reference)
            flattened.append(contentsOf: flattenReferences(from: reference.subscriptions))
        }
        return flattened
    }

    private func normalizeCellReference(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "cell:///unknown" }
        if trimmed.contains("://") {
            return trimmed
        }
        return "cell:///\(trimmed)"
    }

    private func displayName(from raw: String) -> String {
        if raw.hasPrefix("cell:///") {
            return String(raw.dropFirst("cell:///".count))
        }
        return raw
    }

    private func upsertCell(id: String, cellsByID: inout [String: EntityAtlasCellRecord], mutate: (inout EntityAtlasCellRecord) -> Void) {
        var cell = cellsByID[id] ?? EntityAtlasCellRecord(cellID: id, name: displayName(from: id), endpoint: id)
        mutate(&cell)
        cell.purposes.sort()
        cell.capabilities.sort()
        cell.dependencyRefs.sort()
        cell.requiredCredentialClasses.sort()
        cell.knowledgeRoles.sort { $0.rawValue < $1.rawValue }
        cellsByID[id] = cell
    }

    private func insertUnique<T: Hashable>(_ array: inout [T], _ value: T) {
        guard !array.contains(value) else { return }
        array.append(value)
    }

    private func mergeUnique<T: Hashable>(into array: inout [T], values: [T]) {
        for value in values {
            insertUnique(&array, value)
        }
    }

    private func appendProvenance(_ provenance: inout [EntityAtlasProvenance], _ value: EntityAtlasProvenance) {
        guard !provenance.contains(value) else { return }
        provenance.append(value)
    }

    private func dedupeRelations(_ relations: [EntityAtlasRelation]) -> [EntityAtlasRelation] {
        var seen = Set<String>()
        return relations.filter { relation in
            let key = "\(relation.fromID)|\(relation.kind.rawValue)|\(relation.toID)|\(relation.explanation)"
            return seen.insert(key).inserted
        }
    }
}
