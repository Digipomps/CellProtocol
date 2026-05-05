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

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousScopedSecretProvider = CellBase.defaultScopedSecretProvider
        previousPersistedCellMasterKey = CellBase.persistedCellMasterKey
        previousDocumentRootPath = CellBase.documentRootPath
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
