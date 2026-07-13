// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
import Foundation

#if canImport(CellVapor)
import CellVapor
#endif

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class ResolverTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousScopedSecretProvider: ScopedSecretProviderProtocol?
    private var previousPersistedCellMasterKey: Data?
    private var previousDocumentRootPath: String?
    private var previousTypedCellUtility: TypedCellUtility?
    private var previousGlobalTypedCellUtility: TypedCellProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousScopedSecretProvider = CellBase.defaultScopedSecretProvider
        previousPersistedCellMasterKey = CellBase.persistedCellMasterKey
        previousDocumentRootPath = CellBase.documentRootPath
        previousGlobalTypedCellUtility = CellBase.typedCellUtility
        CellBase.defaultIdentityVault = MockIdentityVault()
        CellBase.defaultCellResolver = CellResolver.sharedInstance
        previousTypedCellUtility = CellResolver.sharedInstance.tcUtility
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.defaultScopedSecretProvider = previousScopedSecretProvider
        CellBase.persistedCellMasterKey = previousPersistedCellMasterKey
        CellBase.documentRootPath = previousDocumentRootPath
        CellBase.typedCellUtility = previousGlobalTypedCellUtility
        CellResolver.sharedInstance.tcUtility = previousTypedCellUtility
        super.tearDown()
    }

    func testTemplateResolveCreatesNewInstances() async throws {
        let resolver = CellResolver.sharedInstance
        let name = "Template-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .template, identityDomain: "private", type: GeneralCell.self)

        let identity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        let first = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)
        let second = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)

        XCTAssertNotEqual(first.uuid, second.uuid)
    }

    func testTemplateResolveUsesRequesterAsOwner() async throws {
        let resolver = CellResolver.sharedInstance
        let name = "TemplateRequesterOwner-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .template, identityDomain: "scaffold-template-owner", type: GeneralCell.self)

        guard let requesterA = await CellBase.defaultIdentityVault?.identity(for: "template-requester-a", makeNewIfNotFound: true),
              let requesterB = await CellBase.defaultIdentityVault?.identity(for: "template-requester-b", makeNewIfNotFound: true) else {
            return XCTFail("Expected requester identities")
        }

        guard let first = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: requesterA) as? GeneralCell,
              let second = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: requesterB) as? GeneralCell else {
            return XCTFail("Expected template resolves to create GeneralCell instances")
        }

        let firstOwner = try await first.getOwner(requester: requesterA)
        let secondOwner = try await second.getOwner(requester: requesterB)

        XCTAssertNotEqual(first.uuid, second.uuid)
        XCTAssertEqual(firstOwner.uuid, requesterA.uuid)
        XCTAssertEqual(secondOwner.uuid, requesterB.uuid)
    }

    func testScaffoldUniqueReturnsSameInstance() async throws {
        let resolver = CellResolver.sharedInstance
        let name = "Scaffold-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .scaffoldUnique, identityDomain: "private", type: GeneralCell.self)

        let identity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        let first = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)
        let second = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity!)

        XCTAssertEqual(first.uuid, second.uuid)
    }

    func testScaffoldUniqueSameForDifferentIdentities() async throws {
        let resolver = CellResolver.sharedInstance
        let name = "ScaffoldShared-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .scaffoldUnique, identityDomain: "private", type: GeneralCell.self)

        let identityA = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        let identityB = await CellBase.defaultIdentityVault?.identity(for: "privateB", makeNewIfNotFound: true)

        let first = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identityA!)
        let second = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identityB!)

        XCTAssertEqual(first.uuid, second.uuid)
    }

    func testIdentityUniqueDifferentPerIdentity() async throws {
        let resolver = CellResolver.sharedInstance
        let name = "Identity-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .identityUnique, identityDomain: "private", type: GeneralCell.self)

        let identityA = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        let identityB = await CellBase.defaultIdentityVault?.identity(for: "privateB", makeNewIfNotFound: true)

        let first = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identityA!)
        let second = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identityB!)
        let third = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identityA!)

        XCTAssertNotEqual(first.uuid, second.uuid)
        XCTAssertEqual(first.uuid, third.uuid)
    }

    func testUnsupportedSchemeThrows() async {
        let resolver = CellResolver.sharedInstance
        let identity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.cellAtEndpoint(endpoint: "http://example.com", requester: identity!)
        }
    }

    func testInvalidUrlThrows() async {
        let resolver = CellResolver.sharedInstance
        let identity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.cellAtEndpoint(endpoint: "://", requester: identity!)
        }
    }

    func testDuplicateResolveThrows() async throws {
        let resolver = CellResolver.sharedInstance
        let name = "Dup-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .template, identityDomain: "private", type: GeneralCell.self)

        await XCTAssertThrowsErrorAsync {
            try await resolver.addCellResolve(name: name, cellScope: .template, identityDomain: "private", type: GeneralCell.self)
        }
    }

    func testAuditorThrowsInsteadOfCrashingForAlreadyRegisteredPersonalInstance() async throws {
        let auditor = ResolverAuditor()
        let identity = Identity("personal-auditor-owner", displayName: "Personal Auditor Owner", identityVault: nil)
        let cell = TestEmitCell(owner: identity, uuid: "personal-auditor-cell")
        try await auditor.registerReference(cell)

        do {
            try await auditor.registerPersonalReference(cell, endpoint: "PersonalCell", identity: identity)
            XCTFail("Expected personalInstanceAlreadyRegistered")
        } catch ResolverAuditor.AuditorError.personalInstanceAlreadyRegistered {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRegistrationWaitsForReadinessAndFailureNeverPublishesCell() async throws {
        let resolver = CellResolver.sharedInstance
        let resolvedOwner = await CellBase.defaultIdentityVault?.identity(
            for: "resolver-readiness",
            makeNewIfNotFound: true
        )
        let owner = try XCTUnwrap(resolvedOwner)
        let delayedName = "DelayedReadiness-\(UUID().uuidString)"
        let delayedCell = await ResolverReadinessProbeCell(owner: owner)
        let gate = ResolverReadinessGate()
        delayedCell.readinessGate = gate

        let registration = Task {
            try await resolver.registerNamedEmitCell(
                name: delayedName,
                emitCell: delayedCell,
                scope: .scaffoldUnique,
                identity: owner
            )
        }

        await gate.waitUntilInstallationStarts()
        let installedBeforeRelease = await delayedCell.readinessState.isInstalled()
        let publishedBeforeRelease = await resolver.cellUUID(for: delayedName)
        XCTAssertFalse(installedBeforeRelease)
        XCTAssertNil(
            publishedBeforeRelease,
            "A Cell must not be visible in the resolver while runtime bindings are still installing."
        )

        await gate.releaseInstallation()
        try await registration.value
        let installedAfterRelease = await delayedCell.readinessState.isInstalled()
        let publishedAfterRelease = await resolver.cellUUID(for: delayedName)
        XCTAssertTrue(installedAfterRelease)
        XCTAssertEqual(publishedAfterRelease, delayedCell.uuid)

        let failingName = "FailingReadiness-\(UUID().uuidString)"
        let failingCell = await ResolverReadinessProbeCell(owner: owner)
        failingCell.failInstallation = true
        do {
            try await resolver.registerNamedEmitCell(
                name: failingName,
                emitCell: failingCell,
                scope: .scaffoldUnique,
                identity: owner
            )
            XCTFail("Expected readiness failure")
        } catch ResolverReadinessProbeError.installationFailed {
            // Expected: registration must fail before resolver publication.
        }
        let failingPublishedUUID = await resolver.cellUUID(for: failingName)
        XCTAssertNil(failingPublishedUUID)

        await resolver.unregisterEmitCell(uuid: delayedCell.uuid)
    }

    func testResolverPreparesFreshAndDecodedCellsBeforeReturningThem() async throws {
        let resolver = CellResolver.sharedInstance
        let resolvedOwner = await CellBase.defaultIdentityVault?.identity(
            for: "resolver-ready-return",
            makeNewIfNotFound: true
        )
        let owner = try XCTUnwrap(resolvedOwner)

        let templateName = "ReadyTemplate-\(UUID().uuidString)"
        try await resolver.addCellResolve(
            name: templateName,
            cellScope: .template,
            identityDomain: "resolver-ready-return",
            type: ResolverReadinessProbeCell.self
        )
        let resolvedFresh = try await resolver.cellAtEndpoint(
            endpoint: "cell:///\(templateName)",
            requester: owner
        )
        let fresh = try XCTUnwrap(resolvedFresh as? ResolverReadinessProbeCell)
        let freshInstalled = await fresh.readinessState.isInstalled()
        XCTAssertTrue(freshInstalled)

        let persistedSource = await ResolverReadinessProbeCell(owner: owner)
        let rawDecoded = try JSONDecoder().decode(
            ResolverReadinessProbeCell.self,
            from: JSONEncoder().encode(persistedSource)
        )
        let rawDecodedInstalled = await rawDecoded.readinessState.isInstalled()
        XCTAssertFalse(rawDecodedInstalled)
        CellBase.typedCellUtility = FixedDecodedCellUtility(cell: rawDecoded)

        let resolvedLoaded = try await resolver.loadTypedEmitCell(with: rawDecoded.uuid)
        let loaded = try XCTUnwrap(resolvedLoaded as? ResolverReadinessProbeCell)
        let loadedInstalled = await loaded.readinessState.isInstalled()
        XCTAssertTrue(
            loadedInstalled,
            "Resolver persistence APIs must not return a raw decoded Cell before runtime bindings are installed."
        )
        await resolver.unregisterEmitCell(uuid: loaded.uuid)
    }

    func testScopedSecretProviderSeedsPersistedCellMasterKeyBeforeLegacyVaultAPI() async throws {
#if canImport(CellVapor)
        let resolver = CellResolver.sharedInstance
        let secretSeed = Data(repeating: 0x42, count: 48)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-secret-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let countingVault = CountingLegacyKeyVault()
        CellBase.defaultIdentityVault = countingVault
        CellBase.defaultScopedSecretProvider = FixedScopedSecretProvider(secretData: secretSeed)
        CellBase.persistedCellMasterKey = nil
        CellBase.documentRootPath = tempRoot.appendingPathComponent("CellsContainer").path
        resolver.tcUtility = TypedCellUtility(storage: FileSystemCellStorage())

        let name = "Persisted-\(UUID().uuidString)"
        try await resolver.addCellResolve(
            name: name,
            cellScope: .scaffoldUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: GeneralCell.self
        )

        guard let identity = await countingVault.identity(for: "private", makeNewIfNotFound: true) else {
            XCTFail("Expected test vault identity")
            return
        }
        _ = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: identity)

        let expected = Data(SHA256.hash(data: secretSeed))
        XCTAssertEqual(CellBase.persistedCellMasterKey, expected)
        let acquireCallCount = await countingVault.acquireCallCount
        XCTAssertEqual(acquireCallCount, 0)
#else
        throw XCTSkip("CellVapor-backed file storage is unavailable in this test environment")
#endif
    }
}

private actor FixedScopedSecretProvider: ScopedSecretProviderProtocol {
    let secretData: Data

    init(secretData: Data) {
        self.secretData = secretData
    }

    func scopedSecretData(tag: String, minimumLength: Int) async throws -> Data {
        if secretData.count >= minimumLength {
            return secretData
        }
        return secretData + Data(repeating: 0x00, count: minimumLength - secretData.count)
    }
}

private enum ResolverReadinessProbeError: Error {
    case installationFailed
}

private actor ResolverReadinessState {
    private var installed = false

    func markInstalled() {
        installed = true
    }

    func isInstalled() -> Bool {
        installed
    }
}

private actor ResolverReadinessGate {
    private var installationStarted = false
    private var installationReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilInstallationStarts() async {
        if installationStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func blockInstallationUntilReleased() async {
        installationStarted = true
        let pendingStartWaiters = startWaiters
        startWaiters.removeAll()
        pendingStartWaiters.forEach { $0.resume() }

        if installationReleased { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func releaseInstallation() {
        installationReleased = true
        let pendingReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll()
        pendingReleaseWaiters.forEach { $0.resume() }
    }
}

private final class ResolverReadinessProbeCell: GeneralCell {
    let readinessState = ResolverReadinessState()
    var readinessGate: ResolverReadinessGate?
    var failInstallation = false

    required init(owner: Identity) async {
        await super.init(owner: owner)
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    override func installCellRuntimeBindingsForAccess() async throws {
        if failInstallation {
            throw ResolverReadinessProbeError.installationFailed
        }
        if let readinessGate {
            await readinessGate.blockInstallationUntilReleased()
        }
        await readinessState.markInstalled()
    }
}

private final class FixedDecodedCellUtility: TypedCellProtocol {
    private let cell: Emit?

    init(cell: Emit) {
        self.cell = cell
    }

    required init(storage: CellStorage) {
        cell = nil
    }

    func loadTypedEmitCell(with uuid: String) -> Emit? {
        cell?.uuid == uuid ? cell : nil
    }

    func loadTypedEmitCell(at path: String) -> Emit? {
        cell
    }

    func storeAsTypedCell(cellName: String, cell: Codable, uuid: String) {}

    func storeAsTypedCell(
        cellName: String,
        cell: Codable,
        uuid: String,
        options: CellStorageWriteOptions
    ) {}
}

private actor CountingLegacyKeyVault: IdentityVaultProtocol {
    private var identitiesByContext: [String: Identity] = [:]
    private(set) var acquireCallCount = 0

    func initialize() async -> IdentityVaultProtocol {
        self
    }

    func addIdentity(identity: inout Identity, for identityContext: String) async {
        identity.identityVault = self
        identitiesByContext[identityContext] = identity
    }

    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? {
        if let existing = identitiesByContext[identityContext] {
            return existing
        }
        guard makeNewIfNotFound else {
            return nil
        }
        let identity = Identity(UUID().uuidString, displayName: identityContext, identityVault: self)
        identitiesByContext[identityContext] = identity
        return identity
    }

    func saveIdentity(_ identity: Identity) async {
        identitiesByContext[identity.displayName] = identity
    }

    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        messageData + Data(identity.uuid.utf8)
    }

    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        signature == messageData + Data(identity.uuid.utf8)
    }

    func randomBytes64() async -> Data? {
        Data(repeating: 0x22, count: 64)
    }

    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        acquireCallCount += 1
        return ("legacy-\(tag)", "legacy-iv-\(tag)")
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // expected
    }
}
