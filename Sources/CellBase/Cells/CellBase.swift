// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors


import Crypto
import Foundation

public struct CellBase {
    private static let runtimeEnvironment = CellRuntimeEnvironment()

    public enum WebSocketSecurityPolicy {
        case developmentOnlyInsecureAllowed
        case requireTLS
    }

    public enum ExploreContractEnforcementMode {
        case permissive
        case warn
        case strict
    }

    public enum DiagnosticLogDomain: String, CaseIterable {
        case lifecycle
        case flow
        case resolver
        case skeleton
        case agreement
        case semantics
        case identity
        case credentials
        case contracts
        case bridge
    }

    public static var defaultIdentityVault: IdentityVaultProtocol? {
        get { runtimeEnvironment.defaultIdentityVault }
        set { runtimeEnvironment.defaultIdentityVault = newValue }
    }

    public static var defaultScopedSecretProvider: ScopedSecretProviderProtocol? {
        get { runtimeEnvironment.defaultScopedSecretProvider }
        set { runtimeEnvironment.defaultScopedSecretProvider = newValue }
    }

    public static var defaultCellResolver: CellResolverProtocol? {
        get { runtimeEnvironment.defaultCellResolver }
        set { runtimeEnvironment.defaultCellResolver = newValue }
    }

    public static var documentRootPath: String? {
        get { runtimeEnvironment.documentRootPath }
        set { runtimeEnvironment.documentRootPath = newValue }
    }

    public static var typedCellUtility: TypedCellProtocol? {
        get { runtimeEnvironment.typedCellUtility }
        set { runtimeEnvironment.typedCellUtility = newValue }
    }

    public static var hostname: String {
        get { runtimeEnvironment.hostname }
        set { runtimeEnvironment.hostname = newValue }
    }

    public static var persistedCellMasterKey: Data? {
        get { runtimeEnvironment.persistedCellMasterKey }
        set { runtimeEnvironment.persistedCellMasterKey = newValue }
    }
    
    
// Debug flags
    public static var sendDataAsText: Bool {
        get { runtimeEnvironment.sendDataAsText }
        set { runtimeEnvironment.sendDataAsText = newValue }
    }

    public static var debugValidateAccessForEverything: Bool {
        get { runtimeEnvironment.debugValidateAccessForEverything }
        set { runtimeEnvironment.debugValidateAccessForEverything = newValue }
    }

    public static var webSocketSecurityPolicy: WebSocketSecurityPolicy {
        get { runtimeEnvironment.webSocketSecurityPolicy }
        set { runtimeEnvironment.webSocketSecurityPolicy = newValue }
    }

    public static var exploreContractEnforcementMode: ExploreContractEnforcementMode {
        get { runtimeEnvironment.exploreContractEnforcementMode }
        set { runtimeEnvironment.exploreContractEnforcementMode = newValue }
    }

    public static var enabledDiagnosticLogDomains: Set<DiagnosticLogDomain> {
        get { runtimeEnvironment.enabledDiagnosticLogDomains }
        set { runtimeEnvironment.enabledDiagnosticLogDomains = newValue }
    }

    public static var diagnosticLogHandler: ((DiagnosticLogDomain, String) -> Void)? {
        get { runtimeEnvironment.diagnosticLogHandler }
        set { runtimeEnvironment.diagnosticLogHandler = newValue }
    }

    public static var remoteWebSocketQueryItemsProvider: (@Sendable (URL) -> [URLQueryItem])? {
        get { runtimeEnvironment.remoteWebSocketQueryItemsProvider }
        set { runtimeEnvironment.remoteWebSocketQueryItemsProvider = newValue }
    }

    public static var allowsInsecureWebSockets: Bool {
        switch webSocketSecurityPolicy {
        case .requireTLS:
            return false
        case .developmentOnlyInsecureAllowed:
#if DEBUG
            return true
#else
            return false
#endif
        }
    }

    public static func configurePersistedCellMasterKey(seedData: Data) {
        let digest = SHA256.hash(data: seedData)
        persistedCellMasterKey = Data(digest)
    }

    public static func diagnosticLoggingEnabled(for domain: DiagnosticLogDomain) -> Bool {
        runtimeEnvironment.diagnosticLoggingEnabled(for: domain)
    }

    public static func diagnosticLog(_ message: @autoclosure () -> String, domain: DiagnosticLogDomain) {
        runtimeEnvironment.diagnosticLog(message(), domain: domain)
    }
    
    public init() {
    }
}
