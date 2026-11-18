// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors


import Crypto
import Foundation

public struct CellBase {
    private static let runtimeEnvironment = CellRuntimeEnvironment()

    public enum WebSocketSecurityPolicy {
        case developmentOnlyInsecureAllowed
        case requireTLS
        /// Plain `ws://` is allowed to this machine only (`127.0.0.1`, `::1`,
        /// `localhost`), in every build configuration. Every other host
        /// requires TLS. A host app that talks to a local agent opts in.
        case loopbackInsecureAllowed
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

    /// How ValueType Objects are written and how strictly present fields are read.
    public enum ObjectWireFormat: Sendable, Equatable {
        /// Default (main): JSON inference for Objects; malformed optional fields
        /// fall back to their legacy defaults. Byte-compatible with existing peers.
        case legacyInference
        /// Opt-in (loopback D252E/D256): Objects whose variants JSON inference
        /// would lose use the explicit `&objectEntries` form, and malformed
        /// present fields throw. Requires a coordinated peer rollout before use
        /// on a shared wire.
        case explicitEntries
    }

    public static var objectWireFormat: ObjectWireFormat {
        get { runtimeEnvironment.objectWireFormat }
        set { runtimeEnvironment.objectWireFormat = newValue }
    }
    static var usesExplicitObjectWire: Bool { objectWireFormat == .explicitEntries }

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

    public static var securityEventSink: CellSecurityEventSink? {
        get { runtimeEnvironment.securityEventSink }
        set { runtimeEnvironment.securityEventSink = newValue }
    }

    public static var signingChallengeReplayStore: CellSecuritySigningChallengeReplayStore? {
        get { runtimeEnvironment.signingChallengeReplayStore }
        set { runtimeEnvironment.signingChallengeReplayStore = newValue }
    }

    public static var securityContainmentPolicy: CellSecurityContainmentPolicy {
        get { runtimeEnvironment.securityContainmentPolicy }
        set { runtimeEnvironment.securityContainmentPolicy = newValue }
    }

    public static var securityContainmentController: CellSecurityContainmentController? {
        get { runtimeEnvironment.securityContainmentController }
        set { runtimeEnvironment.securityContainmentController = newValue }
    }

    /// Whether plain `ws://` is allowed to any host. `loopbackInsecureAllowed`
    /// answers false here; ask `allowsInsecureWebSocket(toHost:)` for a host.
    public static var allowsInsecureWebSockets: Bool {
        switch webSocketSecurityPolicy {
        case .requireTLS, .loopbackInsecureAllowed:
            return false
        case .developmentOnlyInsecureAllowed:
#if DEBUG
            return true
#else
            return false
#endif
        }
    }

    /// Whether the channel-authentication endpoint may name a loopback `ws://`
    /// audience. The endpoint itself still accepts only loopback hosts.
    static var allowsInsecureChannelLoopback: Bool {
        webSocketSecurityPolicy == .developmentOnlyInsecureAllowed || webSocketSecurityPolicy == .loopbackInsecureAllowed
    }

    /// Whether plain `ws://` is allowed to `host` under the current policy.
    public static func allowsInsecureWebSocket(toHost host: String?) -> Bool {
        switch webSocketSecurityPolicy {
        case .requireTLS:
            return false
        case .developmentOnlyInsecureAllowed:
            return allowsInsecureWebSockets
        case .loopbackInsecureAllowed:
            return isLoopbackHost(host)
        }
    }

    /// Exactly the names that cannot leave this machine. `.local` names and
    /// other `127/8` addresses are not accepted.
    public static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host else { return false }
        switch host.lowercased() {
        case "127.0.0.1", "::1", "[::1]", "localhost":
            return true
        default:
            return false
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

    public static func recordSecurityEvent(_ event: CellSecurityEvent) async {
        let sink = securityEventSink
        let controller = securityContainmentController
        let policy = securityContainmentPolicy
        await sink?.record(event)
        _ = await controller?.observe(event, policy: policy)
    }
    
    public init() {
    }
}
