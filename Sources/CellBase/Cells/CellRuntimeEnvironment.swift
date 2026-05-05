// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

internal final class CellRuntimeEnvironment: @unchecked Sendable {
    private let lock = NSLock()

    private var storedDefaultIdentityVault: IdentityVaultProtocol?
    private var storedDefaultScopedSecretProvider: ScopedSecretProviderProtocol?
    private var storedDefaultCellResolver: CellResolverProtocol?
    private var storedDocumentRootPath: String?
    private var storedTypedCellUtility: TypedCellProtocol?
    private var storedHostname = "localhost"
    private var storedPersistedCellMasterKey: Data?
    private var storedSendDataAsText = false
    private var storedDebugValidateAccessForEverything = false
    private var storedWebSocketSecurityPolicy: CellBase.WebSocketSecurityPolicy = .developmentOnlyInsecureAllowed
    private var storedExploreContractEnforcementMode: CellBase.ExploreContractEnforcementMode = .permissive
    private var storedEnabledDiagnosticLogDomains = Set<CellBase.DiagnosticLogDomain>()
    private var storedDiagnosticLogHandler: ((CellBase.DiagnosticLogDomain, String) -> Void)?
    private var storedRemoteWebSocketQueryItemsProvider: (@Sendable (URL) -> [URLQueryItem])?

    var defaultIdentityVault: IdentityVaultProtocol? {
        get { withLock { storedDefaultIdentityVault } }
        set {
            let oldValue = withLock {
                let oldValue = storedDefaultIdentityVault
                storedDefaultIdentityVault = newValue
                return oldValue
            }
            _ = oldValue
        }
    }

    var defaultScopedSecretProvider: ScopedSecretProviderProtocol? {
        get { withLock { storedDefaultScopedSecretProvider } }
        set {
            let oldValue = withLock {
                let oldValue = storedDefaultScopedSecretProvider
                storedDefaultScopedSecretProvider = newValue
                return oldValue
            }
            _ = oldValue
        }
    }

    var defaultCellResolver: CellResolverProtocol? {
        get { withLock { storedDefaultCellResolver } }
        set {
            let oldValue = withLock {
                let oldValue = storedDefaultCellResolver
                storedDefaultCellResolver = newValue
                return oldValue
            }
            _ = oldValue
        }
    }

    var documentRootPath: String? {
        get { withLock { storedDocumentRootPath } }
        set {
            let oldValue = withLock {
                let oldValue = storedDocumentRootPath
                storedDocumentRootPath = newValue
                return oldValue
            }
            _ = oldValue
        }
    }

    var typedCellUtility: TypedCellProtocol? {
        get { withLock { storedTypedCellUtility } }
        set {
            let oldValue = withLock {
                let oldValue = storedTypedCellUtility
                storedTypedCellUtility = newValue
                return oldValue
            }
            _ = oldValue
        }
    }

    var hostname: String {
        get { withLock { storedHostname } }
        set {
            let oldValue = withLock {
                let oldValue = storedHostname
                storedHostname = newValue
                return oldValue
            }
            _ = oldValue
        }
    }

    var persistedCellMasterKey: Data? {
        get { withLock { storedPersistedCellMasterKey } }
        set {
            let oldValue = withLock {
                let oldValue = storedPersistedCellMasterKey
                storedPersistedCellMasterKey = newValue
                return oldValue
            }
            _ = oldValue
        }
    }

    var sendDataAsText: Bool {
        get { withLock { storedSendDataAsText } }
        set { withLock { storedSendDataAsText = newValue } }
    }

    var debugValidateAccessForEverything: Bool {
        get { withLock { storedDebugValidateAccessForEverything } }
        set { withLock { storedDebugValidateAccessForEverything = newValue } }
    }

    var webSocketSecurityPolicy: CellBase.WebSocketSecurityPolicy {
        get { withLock { storedWebSocketSecurityPolicy } }
        set { withLock { storedWebSocketSecurityPolicy = newValue } }
    }

    var exploreContractEnforcementMode: CellBase.ExploreContractEnforcementMode {
        get { withLock { storedExploreContractEnforcementMode } }
        set { withLock { storedExploreContractEnforcementMode = newValue } }
    }

    var enabledDiagnosticLogDomains: Set<CellBase.DiagnosticLogDomain> {
        get { withLock { storedEnabledDiagnosticLogDomains } }
        set {
            let oldValue = withLock {
                let oldValue = storedEnabledDiagnosticLogDomains
                storedEnabledDiagnosticLogDomains = newValue
                return oldValue
            }
            _ = oldValue
        }
    }

    var diagnosticLogHandler: ((CellBase.DiagnosticLogDomain, String) -> Void)? {
        get { withLock { storedDiagnosticLogHandler } }
        set {
            let oldValue = withLock {
                let oldValue = storedDiagnosticLogHandler
                storedDiagnosticLogHandler = newValue
                return oldValue
            }
            _ = oldValue
        }
    }

    var remoteWebSocketQueryItemsProvider: (@Sendable (URL) -> [URLQueryItem])? {
        get { withLock { storedRemoteWebSocketQueryItemsProvider } }
        set {
            let oldValue = withLock {
                let oldValue = storedRemoteWebSocketQueryItemsProvider
                storedRemoteWebSocketQueryItemsProvider = newValue
                return oldValue
            }
            _ = oldValue
        }
    }

    func diagnosticLoggingEnabled(for domain: CellBase.DiagnosticLogDomain) -> Bool {
        withLock { storedEnabledDiagnosticLogDomains.contains(domain) }
    }

    func diagnosticLog(_ message: @autoclosure () -> String, domain: CellBase.DiagnosticLogDomain) {
        let logTarget: (enabled: Bool, handler: ((CellBase.DiagnosticLogDomain, String) -> Void)?) = withLock {
            (
                enabled: storedEnabledDiagnosticLogDomains.contains(domain),
                handler: storedDiagnosticLogHandler
            )
        }

        guard logTarget.enabled else { return }

        let renderedMessage = message()
        if let handler = logTarget.handler {
            handler(domain, renderedMessage)
        } else {
            print("[CellBase][\(domain.rawValue)] \(renderedMessage)")
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
