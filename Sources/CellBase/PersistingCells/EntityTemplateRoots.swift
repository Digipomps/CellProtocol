// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Roots that an entity template opens in EntityAnchor.
///
/// EntityData is dynamic (Kjetil 2026-11-17): system keypaths are fixed, and anything
/// below an open root can be written without being registered first. Until 2026-11-21
/// the anchors only opened `person`, `proofs`, `relations` and `identityLinks`; any
/// other root answered `notFound`. A template opens its roots here, so an entity that
/// is a conference or an organizer can hold its own data.
///
/// Source: CellProtocolDocuments `Book/conference_entity_template_v0.json`
/// (Kjetil chose «Malen åpner røtter i EntityAnchor» 2026-11-21).
public enum EntityTemplateRoots {
    public struct Template: Equatable, Sendable {
        public let ref: String
        public let version: String
        public let roots: [String]
    }

    /// Conference template v0. `conference` is the participant's own slice,
    /// keyed per conference entity; the others belong to the conference or
    /// organizer entity itself.
    public static let conferenceV0 = Template(
        ref: "8d3e2a61-6b1f-4c1e-9f5e-2c0b7a4d0001",
        version: "0.1.0",
        roots: [
            "event", "project", "template", "conference", "groups",
            "surfaces", "flows", "messaging", "assistance", "matching", "incentives",
        ]
    )

    public static let templates: [Template] = [conferenceV0]

    /// Every root an anchor opens on behalf of a template, without duplicates,
    /// in a stable order.
    public static var openedRoots: [String] {
        var seen = Set<String>()
        return templates.flatMap(\.roots).filter { seen.insert($0).inserted }
    }

    /// Roots the anchors already handle themselves. A template must not reopen them.
    public static let anchorOwnedRoots: Set<String> = [
        "person", "purposes", "relations", "proofs", "agreements", "signedAgreementEntity",
        "entityRepresentation", "dataInventory", "chronicle", "trace", "identityLinks",
        "entityAuthority", "entityContactSchema", "entityRelationSchema", "reloadStorage",
        "bindings", "scaffoldPresence",
    ]
}
