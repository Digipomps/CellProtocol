// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@_spi(HAVENRuntime) @_spi(Testing) @testable import CellBase
@_spi(Testing) import CellApple
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

final class IntegrationTests: XCTestCase {
    private enum TestFlowSetupError: Error {
        case expected
    }

    private enum FlowSetupOutcome: Equatable {
        case success
        case cancelled
        case expectedFailure
        case otherFailure
    }

    private actor CompletionFlag {
        private var completed = false

        func markCompleted() {
            completed = true
        }

        func isCompleted() -> Bool {
            completed
        }
    }

    private actor OneShotAccessGate {
        private var attempts = 0

        func allowOnlyFirstAttempt() -> Bool {
            attempts += 1
            return attempts == 1
        }

        func attemptCount() -> Int {
            attempts
        }
    }

    private final class OneShotDisconnectAccessCell: GeneralCell {
        let accessGate = OneShotAccessGate()

        override func validateCellSpecificAccess(
            _ requestedAccess: String,
            at keypath: String,
            for identity: Identity
        ) async -> Bool {
            guard requestedAccess == "-w--", keypath == "source" else {
                return false
            }
            return await accessGate.allowOnlyFirstAttempt()
        }
    }

    private actor SuspendedFlowGate {
        private var entered = false
        private var entries = 0
        private var entryWaiters = [CheckedContinuation<Void, Never>]()
        private var releaseWaiters = [CheckedContinuation<Void, Never>]()

        func suspendUntilReleased() async {
            entered = true
            entries += 1
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilEntered() async {
            guard entered == false else { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func release() {
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }

        func entryCount() -> Int {
            entries
        }
    }

    private final class SuspendedFlowEmitter: GeneralCell {
        let flowGate = SuspendedFlowGate()
        private let controlledPublisher = PassthroughSubject<FlowElement, Error>()

        override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
            await flowGate.suspendUntilReleased()
            return controlledPublisher.eraseToAnyPublisher()
        }

        func emit(_ element: FlowElement) {
            controlledPublisher.send(element)
        }
    }

    private final class FailingSuspendedFlowEmitter: GeneralCell {
        let flowGate = SuspendedFlowGate()

        override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
            await flowGate.suspendUntilReleased()
            throw TestFlowSetupError.expected
        }
    }

    private final class LockedCancellationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func snapshot() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private final class LockedCancellationHandler: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (() -> Void)?

        func set(_ handler: @escaping () -> Void) {
            lock.lock()
            self.handler = handler
            lock.unlock()
        }

        func clear() {
            lock.lock()
            handler = nil
            lock.unlock()
        }

        func run() {
            lock.lock()
            let handler = self.handler
            lock.unlock()
            handler?()
        }
    }

    private final class CancellationObservingEmitter: GeneralCell {
        let cancellationCounter = LockedCancellationCounter()
        let cancellationHandler = LockedCancellationHandler()
        private let observedPublisher = PassthroughSubject<FlowElement, Error>()

        override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
            observedPublisher
                .handleEvents(receiveCancel: { [cancellationCounter, cancellationHandler] in
                    cancellationCounter.increment()
                    cancellationHandler.run()
                })
                .eraseToAnyPublisher()
        }

        func emit(_ element: FlowElement) {
            observedPublisher.send(element)
        }
    }

    private final class SuspendedSynchronousBurstEmitter: GeneralCell {
        let flowGate = SuspendedFlowGate()

        override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
            await flowGate.suspendUntilReleased()
            return (0...GeneralCell.flowEventBufferLimit).map { index in
                FlowElement(
                    title: "setup-burst-\(index)",
                    content: .string(String(index)),
                    properties: .init(type: .event, contentType: .string)
                )
            }
            .publisher
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
        }
    }

    private actor RotatingFlowPublisherStore {
        private var currentPublisher: PassthroughSubject<FlowElement, Error>?

        func makePublisher() -> AnyPublisher<FlowElement, Error> {
            let publisher = PassthroughSubject<FlowElement, Error>()
            currentPublisher = publisher
            return publisher.eraseToAnyPublisher()
        }

        func complete() {
            currentPublisher?.send(completion: .finished)
        }

        func emit(_ element: FlowElement) {
            currentPublisher?.send(element)
        }

        func emitBurst(count: Int) {
            for index in 0..<count {
                currentPublisher?.send(
                    FlowElement(
                        title: "burst-\(index)",
                        content: .string(String(index)),
                        properties: .init(type: .event, contentType: .string)
                    )
                )
            }
        }
    }

    private final class RotatingFlowEmitter: GeneralCell {
        private let publisherStore = RotatingFlowPublisherStore()

        override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
            await publisherStore.makePublisher()
        }

        func complete() async {
            await publisherStore.complete()
        }

        func emit(_ element: FlowElement) async {
            await publisherStore.emit(element)
        }

        func emitBurst(count: Int) async {
            await publisherStore.emitBurst(count: count)
        }
    }

    private final class SingleValueFlowEmitter: GeneralCell {
        private var element: FlowElement

        required init(owner: Identity) async {
            element = FlowElement(
                title: "single-value",
                content: .string("default"),
                properties: .init(type: .event, contentType: .string)
            )
            await super.init(owner: owner)
        }

        init(owner: Identity, element: FlowElement) async {
            self.element = element
            await super.init(owner: owner)
        }

        required init(from decoder: Decoder) throws {
            element = FlowElement(
                title: "decoded-single-value",
                content: .string("decoded"),
                properties: .init(type: .event, contentType: .string)
            )
            try super.init(from: decoder)
        }

        override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
            Just(element)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
    }

    private final class LockedEventTitles: @unchecked Sendable {
        private let lock = NSLock()
        private var titles = [String]()

        @discardableResult
        func append(_ title: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            titles.append(title)
            return titles.count
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return titles
        }
    }

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

    func testWaitableDetachWaitsForInFlightDownstreamDelivery() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "waitable-detach-in-flight-delivery", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = await RotatingFlowEmitter(owner: owner)
        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell.absorbFlow(label: "source", requester: owner)

        let deliveryEntered = expectation(description: "Downstream delivery entered")
        let deliveryFinished = expectation(description: "Downstream delivery finished")
        let releaseDelivery = DispatchSemaphore(value: 0)
        let outputCancellable = try await cell.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                guard element.title == "in-flight-delivery" else { return }
                deliveryEntered.fulfill()
                _ = releaseDelivery.wait(timeout: .now() + 1.0)
                deliveryFinished.fulfill()
            }
        )
        await emitter.emit(
            FlowElement(
                title: "in-flight-delivery",
                content: .string("value"),
                properties: .init(type: .event, contentType: .string)
            )
        )
        await fulfillment(of: [deliveryEntered], timeout: 0.3)

        let detachCompleted = CompletionFlag()
        let detachTask = Task {
            await cell.detachAndWait(label: "source", requester: owner)
            await detachCompleted.markCompleted()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let completedBeforeDeliveryFinished = await detachCompleted.isCompleted()
        XCTAssertFalse(completedBeforeDeliveryFinished)

        releaseDelivery.signal()
        await fulfillment(of: [deliveryFinished], timeout: 0.3)
        await detachTask.value
        let finalStatus = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertFalse(finalStatus.connected)
        XCTAssertFalse(finalStatus.active)
        outputCancellable.cancel()
    }

    func testWaitableDetachCancelsUpstreamWhileDrainingDownstreamDelivery() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "detach-cancel-unblocks-delivery", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = await CancellationObservingEmitter(owner: owner)
        let cancellationSignal = DispatchSemaphore(value: 0)
        emitter.cancellationHandler.set {
            cancellationSignal.signal()
        }
        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell.absorbFlow(label: "source", requester: owner)

        let deliveryEntered = expectation(description: "Delivery waits for upstream cancellation")
        let deliveryFinished = expectation(description: "Upstream cancellation unblocks delivery")
        let waitResults = LockedEventTitles()
        let outputCancellable = try await cell.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                guard element.title == "wait-for-cancel" else { return }
                deliveryEntered.fulfill()
                let result = cancellationSignal.wait(timeout: .now() + 1.0)
                waitResults.append(result == .success ? "cancelled" : "timed-out")
                deliveryFinished.fulfill()
            }
        )
        emitter.emit(
            FlowElement(
                title: "wait-for-cancel",
                content: .string("value"),
                properties: .init(type: .event, contentType: .string)
            )
        )
        await fulfillment(of: [deliveryEntered], timeout: 0.3)

        let detachTask = Task {
            await cell.detachAndWait(label: "source", requester: owner)
        }
        await fulfillment(of: [deliveryFinished], timeout: 1.2)
        await detachTask.value
        XCTAssertEqual(waitResults.snapshot(), ["cancelled"])
        XCTAssertEqual(emitter.cancellationCounter.snapshot(), 1)
        outputCancellable.cancel()
    }

    func testDropFlowCancellationCanReenterSameLabelLifecycle() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "cancellation-outside-auditor", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = await CancellationObservingEmitter(owner: owner)
        let cancellationResults = LockedEventTitles()
        emitter.cancellationHandler.set {
            let lifecycleCallFinished = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    try await cell.absorbFlow(label: "source", requester: owner)
                    cancellationResults.append("resubscribed")
                } catch {
                    cancellationResults.append("unexpected-error")
                }
                lifecycleCallFinished.signal()
            }
            let result = lifecycleCallFinished.wait(timeout: .now() + 1.0)
            cancellationResults.append(result == .success ? "completed" : "timed-out")
        }

        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell.absorbFlow(label: "source", requester: owner)
        await cell.dropFlowAndWait(label: "source", requester: owner)

        XCTAssertEqual(cancellationResults.snapshot(), ["resubscribed", "completed"])
        XCTAssertEqual(emitter.cancellationCounter.snapshot(), 1)
        let finalStatus = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(finalStatus.connected)
        XCTAssertTrue(finalStatus.active)
        emitter.cancellationHandler.clear()
        await cell.detachAndWait(label: "source", requester: owner)
    }

    func testConnectedLabelsAndStatusesUseCanonicalOrdering() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "canonical-status-order", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        for label in ["zeta", "alpha", "middle"] {
            let state = try await cell.attach(
                emitter: FlowElementPusherCell(owner: owner),
                label: label,
                requester: owner
            )
            XCTAssertEqual(state, .connected)
        }

        let labels = await cell.connectedLabels(requester: owner)
        XCTAssertEqual(labels, ["alpha", "middle", "zeta"])
        let statuses = try await cell.attachedStatuses(requester: owner)
        XCTAssertEqual(statuses.map(\.name), ["alpha", "middle", "zeta"])
    }

    func testDetachInvalidatesInFlightFlowSubscription() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "in-flight-flow-detach", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = await SuspendedFlowEmitter(owner: owner)

        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)

        let leakedEvent = expectation(description: "Detached in-flight subscription must not forward events")
        leakedEvent.isInverted = true
        let outputCancellable = try await cell.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                if element.title == "post-detach-in-flight" {
                    leakedEvent.fulfill()
                }
            }
        )

        let absorbTask = Task {
            try await cell.absorbFlow(label: "source", requester: owner)
        }
        await emitter.flowGate.waitUntilEntered()
        await cell.detachAndWait(label: "source", requester: owner)
        await emitter.flowGate.release()
        do {
            try await absorbTask.value
            XCTFail("Detached in-flight setup unexpectedly reported success")
        } catch is CancellationError {
            // Expected: detach invalidates the shared subscription flight.
        }

        let status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertFalse(status.connected)
        XCTAssertFalse(status.active)
        emitter.emit(
            FlowElement(
                title: "post-detach-in-flight",
                content: .string("must not leak"),
                properties: .init(type: .event, contentType: .string)
            )
        )
        await fulfillment(of: [leakedEvent], timeout: 0.15)
        outputCancellable.cancel()
    }

    func testConcurrentAbsorbFlowCreatesOnlyOneUpstreamSubscription() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "concurrent-flow-subscription", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = await SuspendedFlowEmitter(owner: owner)
        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)

        let firstAbsorb = Task {
            try await cell.absorbFlow(label: "source", requester: owner)
        }
        await emitter.flowGate.waitUntilEntered()
        let secondCompletion = CompletionFlag()
        let secondAbsorb = Task {
            try await cell.absorbFlow(label: "source", requester: owner)
            await secondCompletion.markCompleted()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let secondCompletedBeforeInstall = await secondCompletion.isCompleted()
        XCTAssertFalse(secondCompletedBeforeInstall)
        await emitter.flowGate.release()
        try await firstAbsorb.value
        try await secondAbsorb.value

        let upstreamSubscriptionCount = await emitter.flowGate.entryCount()
        XCTAssertEqual(upstreamSubscriptionCount, 1)
        let status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.active)
    }

    func testConcurrentAbsorbFlowSharesSetupFailure() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "concurrent-flow-failure", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = await FailingSuspendedFlowEmitter(owner: owner)
        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)

        let firstAbsorb = Task { () -> Bool in
            do {
                try await cell.absorbFlow(label: "source", requester: owner)
                return false
            } catch TestFlowSetupError.expected {
                return true
            } catch {
                return false
            }
        }
        await emitter.flowGate.waitUntilEntered()
        let secondAbsorb = Task { () -> Bool in
            do {
                try await cell.absorbFlow(label: "source", requester: owner)
                return false
            } catch TestFlowSetupError.expected {
                return true
            } catch {
                return false
            }
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        await emitter.flowGate.release()

        let firstReceivedExpectedError = await firstAbsorb.value
        let secondReceivedExpectedError = await secondAbsorb.value
        XCTAssertTrue(firstReceivedExpectedError)
        XCTAssertTrue(secondReceivedExpectedError)
        let upstreamSubscriptionCount = await emitter.flowGate.entryCount()
        XCTAssertEqual(upstreamSubscriptionCount, 1)
        let status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.connected)
        XCTAssertFalse(status.active)
    }

    func testDetachWinsSharedFlightBeforeEmitterSetupFailure() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "detach-before-shared-setup-failure", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = await FailingSuspendedFlowEmitter(owner: owner)
        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)

        let absorb: @Sendable () async -> FlowSetupOutcome = {
            do {
                try await cell.absorbFlow(label: "source", requester: owner)
                return .success
            } catch is CancellationError {
                return .cancelled
            } catch TestFlowSetupError.expected {
                return .expectedFailure
            } catch {
                return .otherFailure
            }
        }
        let leader = Task { await absorb() }
        await emitter.flowGate.waitUntilEntered()
        let waiter = Task { await absorb() }
        for _ in 0..<20 {
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        await cell.detachAndWait(label: "source", requester: owner)
        await emitter.flowGate.release()
        let leaderOutcome = await leader.value
        let waiterOutcome = await waiter.value
        XCTAssertEqual(leaderOutcome, .cancelled)
        XCTAssertEqual(waiterOutcome, .cancelled)
        let upstreamSetupCount = await emitter.flowGate.entryCount()
        XCTAssertEqual(upstreamSetupCount, 1)
    }

    func testMissingFlowLabelDoesNotTerminateUnrelatedCellFeed() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "missing-flow-label", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = FlowElementPusherCell(owner: owner)
        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell.absorbFlow(label: "source", requester: owner)

        let legitimateEvent = expectation(description: "Legitimate feed survives missing-label error")
        let unexpectedCompletion = expectation(description: "Shared Cell feed must not terminate")
        unexpectedCompletion.isInverted = true
        let outputCancellable = try await cell.flow(requester: owner).sink(
            receiveCompletion: { _ in
                unexpectedCompletion.fulfill()
            },
            receiveValue: { element in
                if element.title == "after-missing-label" {
                    legitimateEvent.fulfill()
                }
            }
        )

        do {
            try await cell.absorbFlow(label: "missing", requester: owner)
            XCTFail("Expected missing label to throw")
        } catch GeneralCellErrors.noPublisherForLabel {
            // Expected: the operation fails without terminating feedPublisher.
        }

        emitter.pushFlowElement(
            FlowElement(
                title: "after-missing-label",
                content: .string("expected"),
                properties: .init(type: .event, contentType: .string)
            ),
            requester: owner
        )
        await fulfillment(of: [legitimateEvent, unexpectedCompletion], timeout: 0.2)
        outputCancellable.cancel()
    }

    func testOutsiderCannotAttachOrStartVictimFlowSubscription() async throws {
        let priorDebugAccess = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
        defer { CellBase.debugValidateAccessForEverything = priorDebugAccess }
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "flow-victim-owner", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "flow-victim-outsider", makeNewIfNotFound: true)!
        let victim = await GeneralCell(owner: owner)
        let outsiderEmitter = FlowElementPusherCell(owner: outsider)

        do {
            _ = try await victim.attach(
                emitter: outsiderEmitter,
                label: "injected",
                requester: outsider
            )
            XCTFail("Outsider unexpectedly attached an emitter to the victim Cell")
        } catch CellAuthorizationError.denied(let decision) {
            XCTAssertEqual(decision.request.cellUUID, victim.uuid)
            XCTAssertEqual(decision.request.keypath, "injected")
            XCTAssertEqual(decision.request.requestedAccess, "-w--")
        }
        let statusesAfterDeniedAttach = try await victim.attachedStatuses(requester: owner)
        XCTAssertTrue(statusesAfterDeniedAttach.isEmpty)

        let ownerEmitter = FlowElementPusherCell(owner: owner)
        let state = try await victim.attach(
            emitter: ownerEmitter,
            label: "source",
            requester: owner
        )
        XCTAssertEqual(state, .connected)
        do {
            try await victim.absorbFlow(label: "source", requester: outsider)
            XCTFail("Outsider unexpectedly started the victim subscription")
        } catch CellAuthorizationError.denied(let decision) {
            XCTAssertEqual(decision.request.cellUUID, victim.uuid)
            XCTAssertEqual(decision.request.keypath, "source")
        }
        let status = try await victim.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.connected)
        XCTAssertFalse(status.active)
    }

    func testReleasingSubscribedCellCancelsUpstreamWithoutExplicitDetach() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "subscription-resource-deinit", makeNewIfNotFound: true)!
        let emitter = await CancellationObservingEmitter(owner: owner)
        var cell: GeneralCell? = await GeneralCell(owner: owner)
        weak var releasedCell = cell

        let state = try await cell?.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell?.absorbFlow(label: "source", requester: owner)
        cell = nil

        for _ in 0..<100 {
            if emitter.cancellationCounter.snapshot() > 0,
               releasedCell == nil {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(releasedCell)
        XCTAssertEqual(emitter.cancellationCounter.snapshot(), 1)
    }

    func testReleasingCellCancelsUpstreamWhileDownstreamSubscriberIsBlocked() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "blocked-downstream-resource-deinit", makeNewIfNotFound: true)!
        let emitter = await CancellationObservingEmitter(owner: owner)
        var cell: GeneralCell? = await GeneralCell(owner: owner)
        weak var releasedCell = cell

        let downstreamEntered = expectation(description: "Downstream subscriber entered")
        let releaseDownstream = DispatchSemaphore(value: 0)
        let outputCancellable = try await cell!.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                guard element.title == "block-downstream-release" else { return }
                downstreamEntered.fulfill()
                _ = releaseDownstream.wait(timeout: .now() + 1.0)
            }
        )
        defer {
            releaseDownstream.signal()
            outputCancellable.cancel()
        }

        let state = try await cell?.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell?.absorbFlow(label: "source", requester: owner)
        emitter.emit(
            FlowElement(
                title: "block-downstream-release",
                content: .string("block"),
                properties: .init(type: .event, contentType: .string)
            )
        )
        await fulfillment(of: [downstreamEntered], timeout: 1.0)
        cell = nil

        for _ in 0..<100 {
            if emitter.cancellationCounter.snapshot() > 0,
               releasedCell == nil {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(releasedCell)
        XCTAssertEqual(emitter.cancellationCounter.snapshot(), 1)
    }

    func testReleasingCellDuringSuspendedInterceptCancelsUpstream() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "suspended-intercept-resource-deinit", makeNewIfNotFound: true)!
        let emitter = await CancellationObservingEmitter(owner: owner)
        let interceptGate = SuspendedFlowGate()
        var cell: GeneralCell? = await GeneralCell(owner: owner)
        weak var releasedCell = cell

        await cell?.addIntercept(requester: owner) { element, _ in
            if element.title == "block-release" {
                await interceptGate.suspendUntilReleased()
            }
            return element
        }
        let state = try await cell?.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell?.absorbFlow(label: "source", requester: owner)
        emitter.emit(
            FlowElement(
                title: "block-release",
                content: .string("block"),
                properties: .init(type: .event, contentType: .string)
            )
        )
        await interceptGate.waitUntilEntered()
        cell = nil

        for _ in 0..<100 {
            if emitter.cancellationCounter.snapshot() > 0,
               releasedCell == nil {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(releasedCell)
        XCTAssertEqual(emitter.cancellationCounter.snapshot(), 1)
        await interceptGate.release()
    }

    func testEmitterReplacementInvalidatesInFlightOldSubscription() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "in-flight-flow-replacement", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let oldEmitter = await SuspendedFlowEmitter(owner: owner)
        let newEmitter = FlowElementPusherCell(owner: owner)

        var state = try await cell.attach(emitter: oldEmitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)

        let oldEvent = expectation(description: "Replaced in-flight emitter must not forward events")
        oldEvent.isInverted = true
        let newEvent = expectation(description: "Replacement emitter forwards after explicit subscription")
        let outputCancellable = try await cell.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                if element.title == "old-emitter-event" {
                    oldEvent.fulfill()
                }
                if element.title == "new-emitter-event" {
                    newEvent.fulfill()
                }
            }
        )

        let oldAbsorbTask = Task {
            try await cell.absorbFlow(label: "source", requester: owner)
        }
        await oldEmitter.flowGate.waitUntilEntered()
        state = try await cell.attach(emitter: newEmitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        await oldEmitter.flowGate.release()
        do {
            try await oldAbsorbTask.value
            XCTFail("Replaced in-flight setup unexpectedly reported success")
        } catch is CancellationError {
            // Expected: replacement invalidates the old subscription flight.
        }

        oldEmitter.emit(
            FlowElement(
                title: "old-emitter-event",
                content: .string("must not leak"),
                properties: .init(type: .event, contentType: .string)
            )
        )
        var status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.connected)
        XCTAssertFalse(status.active)
        let connectedEmitter = await cell.getEmitterWithLabel("source", requester: owner)
        XCTAssertEqual(
            connectedEmitter?.uuid,
            newEmitter.uuid
        )

        try await cell.absorbFlow(label: "source", requester: owner)
        status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.active)
        newEmitter.pushFlowElement(
            FlowElement(
                title: "new-emitter-event",
                content: .string("expected"),
                properties: .init(type: .event, contentType: .string)
            ),
            requester: owner
        )
        await fulfillment(of: [newEvent, oldEvent], timeout: 0.3)
        outputCancellable.cancel()
    }

    func testDistinctEmitterObjectWithSameUUIDInvalidatesOldSubscription() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "same-uuid-emitter-replacement", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let oldEmitter = await RotatingFlowEmitter(owner: owner)
        let newEmitter = await RotatingFlowEmitter(owner: owner)
        newEmitter.uuid = oldEmitter.uuid

        var state = try await cell.attach(emitter: oldEmitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell.absorbFlow(label: "source", requester: owner)

        let oldEvent = expectation(description: "Old same-UUID object must not forward")
        oldEvent.isInverted = true
        let newEvent = expectation(description: "New same-UUID object forwards")
        let outputCancellable = try await cell.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                if element.title == "old-same-uuid" {
                    oldEvent.fulfill()
                }
                if element.title == "new-same-uuid" {
                    newEvent.fulfill()
                }
            }
        )

        state = try await cell.attach(emitter: newEmitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        var status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.connected)
        XCTAssertFalse(status.active)
        await oldEmitter.emit(
            FlowElement(
                title: "old-same-uuid",
                content: .string("must not leak"),
                properties: .init(type: .event, contentType: .string)
            )
        )

        try await cell.absorbFlow(label: "source", requester: owner)
        status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.active)
        await newEmitter.emit(
            FlowElement(
                title: "new-same-uuid",
                content: .string("expected"),
                properties: .init(type: .event, contentType: .string)
            )
        )
        await fulfillment(of: [newEvent, oldEvent], timeout: 0.3)
        outputCancellable.cancel()
    }

    func testCompletedUpstreamBecomesInactiveAndCanResubscribe() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "completed-flow-resubscribe", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = await RotatingFlowEmitter(owner: owner)

        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell.absorbFlow(label: "source", requester: owner)
        var status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.active)

        await emitter.complete()
        for _ in 0..<100 {
            status = try await cell.attachedStatus(for: "source", requester: owner)
            if status.active == false { break }
            await Task.yield()
        }
        XCTAssertTrue(status.connected)
        XCTAssertFalse(status.active)

        let resubscribedEvent = expectation(description: "Resubscribed publisher forwards")
        let outputCancellable = try await cell.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                if element.title == "after-resubscribe" {
                    resubscribedEvent.fulfill()
                }
            }
        )
        try await cell.absorbFlow(label: "source", requester: owner)
        status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.active)
        await emitter.emit(
            FlowElement(
                title: "after-resubscribe",
                content: .string("expected"),
                properties: .init(type: .event, contentType: .string)
            )
        )
        await fulfillment(of: [resubscribedEvent], timeout: 0.3)
        outputCancellable.cancel()
    }

    func testSynchronousValueIsForwardedBeforeUpstreamCompletionCleanup() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "single-value-flow", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let expected = FlowElement(
            title: "single-value",
            content: .string("expected"),
            properties: .init(type: .event, contentType: .string)
        )
        let emitter = await SingleValueFlowEmitter(owner: owner, element: expected)
        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)

        let receivedValue = expectation(description: "Synchronous value arrives before completion cleanup")
        let outputCancellable = try await cell.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                if element.title == expected.title {
                    receivedValue.fulfill()
                }
            }
        )
        try await cell.absorbFlow(label: "source", requester: owner)
        await fulfillment(of: [receivedValue], timeout: 0.3)

        var status = try await cell.attachedStatus(for: "source", requester: owner)
        for _ in 0..<100 where status.active {
            await Task.yield()
            status = try await cell.attachedStatus(for: "source", requester: owner)
        }
        XCTAssertTrue(status.connected)
        XCTAssertFalse(status.active)
        outputCancellable.cancel()
    }

    func testAsyncFeedInterceptPreservesUpstreamEventOrder() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "ordered-flow-intercept", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = await RotatingFlowEmitter(owner: owner)
        let firstInterceptGate = SuspendedFlowGate()
        await cell.addIntercept(requester: owner) { element, _ in
            if element.title == "one" {
                await firstInterceptGate.suspendUntilReleased()
            }
            return element
        }
        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell.absorbFlow(label: "source", requester: owner)

        let receivedBoth = expectation(description: "Both ordered events arrive")
        let titles = LockedEventTitles()
        let outputCancellable = try await cell.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                if element.title == "one" || element.title == "two" {
                    if titles.append(element.title) == 2 {
                        receivedBoth.fulfill()
                    }
                }
            }
        )

        await emitter.emit(
            FlowElement(
                title: "one",
                content: .string("1"),
                properties: .init(type: .event, contentType: .string)
            )
        )
        await firstInterceptGate.waitUntilEntered()
        await emitter.emit(
            FlowElement(
                title: "two",
                content: .string("2"),
                properties: .init(type: .event, contentType: .string)
            )
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        await firstInterceptGate.release()
        await fulfillment(of: [receivedBoth], timeout: 0.3)
        XCTAssertEqual(titles.snapshot(), ["one", "two"])
        outputCancellable.cancel()
    }

    func testSlowInterceptFailsClosedWhenFlowBufferOverflows() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "flow-buffer-overflow", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = await RotatingFlowEmitter(owner: owner)
        let interceptGate = SuspendedFlowGate()
        await cell.addIntercept(requester: owner) { element, _ in
            if element.title == "block" {
                await interceptGate.suspendUntilReleased()
            }
            return element
        }
        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell.absorbFlow(label: "source", requester: owner)

        let postOverflowEvent = expectation(description: "Overflowed subscription must not forward queued events")
        postOverflowEvent.isInverted = true
        let outputCancellable = try await cell.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                if element.title == "block" || element.title.hasPrefix("burst-") {
                    postOverflowEvent.fulfill()
                }
            }
        )

        await emitter.emit(
            FlowElement(
                title: "block",
                content: .string("block"),
                properties: .init(type: .event, contentType: .string)
            )
        )
        await interceptGate.waitUntilEntered()
        await emitter.emitBurst(count: 300)

        var status = try await cell.attachedStatus(for: "source", requester: owner)
        for _ in 0..<100 where status.active {
            await Task.yield()
            status = try await cell.attachedStatus(for: "source", requester: owner)
        }
        XCTAssertTrue(status.connected)
        XCTAssertFalse(status.active)
        await interceptGate.release()
        await fulfillment(of: [postOverflowEvent], timeout: 0.15)
        outputCancellable.cancel()
    }

    func testCompletionDroppedAtExactBufferCapacityInvalidatesAndAllowsResubscribe() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "flow-completion-overflow", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = await RotatingFlowEmitter(owner: owner)
        let interceptGate = SuspendedFlowGate()
        await cell.addIntercept(requester: owner) { element, _ in
            if element.title == "block" {
                await interceptGate.suspendUntilReleased()
            }
            return element
        }
        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell.absorbFlow(label: "source", requester: owner)

        let postOverflowEvent = expectation(description: "Dropped completion must fail closed without forwarding")
        postOverflowEvent.isInverted = true
        let outputCancellable = try await cell.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                if element.title == "block" || element.title.hasPrefix("burst-") {
                    postOverflowEvent.fulfill()
                }
            }
        )
        await emitter.emit(
            FlowElement(
                title: "block",
                content: .string("block"),
                properties: .init(type: .event, contentType: .string)
            )
        )
        await interceptGate.waitUntilEntered()
        await emitter.emitBurst(count: GeneralCell.flowEventBufferLimit)
        await emitter.complete()

        var status = try await cell.attachedStatus(for: "source", requester: owner)
        for _ in 0..<100 where status.active {
            await Task.yield()
            status = try await cell.attachedStatus(for: "source", requester: owner)
        }
        XCTAssertTrue(status.connected)
        XCTAssertFalse(status.active)
        await interceptGate.release()
        await fulfillment(of: [postOverflowEvent], timeout: 0.15)

        try await cell.absorbFlow(label: "source", requester: owner)
        status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.connected)
        XCTAssertTrue(status.active)
        outputCancellable.cancel()
    }

    func testConcurrentAbsorbSharesSynchronousSetupOverflowFailure() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "setup-overflow-flight", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = await SuspendedSynchronousBurstEmitter(owner: owner)
        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)

        let firstAbsorb = Task { () -> Bool in
            do {
                try await cell.absorbFlow(label: "source", requester: owner)
                return false
            } catch GeneralCellErrors.flowBufferOverflow {
                return true
            } catch {
                return false
            }
        }
        await emitter.flowGate.waitUntilEntered()
        let secondAbsorb = Task { () -> Bool in
            do {
                try await cell.absorbFlow(label: "source", requester: owner)
                return false
            } catch GeneralCellErrors.flowBufferOverflow {
                return true
            } catch {
                return false
            }
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        await emitter.flowGate.release()

        let firstReceivedOverflow = await firstAbsorb.value
        let secondReceivedOverflow = await secondAbsorb.value
        XCTAssertTrue(firstReceivedOverflow)
        XCTAssertTrue(secondReceivedOverflow)
        let upstreamSubscriptionCount = await emitter.flowGate.entryCount()
        XCTAssertEqual(upstreamSubscriptionCount, 1)
        let status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.connected)
        XCTAssertFalse(status.active)
    }

    func testFlowOverflowStateRejectsReservationsAfterOverflow() {
        let state = FlowBufferOverflowState()
        let reservation = state.reserveForwardIfNotOverflowed()
        XCTAssertNotNil(reservation)
        reservation?.finish()
        XCTAssertTrue(state.markOverflow())
        XCTAssertNil(state.reserveForwardIfNotOverflowed())
    }

    func testOverflowedActiveSubscriptionSelfHealsBeforeResubscribe() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "overflowed-active-self-heal", makeNewIfNotFound: true)!
        let emitter = await RotatingFlowEmitter(owner: owner)
        let auditor = GeneralAuditor()
        await auditor.connectEmitter(emitter, for: "source")

        guard case .ready(let firstID, _, _) = await auditor.beginFlowSubscription(for: "source") else {
            return XCTFail("Expected initial subscription flight")
        }
        let source = PassthroughSubject<FlowElement, Error>()
        let subscribedFeed = source.eraseToAnyPublisher()
        let cancellable = subscribedFeed.sink(receiveCompletion: { _ in }, receiveValue: { _ in })
        let (eventStream, eventContinuation) = AsyncStream.makeStream(
            of: FlowSubscriptionEvent.self,
            bufferingPolicy: .bufferingOldest(GeneralCell.flowEventBufferLimit)
        )
        let processor = Task {
            for await _ in eventStream {}
        }
        let overflowState = FlowBufferOverflowState()
        let installed = await auditor.installFlowSubscription(
            for: "source",
            id: firstID,
            emitterUUID: emitter.uuid,
            subscribedFeed: subscribedFeed,
            feedCancellable: cancellable,
            eventProcessor: processor,
            eventContinuation: eventContinuation,
            overflowState: overflowState
        )
        XCTAssertTrue(installed)
        XCTAssertTrue(overflowState.markOverflow())

        guard case .ready(let replacementID, _, _) = await auditor.beginFlowSubscription(for: "source") else {
            return XCTFail("Overflowed active subscription was reported as active")
        }
        XCTAssertNotEqual(replacementID, firstID)
        await auditor.cancelFlowSubscription(for: "source", pendingID: replacementID)
    }

    func testOverflowSelfHealReloadsSameUUIDEmitterReplacedDuringCancellation() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "overflow-self-heal-emitter-reload", makeNewIfNotFound: true)!
        let oldEmitter = await RotatingFlowEmitter(owner: owner)
        let newEmitter = await RotatingFlowEmitter(owner: owner)
        newEmitter.uuid = oldEmitter.uuid
        let auditor = GeneralAuditor()
        await auditor.connectEmitter(oldEmitter, for: "source")

        guard case .ready(let firstID, _, _) = await auditor.beginFlowSubscription(for: "source") else {
            return XCTFail("Expected initial subscription flight")
        }
        let cancellationEntered = expectation(description: "Overflow cleanup started cancelling old feed")
        let releaseCancellation = DispatchSemaphore(value: 0)
        let source = PassthroughSubject<FlowElement, Error>()
        let subscribedFeed = source
            .handleEvents(receiveCancel: {
                cancellationEntered.fulfill()
                _ = releaseCancellation.wait(timeout: .now() + 1.0)
            })
            .eraseToAnyPublisher()
        let cancellable = subscribedFeed.sink(receiveCompletion: { _ in }, receiveValue: { _ in })
        let (eventStream, eventContinuation) = AsyncStream.makeStream(
            of: FlowSubscriptionEvent.self,
            bufferingPolicy: .bufferingOldest(GeneralCell.flowEventBufferLimit)
        )
        let processor = Task {
            for await _ in eventStream {}
        }
        let overflowState = FlowBufferOverflowState()
        let installed = await auditor.installFlowSubscription(
            for: "source",
            id: firstID,
            emitterUUID: oldEmitter.uuid,
            subscribedFeed: subscribedFeed,
            feedCancellable: cancellable,
            eventProcessor: processor,
            eventContinuation: eventContinuation,
            overflowState: overflowState
        )
        XCTAssertTrue(installed)
        XCTAssertTrue(overflowState.markOverflow())

        let selfHeal = Task {
            await auditor.beginFlowSubscription(for: "source")
        }
        await fulfillment(of: [cancellationEntered], timeout: 1.0)
        await auditor.connectEmitter(newEmitter, for: "source")
        releaseCancellation.signal()

        guard case .ready(let replacementID, let selectedEmitter, _) = await selfHeal.value else {
            return XCTFail("Expected replacement subscription flight")
        }
        XCTAssertEqual(ObjectIdentifier(selectedEmitter), ObjectIdentifier(newEmitter))
        XCTAssertNotEqual(ObjectIdentifier(selectedEmitter), ObjectIdentifier(oldEmitter))
        await auditor.cancelFlowSubscription(for: "source", pendingID: replacementID)
    }

    func testCrossThreadOverflowFeedbackDoesNotDeadlockForwarding() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "cross-thread-overflow-feedback", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let emitter = await RotatingFlowEmitter(owner: owner)
        let state = try await cell.attach(emitter: emitter, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell.absorbFlow(label: "source", requester: owner)

        let feedbackCompleted = expectation(description: "Cross-thread overflow completes while subscriber is running")
        let waitResults = LockedEventTitles()
        let outputCancellable = try await cell.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                guard element.title == "feedback-trigger" else { return }
                let feedbackFinished = DispatchSemaphore(value: 0)
                Task {
                    await emitter.emitBurst(count: GeneralCell.flowEventBufferLimit + 44)
                    feedbackFinished.signal()
                }
                let result = feedbackFinished.wait(timeout: .now() + 1.0)
                waitResults.append(result == .success ? "completed" : "timed-out")
                feedbackCompleted.fulfill()
            }
        )
        await emitter.emit(
            FlowElement(
                title: "feedback-trigger",
                content: .string("trigger"),
                properties: .init(type: .event, contentType: .string)
            )
        )
        await fulfillment(of: [feedbackCompleted], timeout: 1.5)
        XCTAssertEqual(waitResults.snapshot(), ["completed"])

        var status = try await cell.attachedStatus(for: "source", requester: owner)
        for _ in 0..<100 where status.active {
            await Task.yield()
            status = try await cell.attachedStatus(for: "source", requester: owner)
        }
        XCTAssertFalse(status.active)
        outputCancellable.cancel()
    }

    func testAttachedStatusesTerminatesForSelfAndTwoCellCycles() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "cyclic-status-graph", makeNewIfNotFound: true)!

        let selfAttached = await GeneralCell(owner: owner)
        var state = try await selfAttached.attach(
            emitter: selfAttached,
            label: "self",
            requester: owner
        )
        XCTAssertEqual(state, .connected)
        let selfStatuses = try await selfAttached.attachedStatuses(requester: owner)
        XCTAssertEqual(selfStatuses.map(\.name), ["self"])

        let cellA = await GeneralCell(owner: owner)
        let cellB = await GeneralCell(owner: owner)
        state = try await cellA.attach(emitter: cellB, label: "b", requester: owner)
        XCTAssertEqual(state, .connected)
        state = try await cellB.attach(emitter: cellA, label: "a", requester: owner)
        XCTAssertEqual(state, .connected)
        let twoCellStatuses = try await cellA.attachedStatuses(requester: owner)
        XCTAssertEqual(twoCellStatuses.map(\.name), ["b", "b.a"])
    }

    func testAttachedStatusCycleGuardPreservesSiblingAliases() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "status-sibling-aliases", makeNewIfNotFound: true)!
        let root = await GeneralCell(owner: owner)
        let sharedChild = await GeneralCell(owner: owner)
        let leaf = FlowElementPusherCell(owner: owner)

        var state = try await sharedChild.attach(emitter: leaf, label: "leaf", requester: owner)
        XCTAssertEqual(state, .connected)
        state = try await root.attach(emitter: sharedChild, label: "right", requester: owner)
        XCTAssertEqual(state, .connected)
        state = try await root.attach(emitter: sharedChild, label: "left", requester: owner)
        XCTAssertEqual(state, .connected)

        let statuses = try await root.attachedStatuses(requester: owner)
        XCTAssertEqual(
            statuses.map(\.name),
            ["left", "left.leaf", "right", "right.leaf"]
        )
    }

    func testWaitableFlowDisconnectRejectsOutsiderWithoutMutatingOwnerConnection() async throws {
        let priorDebugAccess = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
        defer { CellBase.debugValidateAccessForEverything = priorDebugAccess }
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "waitable-disconnect-owner", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "waitable-disconnect-outsider", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let pusher = FlowElementPusherCell(owner: owner)

        let state = try await cell.attach(emitter: pusher, label: "source", requester: owner)
        XCTAssertEqual(state, .connected)
        try await cell.absorbFlow(label: "source", requester: owner)

        await cell.dropFlowAndWait(label: "source", requester: outsider)
        var status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.connected)
        XCTAssertTrue(status.active)

        await cell.detachAndWait(label: "source", requester: outsider)
        status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertTrue(status.connected)
        XCTAssertTrue(status.active)

        await cell.detachAndWait(label: "source", requester: owner)
        status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertFalse(status.connected)
        XCTAssertFalse(status.active)
    }

    func testWaitableDetachUsesOneAuthorizationDecisionAndLeavesNoHiddenSubscription() async throws {
        let priorDebugAccess = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
        defer { CellBase.debugValidateAccessForEverything = priorDebugAccess }
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = nil
        let owner = await vault.identity(for: "one-shot-disconnect-owner", makeNewIfNotFound: true)!
        let requester = await vault.identity(for: "one-shot-disconnect-requester", makeNewIfNotFound: true)!
        let cell = await OneShotDisconnectAccessCell(owner: owner)
        let pusher = FlowElementPusherCell(owner: owner)

        let connectState = try await cell.attach(
            emitter: pusher,
            label: "source",
            requester: owner
        )
        XCTAssertEqual(connectState, .connected)
        try await cell.absorbFlow(label: "source", requester: owner)

        let leakedEvent = expectation(description: "Detached subscription must not forward events")
        leakedEvent.isInverted = true
        let cancellable = try await cell.flow(requester: owner).sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                if element.title == "post-detach" {
                    leakedEvent.fulfill()
                }
            }
        )

        await cell.detachAndWait(label: "source", requester: requester)
        let status = try await cell.attachedStatus(for: "source", requester: owner)
        XCTAssertFalse(status.connected)
        XCTAssertFalse(status.active)
        let accessAttempts = await cell.accessGate.attemptCount()
        XCTAssertEqual(accessAttempts, 1)

        pusher.pushFlowElement(
            FlowElement(
                title: "post-detach",
                content: .string("must not leak"),
                properties: .init(type: .event, contentType: .string)
            ),
            requester: owner
        )
        await fulfillment(of: [leakedEvent], timeout: 0.15)
        cancellable.cancel()
    }
}
