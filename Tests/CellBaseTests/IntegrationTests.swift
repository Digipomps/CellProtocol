// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@_spi(HAVENRuntime) @_spi(Testing) @testable import CellBase
@_spi(Testing) import CellApple

final class IntegrationTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousDocumentRoot: String?
    private var previousDebugFlag: Bool = false

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousDocumentRoot = CellBase.documentRootPath
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.defaultIdentityVault = nil
        CellBase.debugValidateAccessForEverything = true
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.documentRootPath = previousDocumentRoot
        CellBase.debugValidateAccessForEverything = previousDebugFlag
        super.tearDown()
    }

    func testAppInitializerBootstrapsResolverAndVault() async throws {
        await AppInitializer.initialize()
        XCTAssertTrue(CellBase.defaultIdentityVault is EphemeralIdentityVault)
        XCTAssertNotNil(CellBase.defaultCellResolver)
    }

    func testPortholeSkeletonDescriptionDecodes() throws {
        let config = SkeletonDescriptions.skeletonDescriptionFromJson()
        XCTAssertNotNil(config.skeleton)
    }

    @MainActor
    func testPersistedPortholeCannotCrossSigningIdentityOrDowngradeEncryptedStorage() async throws {
        CellBase.debugValidateAccessForEverything = false
        let resolver = CellResolver.sharedInstance
        let previousTypedUtility = resolver.tcUtility
        let previousGlobalTypedUtility = CellBase.typedCellUtility
        let previousMasterKey = CellBase.persistedCellMasterKey
        addTeardownBlock { @MainActor in
            await AppInitializer.resetRuntimeStateForTesting()
            await resolver.resetRuntimeStateForTesting()
            resolver.tcUtility = previousTypedUtility
            CellBase.typedCellUtility = previousGlobalTypedUtility
            CellBase.persistedCellMasterKey = previousMasterKey
        }
        await AppInitializer.resetRuntimeStateForTesting()
        await resolver.resetRuntimeStateForTesting()

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-initializer-porthole-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver
        CellBase.documentRootPath = tempRoot.path
        CellBase.persistedCellMasterKey = Data(repeating: 0x37, count: 32)

        let resolvedOwnerA = await vault.identity(for: "owner-a", makeNewIfNotFound: true)
        let resolvedOwnerB = await vault.identity(for: "owner-b", makeNewIfNotFound: true)
        let ownerA = try XCTUnwrap(resolvedOwnerA)
        let ownerB = try XCTUnwrap(resolvedOwnerB)

        let firstUtility = TypedCellUtility(storage: FileSystemCellStorage())
        resolver.tcUtility = firstUtility
        CellBase.typedCellUtility = firstUtility
        try await resolver.addCellResolve(
            name: "Porthole",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "owner-a",
            type: OrchestratorCell.self
        )
        let resolvedOwnerAPorthole = try await resolver.cellAtEndpoint(
            endpoint: "cell:///Porthole",
            requester: ownerA
        ) as? OrchestratorCell
        let ownerAPorthole = try XCTUnwrap(resolvedOwnerAPorthole)

        let ownerADirectory = tempRoot
            .appendingPathComponent("CellsContainer")
            .appendingPathComponent(ownerAPorthole.uuid)
        let encryptedCellURL = ownerADirectory.appendingPathComponent("typedCell.json")
        let encryptedBefore = try Data(contentsOf: encryptedCellURL)
        XCTAssertTrue(encryptedBefore.starts(with: Data("CELLENC1".utf8)))

        // Readiness-before-owner-validation would import this mapping into the
        // process-wide resolver even though owner B cannot prove owner A.
        let poisonMappings = [
            ownerA.uuid: ["OwnerOnly": ownerAPorthole.uuid],
            ownerB.uuid: ["Poison": ownerAPorthole.uuid]
        ]
        try JSONEncoder().encode(poisonMappings).write(
            to: ownerADirectory.appendingPathComponent("IdentityNamedEmitters.json")
        )

        // A temporarily unavailable encrypted Porthole is not equivalent to
        // a missing Cell. Preserve its pointer and state instead of silently
        // creating a replacement that hides the existing persisted surface.
        await AppInitializer.resetRuntimeStateForTesting(
            scaffoldCells: ["Porthole": ownerAPorthole.uuid]
        )
        await resolver.resetRuntimeStateForTesting()
        let unavailableUtility = TypedCellUtility(storage: FileSystemCellStorage())
        resolver.tcUtility = unavailableUtility
        CellBase.typedCellUtility = unavailableUtility
        try await resolver.addCellResolve(
            name: "Porthole",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "owner-a",
            type: OrchestratorCell.self
        )
        CellBase.persistedCellMasterKey = Data(repeating: 0x99, count: 32)
        do {
            _ = try await AppInitializer.getPorthole(identity: ownerA)
            XCTFail("Expected encrypted Porthole load to fail closed with the wrong storage key")
        } catch CellSetupError.persistedCellUnavailable {
            // Expected: no replacement may be created for unavailable data.
        } catch {
            XCTFail("Unexpected unavailable Porthole error: \(error)")
        }
        let unavailableMappings = await resolver.identityNamedCells(requester: ownerA)
        XCTAssertTrue(unavailableMappings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: encryptedCellURL), encryptedBefore)
        CellBase.persistedCellMasterKey = Data(repeating: 0x37, count: 32)

        // A decoded Porthole may already have been rebound to its owner when
        // the process-wide vault becomes temporarily unavailable. Restoring
        // owner-scoped mappings must fail readiness in that state so a later
        // call can retry instead of permanently marking a partial install as
        // ready.
        await resolver.resetRuntimeStateForTesting()
        let retryUtility = TypedCellUtility(storage: FileSystemCellStorage())
        resolver.tcUtility = retryUtility
        CellBase.typedCellUtility = retryUtility
        try await resolver.addCellResolve(
            name: "Porthole",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "owner-a",
            type: OrchestratorCell.self
        )
        let retryLoad = retryUtility.loadTypedEmitCellResult(
            at: "CellsContainer/\(ownerAPorthole.uuid)"
        )
        guard case .loaded(let retryLoadedCell) = retryLoad,
              let retryPorthole = retryLoadedCell as? OrchestratorCell else {
            return XCTFail("Expected raw persisted Porthole decode for readiness retry")
        }
        let reboundToOwner = await retryPorthole.bindStoredOwnerToRuntimeIdentity(ownerA)
        XCTAssertTrue(reboundToOwner)
        CellBase.defaultIdentityVault = nil
        do {
            try await retryPorthole.ensureRuntimeReady()
            XCTFail("Expected missing runtime-owner authority to fail readiness")
        } catch CellSetupError.ownerAuthorityUnavailable {
            // Expected: the coordinator must leave readiness retryable.
        } catch {
            XCTFail("Unexpected owner-authority readiness error: \(error)")
        }
        let mappingsAfterFailedReadiness = await resolver.identityNamedCells(requester: ownerA)
        XCTAssertTrue(mappingsAfterFailedReadiness.isEmpty)

        CellBase.defaultIdentityVault = vault
        try await retryPorthole.ensureRuntimeReady()
        let mappingsAfterReadinessRetry = await resolver.identityNamedCells(requester: ownerA)
        XCTAssertEqual(
            mappingsAfterReadinessRetry[ownerA.uuid]?["OwnerOnly"],
            ownerAPorthole.uuid
        )
        XCTAssertNil(mappingsAfterReadinessRetry[ownerB.uuid]?["Poison"])

        await resolver.resetRuntimeStateForTesting()
        let restartedUtility = TypedCellUtility(storage: FileSystemCellStorage())
        resolver.tcUtility = restartedUtility
        CellBase.typedCellUtility = restartedUtility
        try await resolver.addCellResolve(
            name: "Porthole",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "owner-a",
            type: OrchestratorCell.self
        )
        await AppInitializer.resetRuntimeStateForTesting(
            scaffoldCells: ["Porthole": ownerAPorthole.uuid]
        )

        let resolvedRestoredOwnerAPorthole: OrchestratorCell?
        do {
            resolvedRestoredOwnerAPorthole = try await AppInitializer.getPorthole(identity: ownerA)
        } catch {
            XCTFail("Owner A restore unexpectedly failed: \(error)")
            return
        }
        let restoredOwnerAPorthole = try XCTUnwrap(resolvedRestoredOwnerAPorthole)
        let ownerMappingsAfterRestore = await resolver.identityNamedCells(requester: ownerA)
        XCTAssertEqual(restoredOwnerAPorthole.uuid, ownerAPorthole.uuid)
        XCTAssertEqual(ownerMappingsAfterRestore[ownerA.uuid]?["OwnerOnly"], ownerAPorthole.uuid)
        XCTAssertNil(ownerMappingsAfterRestore[ownerB.uuid]?["Poison"])

        await resolver.resetRuntimeStateForTesting()
        let secondRestartedUtility = TypedCellUtility(storage: FileSystemCellStorage())
        resolver.tcUtility = secondRestartedUtility
        CellBase.typedCellUtility = secondRestartedUtility
        try await resolver.addCellResolve(
            name: "Porthole",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "owner-a",
            type: OrchestratorCell.self
        )
        await AppInitializer.resetRuntimeStateForTesting(
            scaffoldCells: ["Porthole": ownerAPorthole.uuid]
        )

        let resolvedOwnerBPorthole: OrchestratorCell?
        do {
            resolvedOwnerBPorthole = try await AppInitializer.getPorthole(identity: ownerB)
        } catch {
            XCTFail("Owner B isolation/replacement unexpectedly failed: \(error)")
            return
        }
        let ownerBPorthole = try XCTUnwrap(resolvedOwnerBPorthole)
        let restoredOwner = try await ownerBPorthole.getOwner(requester: ownerB)
        let mappingsAfterRestore = await resolver.identityNamedCells(requester: ownerB)
        let encryptedAfter = try Data(contentsOf: encryptedCellURL)

        XCTAssertNotEqual(ownerAPorthole.uuid, ownerBPorthole.uuid)
        XCTAssertTrue(restoredOwner.referencesSameSigningIdentity(as: ownerB))
        XCTAssertNil(mappingsAfterRestore[ownerB.uuid]?["Poison"])
        XCTAssertNil(mappingsAfterRestore[ownerA.uuid]?["OwnerOnly"])
        XCTAssertEqual(encryptedAfter, encryptedBefore)

        let ownerBEncryptedURL = tempRoot
            .appendingPathComponent("CellsContainer")
            .appendingPathComponent(ownerBPorthole.uuid)
            .appendingPathComponent("typedCell.json")
        let ownerBEncrypted = try Data(contentsOf: ownerBEncryptedURL)
        XCTAssertTrue(ownerBEncrypted.starts(with: Data("CELLENC1".utf8)))
    }

    @MainActor
    func testEntityScannerRegistrationIsIdempotentAndHasNoBootstrapSideEffects() async throws {
        let resolver = CellResolver.sharedInstance
        await AppInitializer.resetRuntimeStateForTesting()
        await resolver.resetRuntimeStateForTesting()
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        try await AppInitializer.registerEntityScannerResolve(on: resolver)
        try await AppInitializer.registerEntityScannerResolve(on: resolver)

        let resolvedRequester = await vault.identity(
            for: "scanner-audit",
            makeNewIfNotFound: true
        )
        let requester = try XCTUnwrap(resolvedRequester)
        let snapshot = await resolver.resolverRegistrySnapshot(requester: requester)
        let scannerResolves = snapshot.resolves.filter { $0.name == "EntityScanner" }
        XCTAssertEqual(scannerResolves.count, 1)
        XCTAssertTrue(scannerResolves[0].cellType.contains("EntityScannerCell"))
        XCTAssertFalse(snapshot.resolves.contains { $0.name == "Porthole" })
        XCTAssertTrue(snapshot.sharedNamedInstances.isEmpty)
        XCTAssertTrue(snapshot.identityNamedInstances.isEmpty)
        XCTAssertTrue(CellBase.defaultIdentityVault is MockIdentityVault)
    }

    func testFlowThroughResolverAndPusherCell() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!

        // Register a test cell and fetch it through resolver
        let name = "FlowTest-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .scaffoldUnique, identityDomain: "private", type: GeneralCell.self)
        let cell = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: owner)

        // Attach a pusher and ensure it can push a flow element without errors
        let pusher = FlowElementPusherCell(owner: owner)
        let absorb = cell as? Absorb
        XCTAssertNotNil(absorb)
        let state = try await absorb?.attach(emitter: pusher, label: "push", requester: owner)
        XCTAssertEqual(state, .connected)
        try await absorb?.absorbFlow(label: "push", requester: owner)

        let flow = try await cell.flow(requester: owner)
        let expectation = expectation(description: "Receive flow element")
        let cancellable = flow.sink(receiveCompletion: { _ in },
                                    receiveValue: { element in
                                        if element.title == "test" {
                                            expectation.fulfill()
                                        }
                                    })

        let element = FlowElement(title: "test", content: .string("payload"), properties: .init(type: .event, contentType: .string))
        pusher.pushFlowElement(element, requester: owner)

        await fulfillment(of: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testWaitableFlowDisconnectCompletesBeforeStatusRefresh() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "waitable-disconnect", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let pusher = FlowElementPusherCell(owner: owner)

        let state = try await cell.attach(emitter: pusher, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell.absorbFlow(label: "source", requester: owner)
        var status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.connected)
        XCTAssertTrue(status.active)
        var statuses = try await cell.attachedStatuses(requester: owner)
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses.first?.name, "source")
        XCTAssertEqual(statuses.first?.active, true)

        await cell.dropFlowAndWait(label: "source", requester: owner)
        status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.connected)
        XCTAssertFalse(status.active)
        statuses = try await cell.attachedStatuses(requester: owner)
        XCTAssertEqual(statuses.first?.active, false)

        await cell.detachAndWait(label: "source", requester: owner)
        status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertFalse(status.connected)
        XCTAssertFalse(status.active)
        statuses = try await cell.attachedStatuses(requester: owner)
        XCTAssertTrue(statuses.isEmpty)
    }
}
