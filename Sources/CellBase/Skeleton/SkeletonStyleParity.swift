// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Gjoer parity-maaling mellom web- og SwiftUI-rendreren veldefinert.
///
/// `styleRole` og `styleClasses` er i dag ikke én kontrakt med to
/// implementasjoner. De er to private vokabularer som deler et feltnavn:
///
/// - `skeleton-runtime.js` gjoer rollen om til en CSS-klasse
///   (`element.classList.add("style-role-" + rolle)`) og har egen
///   spesialbehandling av `admin-page-heading`, `admin-section-heading` og
///   `admin-form-field`. Rollen har altsaa reell styling-autoritet i web.
/// - `SkeletonView.swift` styler ikke paa rolle i det hele tatt.
///   `applyStyleMetadata` skriver bare en `accessibilityIdentifier`. De eneste
///   unntakene er `markdown` og `chat-primary-action`.
///
/// Settene overlapper ikke. Et skjelett som bruker en rolle vil derfor se ulikt
/// ut i de to rendrerne uten at noen av dem tar feil - forskjellen er ikke en
/// bug, den er en udefinert del av kontrakten. Maaler man piksler uten aa ta
/// hensyn til det, maaler man stoey.
///
/// Denne typen fjerner den stoeyen paa JSON-nivaa, foer rendring. Ingen av
/// rendrerne trenger ny semantikk, og ingen ny styling-evne innfoeres.
public enum SkeletonStyleParity {

    /// Roller begge rendrerne gir samme visuelle betydning.
    ///
    /// Tom med vilje. Ingen rolle er i dag hedret av begge. Naar en rolle skal
    /// bli normativ, foeres den opp her *og* implementeres i begge rendrerne -
    /// det er en produktbeslutning, ikke en opprydding.
    public static let agreedRoles: Set<String> = []

    /// Roller bare web-rendreren tolker (`skeleton-runtime.js`).
    public static let webOnlyRoles: Set<String> = [
        "admin-page-heading",
        "admin-section-heading",
        "admin-form-field"
    ]

    /// Roller bare SwiftUI-rendreren tolker (`SkeletonView.swift`).
    public static let nativeOnlyRoles: Set<String> = [
        "markdown",
        "chat-primary-action"
    ]

    public enum TokenKind: String, Equatable, Sendable {
        /// Tolkes bare av web-rendreren.
        case webOnly
        /// Tolkes bare av SwiftUI-rendreren.
        case nativeOnly
        /// Ingen rendrer tolker den. Ren metadata i dag, men den *kan* treffe
        /// en CSS-regel paa `.style-role-<navn>` uten at noen har ment det.
        case unclaimed
    }

    /// Ett fjernet token, med sti saa funnet kan pekes paa i fiksturet.
    public struct Finding: Equatable, Sendable {
        public let path: String
        public let token: String
        public let kind: TokenKind

        public init(path: String, token: String, kind: TokenKind) {
            self.path = path
            self.token = token
            self.kind = kind
        }
    }

    public static func classify(_ token: String) -> TokenKind? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.isEmpty == false else { return nil }
        if agreedRoles.contains(normalized) { return nil }
        if webOnlyRoles.contains(normalized) { return .webOnly }
        if nativeOnlyRoles.contains(normalized) { return .nativeOnly }
        return .unclaimed
    }

    /// Fjerner alle style-tokens uten felles kontrakt fra et skjelett-JSON, og
    /// rapporterer hva som ble fjernet.
    ///
    /// Gaar over den generiske JSON-grafen i stedet for `SkeletonElement`-treet.
    /// Det er med vilje: enum-en har over tretti elementtyper, og en walker paa
    /// Swift-nivaa maatte utvides hver gang en ny kommer til. En ny elementtype
    /// med `modifiers` daekkes av denne uten endring.
    public static func normalizedForParity(
        jsonObject: Any
    ) -> (normalized: Any, findings: [Finding]) {
        var findings: [Finding] = []
        let normalized = strip(jsonObject, path: "$", findings: &findings)
        return (normalized, findings)
    }

    public static func normalizedForParity(
        jsonData: Data
    ) throws -> (normalized: Data, findings: [Finding]) {
        let object = try JSONSerialization.jsonObject(with: jsonData, options: [])
        let (normalizedObject, findings) = normalizedForParity(jsonObject: object)
        let data = try JSONSerialization.data(
            withJSONObject: normalizedObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        return (data, findings)
    }

    private static func strip(_ value: Any, path: String, findings: inout [Finding]) -> Any {
        if let array = value as? [Any] {
            return array.enumerated().map { index, entry in
                strip(entry, path: "\(path)[\(index)]", findings: &findings)
            }
        }
        guard let object = value as? [String: Any] else { return value }

        var result: [String: Any] = [:]
        for (key, entry) in object {
            let childPath = "\(path).\(key)"
            if key == "modifiers", let modifiers = entry as? [String: Any] {
                result[key] = stripModifiers(modifiers, path: childPath, findings: &findings)
            } else {
                result[key] = strip(entry, path: childPath, findings: &findings)
            }
        }
        return result
    }

    private static func stripModifiers(
        _ modifiers: [String: Any],
        path: String,
        findings: inout [Finding]
    ) -> [String: Any] {
        var result = modifiers

        if let role = modifiers["styleRole"] as? String, let kind = classify(role) {
            findings.append(Finding(path: "\(path).styleRole", token: role, kind: kind))
            result.removeValue(forKey: "styleRole")
        }

        if let classes = modifiers["styleClasses"] as? [Any] {
            var kept: [Any] = []
            for entry in classes {
                guard let token = entry as? String, let kind = classify(token) else {
                    kept.append(entry)
                    continue
                }
                findings.append(Finding(path: "\(path).styleClasses", token: token, kind: kind))
            }
            if kept.isEmpty {
                result.removeValue(forKey: "styleClasses")
            } else {
                result["styleClasses"] = kept
            }
        }

        // Nestede modifiers finnes ikke i dag, men et element kan ha barn under
        // andre noekler inne i samme objekt. De skal fortsatt gaas gjennom.
        for (key, entry) in result where key != "styleRole" && key != "styleClasses" {
            result[key] = strip(entry, path: "\(path).\(key)", findings: &findings)
        }
        return result
    }
}
