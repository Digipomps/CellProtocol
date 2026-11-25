// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Avgrenset utvidelse av en entitet (purpose://candidate.egen-agent-mcp.connect-entity).
///
/// En lenke er enten *hel* (`same_entity`: den lenkede nøkkelen handler som entiteten)
/// eller *avgrenset* (`scoped`: den lenkede nøkkelen får bare det som står i lenken).
/// Avgrensningen ligger i `approvedScopes`, som allerede er signert i godkjenningen og
/// i `SameEntityIdentityLinkCredential`. Derfor trengs ingen nye felt i lenkeflyten.
///
/// Ordforråd (ett ord per oppføring):
/// - `scoped` — markør, påkrevd.
/// - `scope.grant:<permission>:<cellUUID>:<keypath>` — én eller flere. `permission` er en
///   CellBase-tillatelse på fire tegn (`r---`, `-w--`). Nøkkelstien matches eksakt.
/// - `scope.recipient:<mottaker>` — nøyaktig én: hvor svarene ender (`local`, `anthropic`, `openai`, ...).
/// - `scope.expires:<ISO 8601>` — nøyaktig én, påkrevd.
/// - `scope.device:<navn>` — valgfri, bare til visning.
///
/// En liste som har både `same_entity` og avgrensning, eller som ikke kan leses, gir
/// verken hel eller avgrenset tilgang.
public struct ScopedIdentityLinkPolicy: Equatable, Sendable {
    public struct ScopeGrant: Equatable, Sendable {
        public var permission: String
        public var cellUUID: String
        public var keypath: String
    }

    public var grants: [ScopeGrant]
    public var recipient: String
    public var expiresAt: Date
    public var deviceLabel: String?

    public static let marker = "scoped"
    public static let grantPrefix = "scope.grant:"
    public static let recipientPrefix = "scope.recipient:"
    public static let expiresPrefix = "scope.expires:"
    public static let devicePrefix = "scope.device:"

    /// Grenser som holder en avgrenset lenke liten og kortlivet. Over grensen: ingen tilgang.
    public static let maximumGrants = 64
    public static let maximumScopeLength = 512
    public static let maximumLifetime: TimeInterval = 90 * 24 * 60 * 60
    /// En agent leser eller skriver. Andre tillatelsesbiter (kjør, del) kan ikke gis i en lenke.
    public static let allowedPermissions: Set<String> = ["r---", "-w--", "rw--"]

    /// Sant når lista har noe som helst avgrensning i seg. Brukes for å hindre at
    /// en avgrenset lenke noen gang leses som hel.
    public static func mentionsScope(_ scopes: [String]) -> Bool {
        scopes.contains { $0 == marker || $0.hasPrefix("scope.") }
    }

    /// Leser en avgrenset lenke. `nil` betyr at lista ikke er en gyldig avgrenset lenke.
    public init?(approvedScopes scopes: [String]) {
        guard scopes.contains(Self.marker),
              !scopes.contains(IdentityLinkScope.sameEntity),
              !scopes.contains(IdentityLinkScope.legacyEntityAuth) else {
            return nil
        }
        var grants: [ScopeGrant] = []
        var recipients: [String] = []
        var expiries: [Date] = []
        var devices: [String] = []
        guard scopes.allSatisfy({ $0.count <= Self.maximumScopeLength }) else { return nil }
        for scope in scopes {
            if scope == Self.marker { continue }
            if scope.hasPrefix(Self.grantPrefix) {
                let parts = scope.dropFirst(Self.grantPrefix.count).split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { return nil }
                let permission = String(parts[0]), cellUUID = String(parts[1]), keypath = String(parts[2])
                guard Self.allowedPermissions.contains(permission),
                      !cellUUID.isEmpty,
                      !keypath.isEmpty else { return nil }
                grants.append(ScopeGrant(permission: permission, cellUUID: cellUUID, keypath: keypath))
            } else if scope.hasPrefix(Self.recipientPrefix) {
                let recipient = String(scope.dropFirst(Self.recipientPrefix.count))
                guard !recipient.isEmpty else { return nil }
                recipients.append(recipient)
            } else if scope.hasPrefix(Self.expiresPrefix) {
                guard let date = Self.parseDate(String(scope.dropFirst(Self.expiresPrefix.count))) else { return nil }
                expiries.append(date)
            } else if scope.hasPrefix(Self.devicePrefix) {
                devices.append(String(scope.dropFirst(Self.devicePrefix.count)))
            } else if scope.hasPrefix("scope.") {
                // Ukjent avgrensning: lukket, ikke ignorert.
                return nil
            }
        }
        guard !grants.isEmpty, grants.count <= Self.maximumGrants,
              recipients.count == 1, expiries.count == 1, devices.count <= 1 else {
            return nil
        }
        self.grants = grants
        self.recipient = recipients[0]
        self.expiresAt = expiries[0]
        self.deviceLabel = devices.first
    }

    /// Lager `approvedScopes` for en avgrenset lenke (brukes av den som ber om lenken).
    public static func scopes(
        grants: [ScopeGrant],
        recipient: String,
        expiresAt: Date,
        deviceLabel: String? = nil
    ) -> [String] {
        var result = [marker]
        result += grants.map { "\(grantPrefix)\($0.permission):\($0.cellUUID):\($0.keypath)" }
        result.append("\(recipientPrefix)\(recipient)")
        result.append("\(expiresPrefix)\(formatDate(expiresAt))")
        if let deviceLabel { result.append("\(devicePrefix)\(deviceLabel)") }
        return result
    }

    /// Den tillatelsen i lenken som dekker kallet, om noen.
    public func grant(covering requestedAccess: String, at keypath: String, inCell cellUUID: String) -> ScopeGrant? {
        let requested = Grant(keypath: keypath, permission: requestedAccess)
        return grants.first {
            $0.cellUUID == cellUUID && Grant(keypath: $0.keypath, permission: $0.permission).granted(requested)
        }
    }

    /// Lenken gjelder fra `linkedAt` til `expiresAt`, og aldri lenger enn `maximumLifetime`.
    public func isWithinLifetime(linkedAt: String, now: Date) -> Bool {
        guard let start = Self.parseDate(linkedAt) else { return false }
        return now < expiresAt && expiresAt.timeIntervalSince(start) <= Self.maximumLifetime
    }

    public func grantsAnything(inCell cellUUID: String) -> Bool {
        grants.contains { $0.cellUUID == cellUUID }
    }

    private static func parseDate(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
