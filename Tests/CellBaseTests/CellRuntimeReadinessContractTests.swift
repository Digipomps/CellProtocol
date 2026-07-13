// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@_spi(HAVENRuntime) @testable import CellBase
@testable import CellApple

final class CellRuntimeReadinessContractTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousDocumentRoot: String?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousDocumentRoot = CellBase.documentRootPath
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.documentRootPath = previousDocumentRoot
        super.tearDown()
    }

    func testCellBaseDecodedCellsAreImmediatelyAndConcurrentlyReady() async throws {
        let owner = try await configuredOwnerAndDocumentRoot(suffix: "cellbase")

        try await assertDecodedReadiness(
            await GraphIndexCell(owner: owner),
            owner: owner,
            expectedKey: "graph.state",
            requiredGrant: Grant(keypath: "graph", permission: "rw--")
        )
        try await assertDecodedReadiness(
            await VaultCell(owner: owner),
            owner: owner,
            expectedKey: "vault.state",
            requiredGrant: Grant(keypath: "vault", permission: "rw--")
        )
        try await assertDecodedReadiness(
            await FileCryptoCell(owner: owner),
            owner: owner,
            expectedKey: "fileCrypto.state",
            requiredGrant: Grant(keypath: "fileCrypto", permission: "rw--")
        )
        try await assertDecodedReadiness(
            await CommonsTaxonomyCell(owner: owner),
            owner: owner,
            expectedKey: "taxonomy.status",
            requiredGrant: Grant(keypath: "taxonomy", permission: "rw--")
        )
        try await assertDecodedReadiness(
            await CommonsResolverCell(owner: owner),
            owner: owner,
            expectedKey: "commons.status",
            requiredGrant: Grant(keypath: "commons", permission: "rw--")
        )
        try await assertDecodedReadiness(
            await IdentitiesCell(owner: owner),
            owner: owner,
            expectedKey: "identities",
            requiredGrant: Grant(keypath: "identities", permission: "rw--")
        )
        try await assertDecodedReadiness(
            await GoalEvaluationCell(owner: owner),
            owner: owner,
            expectedKey: "goal.state",
            requiredGrant: Grant(keypath: "goal", permission: "rw--")
        )
        try await assertDecodedReadiness(
            await TrustPacketCell(owner: owner),
            owner: owner,
            expectedKey: "trustPacket.state",
            requiredGrant: Grant(keypath: "trustPacket", permission: "rw--")
        )
        try await assertDecodedReadiness(
            await CalendarStoreCell(owner: owner),
            owner: owner,
            expectedKey: CalendarContract.Keys.state,
            requiredGrant: Grant(keypath: CalendarContract.Keys.state, permission: "r---")
        )
        try await assertDecodedReadiness(
            await CalendarImportExportCell(owner: owner),
            owner: owner,
            expectedKey: CalendarContract.Keys.importCalendar,
            requiredGrant: Grant(keypath: CalendarContract.Keys.importCalendar, permission: "rw--")
        )
        try await assertDecodedReadiness(
            await ChatCell(owner: owner),
            owner: owner,
            expectedKey: "state",
            requiredGrant: Grant(keypath: "state", permission: "rw--")
        )
    }

    func testAppleAndVaporDecodedCellsAreImmediatelyAndConcurrentlyReady() async throws {
        let owner = try await configuredOwnerAndDocumentRoot(suffix: "apple-vapor")

        try await assertDecodedReadiness(
            await NativeCalendarBridgeCell(owner: owner),
            owner: owner,
            expectedKey: CalendarContract.Keys.permissionStatus,
            requiredGrant: Grant(keypath: CalendarContract.Keys.permissionStatus, permission: "r---")
        )
        try await assertDecodedReadiness(
            await PerspectiveCell(owner: owner),
            owner: owner,
            expectedKey: "perspective.state",
            requiredGrant: Grant(keypath: "perspective", permission: "rw--")
        )
        try await assertDecodedReadiness(
            await RelationalLearningCell(owner: owner),
            owner: owner,
            expectedKey: "state",
            requiredGrant: Grant(keypath: "state", permission: "r---")
        )
        try await assertDecodedReadiness(
            await EntityAnchorCell(owner: owner),
            owner: owner,
            expectedKey: "person",
            requiredGrant: Grant(keypath: "person", permission: "rw--")
        )
        try await assertDecodedReadiness(
            await ShoppingHandlerCell(owner: owner),
            owner: owner,
            expectedKey: nil,
            requiredGrant: nil,
            unsupportedGrants: [
                Grant(keypath: "loadShopCell", permission: "rw--"),
                Grant(keypath: "getFromShop", permission: "rw--"),
                Grant(keypath: "setInShop", permission: "rw--"),
                Grant(keypath: "buyProductInShop", permission: "rw--")
            ]
        )
        try await assertDecodedReadiness(
            await OrchestratorCell(owner: owner),
            owner: owner,
            expectedKey: "skeleton",
            requiredGrant: Grant(keypath: "skeleton", permission: "r---")
        )
        try await assertDecodedReadiness(
            await EntityScannerCell(owner: owner),
            owner: owner,
            expectedKey: "capabilities",
            requiredGrant: Grant(keypath: "capabilities", permission: "r---")
        )
        try await assertDecodedReadiness(
            await LobbyCell(owner: owner),
            owner: owner,
            expectedKey: "purposes",
            requiredGrant: Grant(keypath: "start", permission: "rw--")
        )
        try await assertDecodedReadiness(
            await OwnershipTransferCell(owner: owner),
            owner: owner,
            expectedKey: nil,
            requiredGrant: nil,
            unsupportedGrants: [
                Grant(keypath: "configure", permission: "rw--"),
                Grant(keypath: "addCondition", permission: "rw--")
            ]
        )
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            try await assertDecodedReadiness(
                await AppleIntelligenceCell(owner: owner),
                owner: owner,
                expectedKey: "ai.state",
                requiredGrant: Grant(keypath: "ai", permission: "rw--")
            )
        }
        #endif
    }

    func testPreviouslyFatalPublicPathsFailClosedWithoutCrashing() async throws {
        let owner = try await configuredOwnerAndDocumentRoot(suffix: "no-crash")

        let goal = await Goal(owner: owner)
        goal.goalDefinitionString = "count >= 1"
        let decodedGoal = try JSONDecoder().decode(
            Goal.self,
            from: JSONEncoder().encode(goal)
        )
        XCTAssertEqual(decodedGoal.goalDefinitionString, "count >= 1")

        let anyCell = AnyCell(
            uuid: "public-snapshot",
            name: "Snapshot",
            contractTemplate: Agreement(owner: owner),
            owner: owner,
            identityDomain: "private"
        )
        do {
            _ = try await anyCell.flow(requester: owner)
            XCTFail("AnyCell.flow must fail when the snapshot has no live transport")
        } catch AnyCellError.unsupportedOperation(let operation) {
            XCTAssertEqual(operation, "flow")
        }

        let bridge = BridgeBase(owner: owner)
        let bridgeOwner = try await bridge.getOwner(requester: owner)
        XCTAssertEqual(bridgeOwner.uuid, owner.uuid)

        let didVault = DIDIdentityVault()
        do {
            _ = try await didVault.signMessageForIdentity(
                messageData: Data("must-not-sign".utf8),
                identity: owner
            )
            XCTFail("A public DID descriptor vault must not expose signing authority")
        } catch DIDIdentityVaultError.signingUnsupported {
            // Expected typed failure.
        }
    }

    func testRuntimeBindingPrivilegeIsInstanceBound() async throws {
        let owner = try await configuredOwnerAndDocumentRoot(suffix: "instance-bound-token")
        let target = await GeneralCell(owner: owner)
        let probe = await RuntimeBindingPrivilegeProbeCell(owner: owner)
        probe.crossCellTarget = target

        try await probe.ensureRuntimeReady()

        let keys = try await target.keys(requester: owner)
        XCTAssertFalse(keys.contains(RuntimeBindingPrivilegeProbeCell.crossCellKey))
    }

    func testRuntimeBindingPrivilegeExpiresBeforeEscapedChildTaskRuns() async throws {
        let owner = try await configuredOwnerAndDocumentRoot(suffix: "expired-token")
        let gate = RuntimeBindingPrivilegeGate()
        let probe = await RuntimeBindingPrivilegeProbeCell(owner: owner)
        probe.escapeGate = gate

        try await probe.ensureRuntimeReady()
        await gate.release()
        await probe.awaitEscapedAttempt()

        let keys = try await probe.keys(requester: owner)
        XCTAssertFalse(keys.contains(RuntimeBindingPrivilegeProbeCell.escapedChildKey))
    }

    func testAdvertisePropagatesReadinessFailureInsteadOfPublishingEmptyCell() async throws {
        let owner = try await configuredOwnerAndDocumentRoot(suffix: "advertise-failure")
        let probe = await RuntimeBindingPrivilegeProbeCell(owner: owner)
        probe.failInstallation = true

        do {
            _ = try await probe.advertise(for: owner)
            XCTFail("A Cell whose runtime bindings failed must not advertise an empty snapshot")
        } catch RuntimeBindingPrivilegeProbeError.installationFailed {
            // Expected typed failure.
        }
    }

    func testAdvertisedCellAndAgreementRedactRuntimeIdentityMetadata() async throws {
        let owner = try await configuredOwnerAndDocumentRoot(suffix: "public-descriptor")
        owner.properties = ["private-marker": .string("must-not-publish")]
        owner.homeVaultReference = "private-vault-reference"
        let cell = await GeneralCell(owner: owner)

        let advertised = try await cell.advertise(for: owner)
        let encoded = try JSONEncoder().encode(advertised)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(json.contains("must-not-publish"))
        XCTAssertFalse(json.contains("private-vault-reference"))
        XCTAssertFalse(json.contains("homeVaultReference"))
        XCTAssertNil(cell.storedOwnerIdentity.identityVault)
        XCTAssertNil(cell.storedOwnerIdentity.properties)
    }

    func testInertBridgeOperationsFailClosedWithTypedErrors() async throws {
        let owner = try await configuredOwnerAndDocumentRoot(suffix: "bridge-fail-closed")
        let bridge = BridgeBase(owner: owner)

        do {
            _ = try await bridge.state(requester: owner)
            XCTFail("Inert bridge state must not wait or return placeholder data")
        } catch BridgeOperationError.unsupportedOperation(let operation) {
            XCTAssertEqual(operation, "state")
        }
        do {
            _ = try await bridge.keys(requester: owner)
            XCTFail("Inert bridge keys must not return placeholder data")
        } catch BridgeOperationError.unsupportedOperation(let operation) {
            XCTAssertEqual(operation, "keys")
        }
        do {
            _ = try await bridge.typeForKey(key: "example", requester: owner)
            XCTFail("Inert bridge schema lookup must not return placeholder data")
        } catch BridgeOperationError.unsupportedOperation(let operation) {
            XCTAssertEqual(operation, "typeForKey:example")
        }
    }

    func testSourceBackedReadinessPreservesCorruptFilesAndFails() async throws {
        let owner = try await configuredOwnerAndDocumentRoot(suffix: "source-preservation")
        let corruptData = Data("{not-valid-json".utf8)

        let perspectiveSource = await PerspectiveCell(owner: owner)
        let perspectiveData = try JSONEncoder().encode(perspectiveSource)
        let perspectiveFile = try writeSourceFixture(
            corruptData,
            cellName: perspectiveSource.name,
            filename: "Perspective.json"
        )
        let restoredPerspective = try JSONDecoder().decode(PerspectiveCell.self, from: perspectiveData)
        do {
            _ = try await restoredPerspective.keys(requester: owner)
            XCTFail("Corrupt Perspective source must not be replaced with bootstrap data")
        } catch {
            XCTAssertEqual(try Data(contentsOf: perspectiveFile), corruptData)
        }

        let orchestratorSource = await OrchestratorCell(owner: owner)
        let orchestratorData = try JSONEncoder().encode(orchestratorSource)
        let orchestratorFile = try writeSourceFixture(
            corruptData,
            cellName: orchestratorSource.name,
            filename: "CellConfiguration.json"
        )
        let restoredOrchestrator = try JSONDecoder().decode(OrchestratorCell.self, from: orchestratorData)
        do {
            _ = try await restoredOrchestrator.keys(requester: owner)
            XCTFail("Corrupt Orchestrator source must not be overwritten or marked ready")
        } catch {
            XCTAssertEqual(try Data(contentsOf: orchestratorFile), corruptData)
        }
    }

    func testAsyncCellJSONDecoderReturnsPreparedCell() async throws {
        let owner = try await configuredOwnerAndDocumentRoot(suffix: "async-coder")
        let source = await ChatCell(owner: owner)
        let encoded = try CellJSONCoder.encodeCell(cellClassName: "ChatCell", cell: source)
        var coder = CellJSONCoder()
        try coder.register(name: "ChatCell", type: ChatCell.self)

        let decoded = try await coder.decodeRuntimeReadyEmitCell(from: encoded)
        let chat = try XCTUnwrap(decoded as? ChatCell)
        let keys = try await chat.keys(requester: owner)
        XCTAssertTrue(keys.contains("state"))
    }

    func testPersistedOwnerRuntimeBindingRequiresSameKeyControl() async throws {
        let owner = try await configuredOwnerAndDocumentRoot(suffix: "owner-rebind")
        let source = await GeneralCell(owner: owner)
        let restored = try JSONDecoder().decode(
            GeneralCell.self,
            from: JSONEncoder().encode(source)
        )
        XCTAssertNil(restored.storedOwnerIdentity.identityVault)

        let attackerVault = MockIdentityVault()
        let attackerIdentity = await attackerVault.identity(for: "attacker", makeNewIfNotFound: true)
        let attackerKeySource = try XCTUnwrap(attackerIdentity)
        let attacker = Identity(owner.uuid, displayName: "attacker", identityVault: attackerVault)
        attacker.publicSecureKey = attackerKeySource.publicSecureKey
        let attackerBound = await restored.bindStoredOwnerToRuntimeIdentity(attacker)
        let ownerBound = await restored.bindStoredOwnerToRuntimeIdentity(owner)
        XCTAssertFalse(attackerBound)
        XCTAssertTrue(ownerBound)
        XCTAssertNil(restored.storedOwnerIdentity.identityVault)
    }

    func testMalformedPersistedAgreementFailsDecodeWithoutCrashing() async throws {
        let owner = try await configuredOwnerAndDocumentRoot(suffix: "malformed-agreement")
        let source = await GeneralCell(owner: owner)
        let encoded = try JSONEncoder().encode(source)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["contractTemplate"] = "invalid-agreement"
        let malformed = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(GeneralCell.self, from: malformed))
    }

    private func configuredOwnerAndDocumentRoot(suffix: String) async throws -> Identity {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellprotocol-readiness-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)
        return try XCTUnwrap(owner)
    }

    private func writeSourceFixture(_ data: Data, cellName: String, filename: String) throws -> URL {
        let root = try XCTUnwrap(CellBase.documentRootPath)
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("CellsContainer", isDirectory: true)
            .appendingPathComponent(cellName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(filename)
        try data.write(to: file)
        return file
    }

    private func assertDecodedReadiness<T: GeneralCell>(
        _ source: T,
        owner: Identity,
        expectedKey: String?,
        requiredGrant: Grant?,
        unsupportedGrants: [Grant] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let encoded = try JSONEncoder().encode(source)

        let immediate = try JSONDecoder().decode(T.self, from: encoded)
        let immediateKeys = try await immediate.keys(requester: owner)
        if let expectedKey {
            XCTAssertTrue(immediateKeys.contains(expectedKey), "Missing immediately restored key \(expectedKey) on \(T.self)", file: file, line: line)
        }
        if let requiredGrant {
            XCTAssertTrue(immediate.agreementTemplate.checkGrant(requestedGrant: requiredGrant), file: file, line: line)
        }
        for unsupportedGrant in unsupportedGrants {
            XCTAssertFalse(immediate.agreementTemplate.checkGrant(requestedGrant: unsupportedGrant), file: file, line: line)
        }

        let concurrent = try JSONDecoder().decode(T.self, from: encoded)
        let persistedGrantCount = concurrent.agreementTemplate.grants.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    try await concurrent.ensureRuntimeReady()
                }
            }
            try await group.waitForAll()
        }

        let concurrentKeys = try await concurrent.keys(requester: owner)
        if let expectedKey {
            XCTAssertTrue(concurrentKeys.contains(expectedKey), "Missing concurrently restored key \(expectedKey) on \(T.self)", file: file, line: line)
        }
        XCTAssertEqual(concurrent.agreementTemplate.grants.count, persistedGrantCount, "Runtime preparation duplicated persisted grants on \(T.self)", file: file, line: line)
        if let requiredGrant {
            XCTAssertTrue(concurrent.agreementTemplate.checkGrant(requestedGrant: requiredGrant), file: file, line: line)
        }
        for unsupportedGrant in unsupportedGrants {
            XCTAssertFalse(concurrent.agreementTemplate.checkGrant(requestedGrant: unsupportedGrant), file: file, line: line)
        }
    }
}

private actor RuntimeBindingPrivilegeGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

private final class RuntimeBindingPrivilegeProbeCell: GeneralCell {
    static let crossCellKey = "probe.cross-cell"
    static let escapedChildKey = "probe.escaped-child"

    var crossCellTarget: GeneralCell?
    var escapeGate: RuntimeBindingPrivilegeGate?
    var failInstallation = false
    private var escapedAttempt: Task<Void, Never>?

    required init(owner: Identity) async {
        await super.init(owner: owner)
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    override func installCellRuntimeBindingsForAccess() async throws {
        if failInstallation {
            throw RuntimeBindingPrivilegeProbeError.installationFailed
        }
        if let crossCellTarget {
            let exposedOwner = try await crossCellTarget.getOwner(requester: Identity())
            await crossCellTarget.addInterceptForGet(
                requester: exposedOwner,
                key: Self.crossCellKey
            ) { _, _ in
                .string("must-not-register")
            }
        }

        if let escapeGate {
            let exposedOwner = try await getOwner(requester: Identity())
            escapedAttempt = Task { [weak self] in
                await escapeGate.wait()
                guard let self else { return }
                await self.addInterceptForGet(
                    requester: exposedOwner,
                    key: Self.escapedChildKey
                ) { _, _ in
                    .string("must-not-register")
                }
            }
        }
    }

    func awaitEscapedAttempt() async {
        await escapedAttempt?.value
    }
}

private enum RuntimeBindingPrivilegeProbeError: Error {
    case installationFailed
}
