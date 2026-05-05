// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import HavenCoreSchemas

public struct PermissionEvaluator: Sendable {
    public init() {}

    public func evaluate(permissionClass: PermissionClass, context: RequesterContext, path: String) -> PermissionDecision {
        let normalizedPath = JSONPointer.normalize(path)

        if context.role == .sponsor {
            if permissionClass == .aggregated {
                return PermissionDecision(
                    isAllowed: true,
                    permissionClass: permissionClass,
                    reason: "Sponsor role can access aggregated keypaths."
                )
            }

            return PermissionDecision(
                isAllowed: false,
                permissionClass: permissionClass,
                reason: "Sponsor role is limited to aggregated keypaths."
            )
        }

        switch permissionClass {
        case .public:
            return PermissionDecision(
                isAllowed: true,
                permissionClass: permissionClass,
                reason: "Path is public."
            )

        case .private:
            let allowed = context.role == .owner || context.role == .member || context.role == .service
            return PermissionDecision(
                isAllowed: allowed,
                permissionClass: permissionClass,
                reason: allowed ? "Role allows private access." : "Role does not allow private access."
            )

        case .consent:
            if context.role == .owner || context.role == .service {
                return PermissionDecision(
                    isAllowed: true,
                    permissionClass: permissionClass,
                    reason: "Role bypasses consent requirement."
                )
            }

            let consentMatches = hasConsent(for: normalizedPath, tokens: context.consentTokens)
            return PermissionDecision(
                isAllowed: consentMatches,
                permissionClass: permissionClass,
                reason: consentMatches ? "Consent token matched keypath." : "Consent token is required for this keypath."
            )

        case .aggregated:
            let allowed = context.role != .unknown
            return PermissionDecision(
                isAllowed: allowed,
                permissionClass: permissionClass,
                reason: allowed ? "Aggregated data is available to authenticated roles." : "Unknown role cannot access aggregated data."
            )
        }
    }

    private func hasConsent(for path: String, tokens: [String]) -> Bool {
        let normalizedTokens = tokens.map(JSONPointer.normalize)

        if normalizedTokens.contains("#/*") || normalizedTokens.contains("#/full") {
            return true
        }

        for token in normalizedTokens {
            if token == path {
                return true
            }

            if token.hasSuffix("/*") {
                let prefix = String(token.dropLast(2))
                if path == prefix || path.hasPrefix(prefix + "/") {
                    return true
                }
            }
        }

        return false
    }
}
