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

    /// Roller web-rendreren gir en egen visuell behandling gjennom
    /// spesialkode i `skeleton-runtime.js`.
    ///
    /// Only roles without a stylesheet selector belong here. The admin roles
    /// now have CSS rules and are classified under webStylesheetRoles.
    public static let webJavaScriptRoles: Set<String> = []

    /// Roller web-rendreren styler gjennom en `.style-role-<navn>`-regel i
    /// stilarket.
    ///
    /// `applyElementModifiers` i `skeleton-runtime.js` legger paa klassen
    /// `style-role-<navn>` for *hver* rolle, betingelsesloest. En rolle er
    /// derfor stylet av web saa snart det finnes en regel som treffer den
    /// klassen - uten at noen har skrevet spesialkode for rollen.
    ///
    /// Lista er generert fra `CellScaffold/Public/css/*.css` og
    /// `CellScaffold/Public/js/skeleton-runtime.js`. Den er speilet i to repoer
    /// og driver derfor fra hverandre av seg selv. `SkeletonStyleParityCSSDriftTests`
    /// i CellScaffold skanner stilarkene og feiler med differansen.
    ///
    /// Generated 2026-09-17 against the integrated CellScaffold Public surface; 139 roles.
    /// 2026-09-19: + butler-chat-tabs, butler-workbench (Butler-temaet, Public/css/themes/Co-Pilot Chat.css); 141 roles.
    public static let webStylesheetRoles: Set<String> = [
        "admin-actions",
        "admin-banner-critical",
        "admin-banner-ok",
        "admin-banner-warn",
        "admin-button",
        "admin-button-danger",
        "admin-button-primary",
        "admin-button-quiet",
        "admin-canvas",
        "admin-crumb",
        "admin-crumb-current",
        "admin-crumb-sep",
        "admin-drawer",
        "admin-drawer-body",
        "admin-drawer-footer",
        "admin-drawer-header",
        "admin-drawer-title",
        "admin-empty",
        "admin-env",
        "admin-field",
        "admin-field-hint",
        "admin-field-label",
        "admin-form-field",
        "admin-labeled-value",
        "admin-main",
        "admin-note",
        "admin-page-header",
        "admin-page-heading",
        "admin-page-subtitle",
        "admin-page-titles",
        "admin-panel",
        "admin-panel-body",
        "admin-panel-head",
        "admin-panel-row",
        "admin-picker",
        "admin-rail",
        "admin-rail-brand",
        "admin-rail-kind",
        "admin-rail-mark",
        "admin-rail-nav",
        "admin-rail-nav-current",
        "admin-rail-section",
        "admin-section-heading",
        "admin-shell",
        "admin-stat",
        "admin-stat-label",
        "admin-stat-value",
        "admin-status-critical",
        "admin-status-ok",
        "admin-status-unknown",
        "admin-status-warn",
        "admin-table",
        "admin-table-empty",
        "admin-table-frame",
        "admin-table-head",
        "admin-table-row",
        "admin-table-row-note",
        "admin-table-scroll",
        "admin-tabs",
        "admin-tabs-current",
        "admin-td",
        "admin-td-actions",
        "admin-td-mono",
        "admin-td-primary",
        "admin-td-secondary",
        "admin-td-stack",
        "admin-td-status",
        "admin-th",
        "admin-timestamp",
        "admin-toggle",
        "admin-topbar",
        "admin-value",
        "admin-value-label",
        "admin-value-mono",
        "arendalsuka-optional-list",
        "assistant-response-actions",
        "butler-chat-tabs",
        "butler-helper-tree-chat",
        "butler-helper-tree-layout",
        "butler-helper-tree-rail",
        "butler-workbench",
        "chat-active-tool-chip",
        "chat-active-tool-chips",
        "chat-ask-this-time",
        "chat-clarification-card",
        "chat-composer",
        "chat-composer-dock",
        "chat-conversation",
        "chat-escalation-meter",
        "chat-escalation-pause",
        "chat-help-line",
        "chat-help-line-text",
        "chat-helper-tabs",
        "chat-helper-tabs-compact",
        "chat-lane-chip",
        "chat-message-list",
        "chat-prompt-log",
        "chat-prompt-scroll",
        "chat-starter-card",
        "chat-starter-row",
        "chat-workbench-layout",
        "component-panel",
        "component-panel-scroll",
        "component-surface",
        "minimized-helper-pill",
        "personal-page-publisher",
        "pinned-component-card",
        "pinned-component-dock",
        "publisher-actions",
        "publisher-card",
        "publisher-card-copy",
        "publisher-card-title",
        "publisher-hero",
        "publisher-hero-eyebrow",
        "publisher-hero-meta",
        "publisher-hero-status",
        "publisher-hero-storage",
        "publisher-media-kind",
        "publisher-media-list",
        "publisher-media-meta",
        "publisher-media-upload",
        "publisher-page-list",
        "publisher-preview-card",
        "publisher-preview-copy",
        "publisher-preview-title",
        "publisher-readiness",
        "publisher-status-chip",
        "publisher-storage-number",
        "publisher-template-list",
        "rendered-html",
        "resource-match-badge",
        "resource-match-card",
        "resource-match-footer",
        "resource-match-hint",
        "resource-match-kind",
        "resource-match-list",
        "resource-match-meta",
        "resource-match-summary",
        "resource-match-title",
        "secondary-text",
        "suggestion-card"
    ]

    /// Roller bare web-rendreren tolker - uansett om det skjer i JavaScript
    /// eller i stilarket.
    ///
    /// Var tidligere bare de tre JS-spesialbehandlede. Det gjorde at
    /// `chat-active-tool-chip`, `chat-active-tool-chips`, `chat-helper-tabs`,
    /// `chat-helper-tabs-compact` og `chat-prompt-log` - alle fem i bruk i
    /// appens egne flater, alle fem stylet av web og ingen av dem av SwiftUI -
    /// ble klassifisert `unclaimed`, altsaa "ingen rendrer tolker den".
    /// Funnstroemmen sa dermed at forskjellen ikke fantes. Retter 2026-09-07.
    public static let webOnlyRoles: Set<String> =
        webJavaScriptRoles.union(webStylesheetRoles)

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
        /// Ingen rendrer tolker den. Ren metadata: verken SwiftUI-rendreren
        /// eller noen `.style-role-<navn>`-regel i web-stilarket treffer den.
        /// At det faktisk stemmer haandheves av `webStylesheetRoles` og
        /// drift-testen som holder den mot stilarkene.
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
