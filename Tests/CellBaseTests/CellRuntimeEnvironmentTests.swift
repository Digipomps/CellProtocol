// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class CellRuntimeEnvironmentTests: XCTestCase {
    private var savedDefaultIdentityVault: IdentityVaultProtocol?
    private var savedDefaultCellResolver: CellResolverProtocol?
    private var savedDocumentRootPath: String?
    private var savedHostname: String = "localhost"
    private var savedPersistedCellMasterKey: Data?
    private var savedSendDataAsText = false
    private var savedDebugValidateAccessForEverything = false
    private var savedWebSocketSecurityPolicy: CellBase.WebSocketSecurityPolicy = .developmentOnlyInsecureAllowed
    private var savedExploreContractEnforcementMode: CellBase.ExploreContractEnforcementMode = .permissive
    private var savedEnabledDiagnosticLogDomains = Set<CellBase.DiagnosticLogDomain>()
    private var savedDiagnosticLogHandler: ((CellBase.DiagnosticLogDomain, String) -> Void)?
    private var savedRemoteWebSocketQueryItemsProvider: (@Sendable (URL) -> [URLQueryItem])?

    override func setUp() {
        super.setUp()
        savedDefaultIdentityVault = CellBase.defaultIdentityVault
        savedDefaultCellResolver = CellBase.defaultCellResolver
        savedDocumentRootPath = CellBase.documentRootPath
        savedHostname = CellBase.hostname
        savedPersistedCellMasterKey = CellBase.persistedCellMasterKey
        savedSendDataAsText = CellBase.sendDataAsText
        savedDebugValidateAccessForEverything = CellBase.debugValidateAccessForEverything
        savedWebSocketSecurityPolicy = CellBase.webSocketSecurityPolicy
        savedExploreContractEnforcementMode = CellBase.exploreContractEnforcementMode
        savedEnabledDiagnosticLogDomains = CellBase.enabledDiagnosticLogDomains
        savedDiagnosticLogHandler = CellBase.diagnosticLogHandler
        savedRemoteWebSocketQueryItemsProvider = CellBase.remoteWebSocketQueryItemsProvider
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = savedDefaultIdentityVault
        CellBase.defaultCellResolver = savedDefaultCellResolver
        CellBase.documentRootPath = savedDocumentRootPath
        CellBase.hostname = savedHostname
        CellBase.persistedCellMasterKey = savedPersistedCellMasterKey
        CellBase.sendDataAsText = savedSendDataAsText
        CellBase.debugValidateAccessForEverything = savedDebugValidateAccessForEverything
        CellBase.webSocketSecurityPolicy = savedWebSocketSecurityPolicy
        CellBase.exploreContractEnforcementMode = savedExploreContractEnforcementMode
        CellBase.enabledDiagnosticLogDomains = savedEnabledDiagnosticLogDomains
        CellBase.diagnosticLogHandler = savedDiagnosticLogHandler
        CellBase.remoteWebSocketQueryItemsProvider = savedRemoteWebSocketQueryItemsProvider
        super.tearDown()
    }

    func testLegacyStaticsProxyThroughRuntimeEnvironment() {
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()

        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver
        CellBase.documentRootPath = "/tmp/cell-runtime"
        CellBase.hostname = "runtime.local"
        CellBase.sendDataAsText = true
        CellBase.debugValidateAccessForEverything = true
        CellBase.webSocketSecurityPolicy = .requireTLS
        CellBase.exploreContractEnforcementMode = .strict
        CellBase.enabledDiagnosticLogDomains = [.bridge, .resolver]

        let returnedVault = CellBase.defaultIdentityVault as? MockIdentityVault
        let returnedResolver = CellBase.defaultCellResolver as? MockCellResolver

        XCTAssertTrue(returnedVault === vault)
        XCTAssertTrue(returnedResolver === resolver)
        XCTAssertEqual(CellBase.documentRootPath, "/tmp/cell-runtime")
        XCTAssertEqual(CellBase.hostname, "runtime.local")
        XCTAssertTrue(CellBase.sendDataAsText)
        XCTAssertTrue(CellBase.debugValidateAccessForEverything)
        XCTAssertFalse(CellBase.allowsInsecureWebSockets)
        XCTAssertEqual(CellBase.exploreContractEnforcementMode, .strict)
        XCTAssertTrue(CellBase.diagnosticLoggingEnabled(for: .bridge))
        XCTAssertFalse(CellBase.diagnosticLoggingEnabled(for: .flow))
    }

    func testDiagnosticLogStillUsesPublicHandlerAndDomainFilter() {
        var received = [(CellBase.DiagnosticLogDomain, String)]()
        var renderedHiddenMessage = false
        CellBase.enabledDiagnosticLogDomains = [.bridge]
        CellBase.diagnosticLogHandler = { domain, message in
            received.append((domain, message))
        }

        CellBase.diagnosticLog(renderHiddenMessage(&renderedHiddenMessage), domain: .resolver)
        CellBase.diagnosticLog("visible", domain: .bridge)

        XCTAssertFalse(renderedHiddenMessage)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, .bridge)
        XCTAssertEqual(received.first?.1, "visible")
    }

    func testRemoteWebSocketQueryProviderRemainsSourceCompatible() throws {
        CellBase.remoteWebSocketQueryItemsProvider = { url in
            [URLQueryItem(name: "host", value: url.host)]
        }

        let url = try XCTUnwrap(URL(string: "wss://example.test/bridge"))
        let items = try XCTUnwrap(CellBase.remoteWebSocketQueryItemsProvider?(url))

        XCTAssertEqual(items, [URLQueryItem(name: "host", value: "example.test")])
    }

    func testReplacingResolverReleasesOldGraphOutsideRuntimeLock() async throws {
        try await installResolverThatOwnsCellOnlyThroughCellBase()

        CellBase.defaultCellResolver = nil

        XCTAssertNil(CellBase.defaultCellResolver)
    }

    func testConfigurePersistedCellMasterKeyStillDerivesStableSHA256Key() {
        let seed = Data("runtime-seed".utf8)

        CellBase.configurePersistedCellMasterKey(seedData: seed)
        let firstKey = CellBase.persistedCellMasterKey

        CellBase.persistedCellMasterKey = nil
        CellBase.configurePersistedCellMasterKey(seedData: seed)

        XCTAssertEqual(CellBase.persistedCellMasterKey, firstKey)
        XCTAssertEqual(CellBase.persistedCellMasterKey?.count, 32)
    }

    private func renderHiddenMessage(_ rendered: inout Bool) -> String {
        rendered = true
        return "hidden"
    }

    private func installResolverThatOwnsCellOnlyThroughCellBase() async throws {
        let vault = MockIdentityVault()
        let owner = Identity("runtime-owner", displayName: "Runtime Owner", identityVault: vault)
        let resolver = MockCellResolver()
        let cell = await GeneralCell(owner: owner)

        try await resolver.registerNamedEmitCell(
            name: "RuntimeOwnedCell",
            emitCell: cell,
            scope: .template,
            identity: owner
        )
        CellBase.defaultCellResolver = resolver
    }
}
