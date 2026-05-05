// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

private final class AtlasFixtureCell: GeneralCell, EntityAtlasDescribing {
    private let descriptorValue: EntityAtlasCellDescriptor

    required init(owner: Identity) async {
        self.descriptorValue = EntityAtlasCellDescriptor(
            title: "Fixture",
            summary: "Default fixture",
            purposeRefs: [],
            dependencyRefs: [],
            requiredCredentialClasses: [],
            capabilityHints: [],
            knowledgeRoles: []
        )
        await super.init(owner: owner)
        await registerFixtureContracts(owner: owner)
    }

    init(owner: Identity, descriptor: EntityAtlasCellDescriptor) async {
        self.descriptorValue = descriptor
        await super.init(owner: owner)
        await registerFixtureContracts(owner: owner)
    }

    required init(from decoder: Decoder) throws {
        fatalError("init(from:) has not been implemented")
    }

    func entityAtlasDescriptor(requester: Identity) async throws -> EntityAtlasCellDescriptor {
        descriptorValue
    }

    private func registerFixtureContracts(owner: Identity) async {
        agreementTemplate.addGrant("r---", for: "fixture")
        await registerExploreContract(
            requester: owner,
            key: "fixture.inspect",
            method: .get,
            input: .null,
            returns: ExploreContract.objectSchema(
                properties: ["status": ExploreContract.schema(type: "string")],
                requiredKeys: ["status"],
                description: "Fixture inspect response."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns fixture status.")
        )
    }
}

final class EntityAtlasProjectionTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    func testProjectionIsDeterministicAndSeparatesOwnedFromScaffold() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let resolver = MockCellResolver()
        let projection = EntityAtlasProjection()

        let ownedCell = await AtlasFixtureCell(
            owner: owner,
            descriptor: EntityAtlasCellDescriptor(
                title: "Owned Knowledge Cell",
                summary: "Indexes and reasons over local topology.",
                purposeRefs: ["purpose.relationship-map"],
                dependencyRefs: ["PromptLibrary"],
                requiredCredentialClasses: ["openai.api-key"],
                capabilityHints: ["graph.match"],
                knowledgeRoles: [.indexesCells, .describesCells]
            )
        )
        let promptLibrary = await AtlasFixtureCell(
            owner: owner,
            descriptor: EntityAtlasCellDescriptor(
                title: "Prompt Library",
                summary: "Provides prompt documents.",
                purposeRefs: [],
                dependencyRefs: [],
                requiredCredentialClasses: [],
                capabilityHints: ["prompt.list"],
                knowledgeRoles: []
            )
        )
        _ = try await ownedCell.attach(emitter: promptLibrary, label: "PromptLibrary", requester: owner)
        try await ownedCell.absorbFlow(label: "PromptLibrary", requester: owner)

        try await resolver.registerNamedEmitCell(name: "OwnedKnowledge", emitCell: ownedCell, scope: .identityUnique, identity: owner)
        try await resolver.registerNamedEmitCell(name: "PromptLibrary", emitCell: promptLibrary, scope: .scaffoldUnique, identity: owner)
        resolver.setResolveSnapshot(
            CellResolverResolveSnapshot(
                name: "OwnedKnowledge",
                cellType: "AtlasFixtureCell",
                cellScope: .identityUnique,
                persistancy: .persistant,
                identityDomain: "private",
                hasLifecyclePolicy: false
            )
        )
        resolver.setResolveSnapshot(
            CellResolverResolveSnapshot(
                name: "PromptLibrary",
                cellType: "AtlasFixtureCell",
                cellScope: .scaffoldUnique,
                persistancy: .ephemeral,
                identityDomain: "scaffold",
                hasLifecyclePolicy: false
            )
        )
        resolver.setResolveSnapshot(
            CellResolverResolveSnapshot(
                name: "ScaffoldOnly",
                cellType: "AtlasFixtureCell",
                cellScope: .template,
                persistancy: .ephemeral,
                identityDomain: "scaffold",
                hasLifecyclePolicy: false
            )
        )

        var scaffoldConfiguration = CellConfiguration(name: "Scaffold Candidate")
        scaffoldConfiguration.uuid = "cfg-scaffold-only"
        scaffoldConfiguration.discovery = CellConfigurationDiscovery(
            sourceCellName: "ScaffoldOnly",
            purpose: "purpose.scaffold-gap",
            purposeDescription: "Provides a scaffold-only fallback for the missing purpose.",
            interests: [],
            menuSlots: []
        )
        scaffoldConfiguration.cellReferences = [
            CellReference(endpoint: "PromptLibrary", label: "PromptLibrary")
        ]

        let documents = AtlasVaultDocumentSnapshot(
            assistantProfiles: [
                AtlasAssistantProfile(
                    id: "assistant.main",
                    title: "Main Assistant",
                    providerProfileRef: "provider.openai",
                    promptRefs: ["prompt.global"],
                    contextRefs: ["context.global"],
                    createdAtEpochMs: 1_000,
                    updatedAtEpochMs: 1_000
                )
            ],
            providerProfiles: [
                AtlasModelProviderProfile(
                    id: "provider.openai",
                    title: "OpenAI API",
                    providerID: "openai",
                    accessMode: .apiKey,
                    credentialHandleRefs: ["cred.openai"],
                    createdAtEpochMs: 1_000,
                    updatedAtEpochMs: 1_000
                )
            ],
            credentialHandles: [
                AtlasCredentialHandleRecord(
                    id: "cred.openai",
                    title: "OpenAI Credential",
                    providerID: "openai",
                    credentialClass: "openai.api-key",
                    accessMode: .apiKey,
                    label: "Primary OpenAI Key",
                    createdAtEpochMs: 1_000,
                    updatedAtEpochMs: 1_000
                )
            ]
        )

        let context = EntityAtlasProjectionContext(
            resolver: resolver,
            requester: owner,
            scaffoldConfigurations: [scaffoldConfiguration],
            documents: documents
        )

        let first = try await projection.build(context: context)
        let second = try await projection.build(context: context)
        XCTAssertEqual(first.cells, second.cells)
        XCTAssertEqual(first.scaffolds, second.scaffolds)
        XCTAssertEqual(first.relations, second.relations)

        let ownedRecord = try XCTUnwrap(first.cells.first(where: { $0.cellID == "cell:///OwnedKnowledge" }))
        XCTAssertTrue(ownedRecord.controlState.owned)
        XCTAssertTrue(ownedRecord.controlState.runtimeAvailable)
        XCTAssertTrue(ownedRecord.controlState.runtimeAttached)
        XCTAssertTrue(ownedRecord.controlState.absorbed)
        XCTAssertEqual(ownedRecord.requiredCredentialClasses, ["openai.api-key"])
        XCTAssertEqual(ownedRecord.knowledgeRoles, [.describesCells, .indexesCells])
        XCTAssertTrue(ownedRecord.capabilities.contains("fixture.inspect"))
        XCTAssertTrue(ownedRecord.capabilities.contains("graph.match"))
        XCTAssertTrue(ownedRecord.dependencyRefs.contains("cell:///PromptLibrary"))

        let scaffoldOnly = try XCTUnwrap(first.cells.first(where: { $0.cellID == "cell:///ScaffoldOnly" }))
        XCTAssertFalse(scaffoldOnly.controlState.owned)
        XCTAssertTrue(scaffoldOnly.controlState.scaffoldAvailable)
        XCTAssertFalse(scaffoldOnly.controlState.runtimeAvailable)
        XCTAssertFalse(scaffoldOnly.controlState.runtimeAttached)
        XCTAssertFalse(scaffoldOnly.controlState.absorbed)

        let knowledgeCells = projection.cellsKnowingAboutOtherCells(in: first)
        XCTAssertEqual(knowledgeCells.map(\.cellID), ["cell:///OwnedKnowledge"])

        let credentialCells = projection.cellsRequiringCredentials(in: first)
        XCTAssertEqual(credentialCells.map(\.cellID), ["cell:///OwnedKnowledge"])

        let covered = projection.explainCoverage(for: "purpose.relationship-map", in: first)
        XCTAssertEqual(covered.status, .covered)
        XCTAssertEqual(covered.supportingCellIDs, ["cell:///OwnedKnowledge"])

        let partial = projection.explainCoverage(for: "purpose.scaffold-gap", in: first)
        XCTAssertEqual(partial.status, .partial)
        XCTAssertEqual(partial.scaffoldCandidateCellIDs, ["cell:///ScaffoldOnly"])

        XCTAssertTrue(first.relations.contains { relation in
            relation.fromID == "atlas.assistantProfile:assistant.main" && relation.kind == .usesModelProvider
        })
        XCTAssertTrue(first.relations.contains { relation in
            relation.fromID == "atlas.modelProviderProfile:provider.openai" && relation.kind == .requiresCredential
        })
    }

    func testVaultSyncPromptResolutionAndSecretIsolation() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let vaultCell = await VaultCell(owner: owner)
        let repository = AtlasVaultDocumentRepository()
        let resolver = AtlasPromptResolver()
        let exporter = EntityAtlasExporter()
        let atlasService = EntityAtlasService(repository: repository, exporter: exporter)
        let secureStore = InMemorySecureCredentialStore()
        let credentialService = CredentialVaultService(repository: repository, secureStore: secureStore)

        let entityPrompt = AtlasPromptDocument(
            id: "prompt.global",
            title: "Global Prompt",
            scope: AtlasDocumentScope(kind: .entity),
            body: "You are operating on the local entity topology.",
            createdAtEpochMs: 1_000,
            updatedAtEpochMs: 1_000
        )
        let assistantPrompt = AtlasPromptDocument(
            id: "prompt.assistant",
            title: "Assistant Prompt",
            scope: AtlasDocumentScope(kind: .assistant, reference: "assistant.main"),
            body: "Prefer explicit topology and deterministic data.",
            createdAtEpochMs: 1_100,
            updatedAtEpochMs: 1_100
        )
        let purposePrompt = AtlasPromptDocument(
            id: "prompt.purpose",
            title: "Purpose Prompt",
            scope: AtlasDocumentScope(kind: .purpose, reference: "purpose.relationship-map"),
            body: "Explain why coverage exists or does not exist.",
            createdAtEpochMs: 1_200,
            updatedAtEpochMs: 1_200
        )
        let cellPrompt = AtlasPromptDocument(
            id: "prompt.cell",
            title: "Cell Prompt",
            scope: AtlasDocumentScope(kind: .cell, reference: "cell:///OwnedKnowledge"),
            body: "Inspect the knowledge cell before proposing changes.",
            createdAtEpochMs: 1_300,
            updatedAtEpochMs: 1_300
        )
        let entityContext = AtlasContextDocument(
            id: "context.global",
            title: "Global Context",
            scope: AtlasDocumentScope(kind: .entity),
            body: "Local-first. Privacy-preserving.",
            blockIDs: ["entity-topology", "privacy"],
            createdAtEpochMs: 1_000,
            updatedAtEpochMs: 1_000
        )
        let assistantContext = AtlasContextDocument(
            id: "context.assistant",
            title: "Assistant Context",
            scope: AtlasDocumentScope(kind: .assistant, reference: "assistant.main"),
            body: "Use atlas queries before free-form reasoning.",
            createdAtEpochMs: 1_050,
            updatedAtEpochMs: 1_050
        )
        let assistantProfile = AtlasAssistantProfile(
            id: "assistant.main",
            title: "Main Assistant",
            providerProfileRef: "provider.openai",
            promptRefs: ["prompt.assistant"],
            contextRefs: ["context.assistant"],
            executionPolicy: "atlas-first",
            createdAtEpochMs: 1_400,
            updatedAtEpochMs: 1_400
        )
        let providerProfile = AtlasModelProviderProfile(
            id: "provider.openai",
            title: "OpenAI API",
            providerID: "openai",
            accessMode: .apiKey,
            allowedModels: ["gpt-5"],
            credentialHandleRefs: ["cred.openai"],
            createdAtEpochMs: 1_450,
            updatedAtEpochMs: 1_450
        )
        let handle = AtlasCredentialHandleRecord(
            id: "cred.openai",
            title: "OpenAI Key",
            providerID: "openai",
            credentialClass: "openai.api-key",
            accessMode: .apiKey,
            label: "Primary Key",
            createdAtEpochMs: 1_500,
            updatedAtEpochMs: 1_500
        )

        try await repository.upsert(entityPrompt, in: vaultCell, requester: owner)
        try await repository.upsert(assistantPrompt, in: vaultCell, requester: owner)
        try await repository.upsert(purposePrompt, in: vaultCell, requester: owner)
        try await repository.upsert(cellPrompt, in: vaultCell, requester: owner)
        try await repository.upsert(entityContext, in: vaultCell, requester: owner)
        try await repository.upsert(assistantContext, in: vaultCell, requester: owner)
        try await repository.upsert(assistantProfile, in: vaultCell, requester: owner)
        try await repository.upsert(providerProfile, in: vaultCell, requester: owner)
        try await credentialService.createHandle(handle, secret: Data("super-secret".utf8), in: vaultCell, requester: owner)

        let olderPrompt = AtlasPromptDocument(
            id: "prompt.assistant",
            title: "Assistant Prompt",
            scope: AtlasDocumentScope(kind: .assistant, reference: "assistant.main"),
            body: "Older content",
            createdAtEpochMs: 1_100,
            updatedAtEpochMs: 1_050
        )
        let skipped = try await repository.sync([olderPrompt], into: vaultCell, requester: owner)
        XCTAssertEqual(skipped.skipped, 1)

        let newerPrompt = AtlasPromptDocument(
            id: "prompt.assistant",
            title: "Assistant Prompt",
            scope: AtlasDocumentScope(kind: .assistant, reference: "assistant.main"),
            body: "Prefer explicit topology and deterministic data. Avoid hidden state.",
            createdAtEpochMs: 1_100,
            updatedAtEpochMs: 1_600
        )
        let updated = try await repository.sync([newerPrompt], into: vaultCell, requester: owner)
        XCTAssertEqual(updated.updated, 1)

        let snapshot = try await repository.loadAll(from: vaultCell, requester: owner)
        XCTAssertEqual(snapshot.promptDocuments.map(\.id), ["prompt.assistant", "prompt.cell", "prompt.global", "prompt.purpose"])
        XCTAssertEqual(snapshot.contextDocuments.map(\.id), ["context.assistant", "context.global"])
        XCTAssertEqual(snapshot.assistantProfiles.map(\.id), ["assistant.main"])
        XCTAssertEqual(snapshot.providerProfiles.map(\.id), ["provider.openai"])
        XCTAssertEqual(snapshot.credentialHandles.map(\.id), ["cred.openai"])

        let resolved = resolver.resolve(
            assistantProfile: assistantProfile,
            promptDocuments: snapshot.promptDocuments,
            contextDocuments: snapshot.contextDocuments,
            purposeRef: "purpose.relationship-map",
            cellRefs: ["cell:///OwnedKnowledge"],
            sessionPromptOverrides: [
                AtlasPromptDocument(
                    id: "prompt.session",
                    title: "Session Prompt",
                    scope: AtlasDocumentScope(kind: .session, reference: "session-1"),
                    body: "This session is debugging atlas coverage.",
                    createdAtEpochMs: 1_700,
                    updatedAtEpochMs: 1_700
                )
            ]
        )

        XCTAssertEqual(
            resolved.sections.map { "\($0.layer.rawValue):\($0.sourceID)" },
            [
                "entity:prompt.global",
                "entity:context.global",
                "assistant:prompt.assistant",
                "assistant:context.assistant",
                "purpose:prompt.purpose",
                "cell:prompt.cell",
                "sessionOverride:prompt.session"
            ]
        )
        XCTAssertTrue(resolved.assembledText.contains("Global Prompt"))
        XCTAssertTrue(resolved.assembledText.contains("Session Prompt"))
        XCTAssertTrue(resolved.explain.first?.contains("entity prompt") == true)

        guard let rawHandleResponse = try await vaultCell.set(
            keypath: "vault.note.get",
            value: try VaultCellCodec.encode(["id": "cred.openai"]),
            requester: owner
        ) else {
            XCTFail("Expected raw handle note")
            return
        }

        guard case let .object(root) = rawHandleResponse,
              case let .object(result)? = root["result"],
              case let .string(content)? = result["content"] else {
            XCTFail("Expected note content payload")
            return
        }

        XCTAssertFalse(content.contains("super-secret"))
        let encodedHandleData = try JSONEncoder().encode(handle)
        let encodedHandleText = String(decoding: encodedHandleData, as: UTF8.self)
        XCTAssertFalse(encodedHandleText.contains("super-secret"))

        let recoveredSecret = try await credentialService.secret(for: "cred.openai")
        XCTAssertEqual(recoveredSecret, Data("super-secret".utf8))

        let mockResolver = MockCellResolver()
        mockResolver.setResolveSnapshot(
            CellResolverResolveSnapshot(
                name: "Vault",
                cellType: "VaultCell",
                cellScope: .identityUnique,
                persistancy: .persistant,
                identityDomain: "private",
                hasLifecyclePolicy: false
            )
        )
        try await mockResolver.registerNamedEmitCell(name: "Vault", emitCell: vaultCell, scope: .identityUnique, identity: owner)

        let atlasSnapshot = try await atlasService.buildSnapshot(
            resolver: mockResolver,
            requester: owner,
            scaffoldConfigurations: [],
            vaultCell: vaultCell
        )
        let redactedJSON = try atlasService.exportRedactedJSON(snapshot: atlasSnapshot)
        let redactedMarkdown = atlasService.exportRedactedMarkdown(snapshot: atlasSnapshot)

        XCTAssertTrue(redactedJSON.contains("\"credentialHandles\""))
        XCTAssertTrue(redactedJSON.contains("\"metadataKeys\""))
        XCTAssertTrue(redactedMarkdown.contains("# Entity Atlas (Redacted)"))
        XCTAssertTrue(redactedMarkdown.contains("cred.openai"))
        XCTAssertFalse(redactedJSON.contains("super-secret"))
        XCTAssertFalse(redactedMarkdown.contains("super-secret"))
        XCTAssertFalse(redactedJSON.contains("Prefer explicit topology and deterministic data. Avoid hidden state."))
        XCTAssertTrue(atlasSnapshot.cells.contains { $0.cellID == "cell:///Vault" })

        let previewJSON = try exporter.redactedJSON(
            snapshot: atlasSnapshot,
            policy: EntityAtlasExportPolicy(
                includeDocumentBodyPreviews: true,
                documentBodyPreviewCharacterLimit: 24,
                includeRelationExplanations: true
            )
        )
        XCTAssertTrue(previewJSON.contains("Prefer explicit topology..."))
        XCTAssertFalse(previewJSON.contains("super-secret"))
    }
}
