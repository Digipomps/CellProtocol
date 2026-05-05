// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

#if canImport(CellVapor)
import CellVapor
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

private actor LifecycleEventRecorder {
    private var events: [CellLifecycleEvent] = []
    private var memoryExpiryExtensionSeconds: TimeInterval?
    private var usedMemoryExpiryExtension = false

    func setMemoryExpiryExtension(_ seconds: TimeInterval?) {
        memoryExpiryExtensionSeconds = seconds
        usedMemoryExpiryExtension = false
    }

    func handle(event: CellLifecycleEvent) -> CellLifecycleEventResponse {
        events.append(event)

        if event.type == .memoryTTLExpired,
           let seconds = memoryExpiryExtensionSeconds,
           !usedMemoryExpiryExtension {
            usedMemoryExpiryExtension = true
            return .extendMemoryTTL(seconds)
        }
        return .useDefaultAction
    }

    func hasEvent(type: CellLifecycleEventType, uuid: String) -> Bool {
        events.contains(where: { $0.type == type && $0.uuid == uuid })
    }

    func eventCount(type: CellLifecycleEventType, uuid: String) -> Int {
        events.filter { $0.type == type && $0.uuid == uuid }.count
    }
}

private actor LifecycleFlowRecorder {
    private var lifecycleEvents: [(typeRawValue: String, uuid: String)] = []

    func append(_ flowElement: FlowElement) {
        guard flowElement.topic == "lifecycle",
              case .object(let payload) = flowElement.content,
              case .string(let typeRawValue)? = payload["type"],
              case .string(let uuid)? = payload["uuid"] else {
            return
        }

        lifecycleEvents.append((typeRawValue: typeRawValue, uuid: uuid))
    }

    func hasEvent(type: CellLifecycleEventType, uuid: String) -> Bool {
        lifecycleEvents.contains { $0.typeRawValue == type.rawValue && $0.uuid == uuid }
    }
}

private final class LifecycleResponder: CellLifecycleEventResponder {
    let recorder = LifecycleEventRecorder()

    func resolver(_ resolver: CellResolver, didReceive event: CellLifecycleEvent) async -> CellLifecycleEventResponse {
        await recorder.handle(event: event)
    }
}

final class CellLifecycleTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousDocumentRoot: String?
    private var previousTypedUtility: TypedCellProtocol?
    private var previousResolverTypedUtility: TypedCellUtility?
    private var previousHome: String?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousDocumentRoot = CellBase.documentRootPath
        previousTypedUtility = CellBase.typedCellUtility
        previousResolverTypedUtility = CellResolver.sharedInstance.tcUtility
        previousHome = ProcessInfo.processInfo.environment["HOME"]

        CellBase.defaultIdentityVault = MockIdentityVault()
        CellBase.defaultCellResolver = CellResolver.sharedInstance
        CellResolver.sharedInstance.lifecycleSweepInterval = 0.05
        CellResolver.sharedInstance.setCellLifecycleEventResponder(nil)
    }

    override func tearDown() {
        CellResolver.sharedInstance.setCellLifecycleEventResponder(nil)
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.documentRootPath = previousDocumentRoot
        CellBase.typedCellUtility = previousTypedUtility
        CellResolver.sharedInstance.tcUtility = previousResolverTypedUtility
        if let previousHome {
            setenv("HOME", previousHome, 1)
        } else {
            unsetenv("HOME")
        }
        super.tearDown()
    }

    func testMemoryTTLWarningAndExpiryEventsAreEmitted() async throws {
        let resolver = CellResolver.sharedInstance
        let responder = LifecycleResponder()
        resolver.setCellLifecycleEventResponder(responder)

        let policy = CellLifecyclePolicy(
            memoryTTL: 0.25,
            warningLeadTime: 0.15,
            persistedDataTTL: nil,
            memoryExpiryAction: .notifyOnly
        )

        let name = "TTL-Warn-\(UUID().uuidString)"
        try await resolver.addCellResolve(
            name: name,
            cellScope: .scaffoldUnique,
            identityDomain: "private",
            lifecyclePolicy: policy,
            type: GeneralCell.self
        )

        let identity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        let cell = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)

        let gotWarning = await waitUntil(timeout: 2.0) {
            await responder.recorder.hasEvent(type: .memoryTTLWarning, uuid: cell.uuid)
        }
        let gotExpiry = await waitUntil(timeout: 2.0) {
            await responder.recorder.hasEvent(type: .memoryTTLExpired, uuid: cell.uuid)
        }

        XCTAssertTrue(gotWarning)
        XCTAssertTrue(gotExpiry)
    }

    func testMemoryTTLCanBeExtendedFromLifecycleResponse() async throws {
        let resolver = CellResolver.sharedInstance
        let responder = LifecycleResponder()
        await responder.recorder.setMemoryExpiryExtension(0.40)
        resolver.setCellLifecycleEventResponder(responder)

        let policy = CellLifecyclePolicy(
            memoryTTL: 0.20,
            warningLeadTime: 0,
            persistedDataTTL: nil,
            memoryExpiryAction: .unloadFromMemory
        )

        let name = "TTL-Extend-\(UUID().uuidString)"
        try await resolver.addCellResolve(
            name: name,
            cellScope: .scaffoldUnique,
            identityDomain: "private",
            lifecyclePolicy: policy,
            type: GeneralCell.self
        )

        let identity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        let first = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)

        let sawFirstExpiry = await waitUntil(timeout: 2.0) {
            await responder.recorder.hasEvent(type: .memoryTTLExpired, uuid: first.uuid)
        }
        XCTAssertTrue(sawFirstExpiry)

        let second = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)
        XCTAssertEqual(first.uuid, second.uuid)

        let sawSecondExpiry = await waitUntil(timeout: 2.0) {
            await responder.recorder.eventCount(type: .memoryTTLExpired, uuid: first.uuid) >= 2
        }
        XCTAssertTrue(sawSecondExpiry)

        let third = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)
        XCTAssertNotEqual(first.uuid, third.uuid)
    }

    func testPersistAndUnloadReloadsSameUUIDFromStorage() async throws {
        let resolver = CellResolver.sharedInstance
        let responder = LifecycleResponder()
        resolver.setCellLifecycleEventResponder(responder)

        try await withTempPersistenceContext { _ in
            let policy = CellLifecyclePolicy(
                memoryTTL: 0.20,
                warningLeadTime: 0,
                persistedDataTTL: 5.0,
                memoryExpiryAction: .persistAndUnload
            )

            let name = "TTL-Persist-\(UUID().uuidString)"
            try await resolver.addCellResolve(
                name: name,
                cellScope: .scaffoldUnique,
                persistency: .persistant,
                identityDomain: "private",
                lifecyclePolicy: policy,
                type: GeneralCell.self
            )

            let identity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
            let first = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)

            let sawExpiry = await waitUntil(timeout: 2.0) {
                await responder.recorder.hasEvent(type: .memoryTTLExpired, uuid: first.uuid)
            }
            XCTAssertTrue(sawExpiry)

            let second = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)
            XCTAssertEqual(first.uuid, second.uuid)
            XCTAssertFalse(second as AnyObject === first as AnyObject)
        }
    }

    func testPersistedDataTTLDeletesUnusedPersistedData() async throws {
        let resolver = CellResolver.sharedInstance
        let responder = LifecycleResponder()
        resolver.setCellLifecycleEventResponder(responder)

        try await withTempPersistenceContext { rootPath in
            let policy = CellLifecyclePolicy(
                memoryTTL: 0.10,
                warningLeadTime: 0,
                persistedDataTTL: 0.25,
                memoryExpiryAction: .persistAndUnload
            )

            let name = "TTL-Persist-Delete-\(UUID().uuidString)"
            try await resolver.addCellResolve(
                name: name,
                cellScope: .scaffoldUnique,
                persistency: .persistant,
                identityDomain: "private",
                lifecyclePolicy: policy,
                type: GeneralCell.self
            )

            let identity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
            let cell = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)

            let persistedDirectory = URL(fileURLWithPath: rootPath)
                .appendingPathComponent("CellsContainer")
                .appendingPathComponent(cell.uuid)
            let deleted = await waitUntil(timeout: 3.0) {
                !FileManager.default.fileExists(atPath: persistedDirectory.path)
            }
            XCTAssertTrue(deleted)
            XCTAssertFalse(FileManager.default.fileExists(atPath: persistedDirectory.path))
        }
    }

    func testLifecycleAlarmRoutesOnlyToOwnerAndAllowedIdentities() async throws {
        let resolver = CellResolver.sharedInstance
        resolver.setCellLifecycleEventResponder(nil)

        guard let vault = CellBase.defaultIdentityVault else {
            XCTFail("Missing identity vault")
            return
        }

        let ownerDomain = "ttl-owner-\(UUID().uuidString)"
        let allowedDomain = "ttl-allowed-\(UUID().uuidString)"
        let blockedDomain = "ttl-blocked-\(UUID().uuidString)"

        guard let owner = await vault.identity(for: ownerDomain, makeNewIfNotFound: true),
              let allowed = await vault.identity(for: allowedDomain, makeNewIfNotFound: true),
              let blocked = await vault.identity(for: blockedDomain, makeNewIfNotFound: true) else {
            XCTFail("Failed to create identities")
            return
        }

        let ownerEmitter = FlowElementPusherCell(owner: owner)
        let allowedEmitter = FlowElementPusherCell(owner: allowed)
        let blockedEmitter = FlowElementPusherCell(owner: blocked)

        try await resolver.setResolverEmitter(ownerEmitter, requester: owner)
        try await resolver.setResolverEmitter(allowedEmitter, requester: allowed)
        try await resolver.setResolverEmitter(blockedEmitter, requester: blocked)

        let ownerRecorder = LifecycleFlowRecorder()
        let allowedRecorder = LifecycleFlowRecorder()
        let blockedRecorder = LifecycleFlowRecorder()
        var cancellables = Set<AnyCancellable>()

        ownerEmitter.getFeedPublisher().sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
            Task { await ownerRecorder.append(flowElement) }
        }).store(in: &cancellables)
        allowedEmitter.getFeedPublisher().sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
            Task { await allowedRecorder.append(flowElement) }
        }).store(in: &cancellables)
        blockedEmitter.getFeedPublisher().sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
            Task { await blockedRecorder.append(flowElement) }
        }).store(in: &cancellables)

        let policy = CellLifecyclePolicy(
            memoryTTL: 0.25,
            warningLeadTime: 0.20,
            persistedDataTTL: nil,
            memoryExpiryAction: .notifyOnly
        )

        let name = "TTL-Access-\(UUID().uuidString)"
        try await resolver.addCellResolve(
            name: name,
            cellScope: .scaffoldUnique,
            identityDomain: ownerDomain,
            lifecyclePolicy: policy,
            type: GeneralCell.self
        )

        let cell = await GeneralCell(owner: owner)
        try cell.agreementTemplate.addCondition(
            LifecycleAlertAccessCondition(
                allowedIdentityUUIDs: [allowed.uuid],
                includeSignatories: false
            )
        )
        try await resolver.registerNamedEmitCell(
            name: name,
            emitCell: cell,
            scope: .scaffoldUnique,
            identity: owner
        )

        let ownerReceived = await waitUntil(timeout: 2.0) {
            await ownerRecorder.hasEvent(type: .memoryTTLWarning, uuid: cell.uuid)
        }
        let allowedReceived = await waitUntil(timeout: 2.0) {
            await allowedRecorder.hasEvent(type: .memoryTTLWarning, uuid: cell.uuid)
        }
        let blockedReceived = await waitUntil(timeout: 0.8) {
            await blockedRecorder.hasEvent(type: .memoryTTLWarning, uuid: cell.uuid)
        }

        XCTAssertTrue(ownerReceived)
        XCTAssertTrue(allowedReceived)
        XCTAssertFalse(blockedReceived)
    }

    private func withTempPersistenceContext<T>(
        _ body: (String) async throws -> T
    ) async throws -> T {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellprotocol-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("HOME", tempRoot.path, 1)
        CellBase.documentRootPath = tempRoot.appendingPathComponent("CellsContainer").path
        let typedUtility = TypedCellUtility(storage: FileSystemCellStorage())
        CellBase.typedCellUtility = typedUtility
        CellResolver.sharedInstance.tcUtility = typedUtility
        return try await body(tempRoot.path)
    }

    private func waitUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.05,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await CellResolver.sharedInstance.performLifecycleSweepNow()
            if await condition() {
                return true
            }
            let sleepNanos = UInt64(interval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepNanos)
        }
        return false
    }
}
#endif
