// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CellSecurityProbeRunMode: String, Codable, Sendable {
    case local
    case stagingAllowlist
}

public enum CellSecurityProbeRunStatus: String, Codable, Sendable {
    case planned
    case refused
}

public struct CellSecurityProbeRunConfiguration: Codable, Equatable, Sendable {
    public var mode: CellSecurityProbeRunMode
    public var targetEndpoint: String?
    public var allowedStagingHosts: [String]
    public var emitPolicyProbeEvents: Bool

    public init(
        mode: CellSecurityProbeRunMode = .local,
        targetEndpoint: String? = nil,
        allowedStagingHosts: [String] = [],
        emitPolicyProbeEvents: Bool = false
    ) {
        self.mode = mode
        self.targetEndpoint = targetEndpoint
        self.allowedStagingHosts = allowedStagingHosts.map { $0.lowercased() }
        self.emitPolicyProbeEvents = emitPolicyProbeEvents
    }
}

public struct CellSecurityProbeRunResult: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var probeID: String
    public var probeName: String
    public var status: CellSecurityProbeRunStatus
    public var decision: String
    public var reasonCode: String
    public var expectedEventKind: CellSecurityEventKind
    public var expectedReasonCode: String
    public var expectedRequiredAction: String?
    public var remediation: String

    public init(
        id: String = UUID().uuidString,
        probeID: String,
        probeName: String,
        status: CellSecurityProbeRunStatus,
        decision: String,
        reasonCode: String,
        expectedEventKind: CellSecurityEventKind,
        expectedReasonCode: String,
        expectedRequiredAction: String?,
        remediation: String
    ) {
        self.id = id
        self.probeID = probeID
        self.probeName = probeName
        self.status = status
        self.decision = decision
        self.reasonCode = reasonCode
        self.expectedEventKind = expectedEventKind
        self.expectedReasonCode = expectedReasonCode
        self.expectedRequiredAction = expectedRequiredAction
        self.remediation = remediation
    }
}

public struct CellSecurityProbeRunReport: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var mode: CellSecurityProbeRunMode
    public var targetEndpoint: String?
    public var startedAt: Date
    public var finishedAt: Date
    public var results: [CellSecurityProbeRunResult]

    public init(
        id: String = UUID().uuidString,
        mode: CellSecurityProbeRunMode,
        targetEndpoint: String?,
        startedAt: Date,
        finishedAt: Date,
        results: [CellSecurityProbeRunResult]
    ) {
        self.id = id
        self.mode = mode
        self.targetEndpoint = targetEndpoint
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.results = results
    }

    public var plannedCount: Int {
        results.filter { $0.status == .planned }.count
    }

    public var refusedCount: Int {
        results.filter { $0.status == .refused }.count
    }
}

public enum CellSecurityProbeRunnerError: Error, Equatable {
    case stagingTargetRequired
    case stagingTargetNotAllowlisted(String)
    case invalidStagingTarget(String)
}

public struct CellSecurityProbeRunner: Sendable {
    public init() {}

    public func run(
        _ probes: [CellSecurityProbe] = CellSecurityProbeCatalog.baseline,
        configuration: CellSecurityProbeRunConfiguration = CellSecurityProbeRunConfiguration(),
        now: Date = Date()
    ) async -> CellSecurityProbeRunReport {
        let targetValidation = validateTarget(configuration)
        let results = probes.map { probe in
            result(for: probe, configuration: configuration, targetValidation: targetValidation)
        }

        if configuration.emitPolicyProbeEvents {
            for result in results where result.status == .planned {
                await CellBase.recordSecurityEvent(
                    CellSecurityEvent(
                        kind: .policyProbe,
                        severity: .info,
                        occurredAt: now,
                        resource: CellSecurityResource(
                            kind: "securityProbe",
                            identifier: result.probeID,
                            action: "simulate"
                        ),
                        reasonCode: result.expectedReasonCode,
                        userMessage: result.decision,
                        requiredAction: result.expectedRequiredAction,
                        canAutoResolve: false,
                        metadata: [
                            "expectedEventKind": result.expectedEventKind.rawValue,
                            "mode": configuration.mode.rawValue
                        ]
                    )
                )
            }
        }

        return CellSecurityProbeRunReport(
            mode: configuration.mode,
            targetEndpoint: configuration.targetEndpoint,
            startedAt: now,
            finishedAt: now,
            results: results
        )
    }

    private func result(
        for probe: CellSecurityProbe,
        configuration: CellSecurityProbeRunConfiguration,
        targetValidation: Result<String?, CellSecurityProbeRunnerError>
    ) -> CellSecurityProbeRunResult {
        if probe.performsNetworkIO {
            return refused(
                probe,
                decision: "Probe refused because CellSecurityKit probes must not perform network I/O.",
                reasonCode: "network_io_not_allowed"
            )
        }

        switch configuration.mode {
        case .local:
            guard probe.executionBoundary == .localOnly else {
                return refused(
                    probe,
                    decision: "Probe refused because it is not declared local-only.",
                    reasonCode: "probe_boundary_not_local"
                )
            }
        case .stagingAllowlist:
            switch targetValidation {
            case .success:
                break
            case .failure(let error):
                return refused(probe, decision: error.userMessage, reasonCode: error.reasonCode)
            }
        }

        return CellSecurityProbeRunResult(
            probeID: probe.id,
            probeName: probe.name,
            status: .planned,
            decision: "Probe is authorized for deterministic simulation only; expected denial is \(probe.expectation.expectedReasonCode).",
            reasonCode: "probe_planned",
            expectedEventKind: probe.expectation.expectedEventKind,
            expectedReasonCode: probe.expectation.expectedReasonCode,
            expectedRequiredAction: probe.expectation.expectedRequiredAction,
            remediation: probe.remediation
        )
    }

    private func refused(
        _ probe: CellSecurityProbe,
        decision: String,
        reasonCode: String
    ) -> CellSecurityProbeRunResult {
        CellSecurityProbeRunResult(
            probeID: probe.id,
            probeName: probe.name,
            status: .refused,
            decision: decision,
            reasonCode: reasonCode,
            expectedEventKind: probe.expectation.expectedEventKind,
            expectedReasonCode: probe.expectation.expectedReasonCode,
            expectedRequiredAction: probe.expectation.expectedRequiredAction,
            remediation: probe.remediation
        )
    }

    private func validateTarget(
        _ configuration: CellSecurityProbeRunConfiguration
    ) -> Result<String?, CellSecurityProbeRunnerError> {
        guard configuration.mode == .stagingAllowlist else {
            return .success(nil)
        }
        guard let targetEndpoint = configuration.targetEndpoint,
              targetEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .failure(.stagingTargetRequired)
        }
        guard let components = URLComponents(string: targetEndpoint),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "cell", "ws", "wss"].contains(scheme),
              let host = components.host?.lowercased(),
              host.isEmpty == false else {
            return .failure(.invalidStagingTarget(targetEndpoint))
        }
        guard configuration.allowedStagingHosts.contains(host) else {
            return .failure(.stagingTargetNotAllowlisted(host))
        }
        return .success(host)
    }
}

public extension CellSecurityProbeRunnerError {
    var reasonCode: String {
        switch self {
        case .stagingTargetRequired:
            return "staging_target_required"
        case .stagingTargetNotAllowlisted:
            return "staging_target_not_allowlisted"
        case .invalidStagingTarget:
            return "invalid_staging_target"
        }
    }

    var userMessage: String {
        switch self {
        case .stagingTargetRequired:
            return "Staging probe run requires an explicit target endpoint."
        case .stagingTargetNotAllowlisted(let host):
            return "Staging probe target host is not allowlisted: \(host)"
        case .invalidStagingTarget(let target):
            return "Staging probe target is invalid or unsupported: \(target)"
        }
    }
}
