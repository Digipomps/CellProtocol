// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Hvem innholdet i cellen kan ende hos når en avgrenset lenke (en agent) leser det
/// (purpose://candidate.egen-agent-mcp.provider-recipient).
///
/// Vilkåret er en erklæring i cellens Agreement, som `LifecycleAlertAccessCondition`.
/// Det gir ingen tilgang alene. En avgrenset lenke slipper bare inn når cellens
/// Agreement har dette vilkåret og lenkens mottaker står i `allowedRecipients`.
/// Mangler vilkåret, er cellen stengt for avgrensede lenker.
public struct RecipientCondition: Codable, Condition {
    public var uuid: String
    public var name: String
    /// For eksempel `local`, `anthropic`, `openai`. Sortert og uten duplikater.
    public var allowedRecipients: [String]

    public init(allowedRecipients: [String], name: String = "Allowed recipients") {
        self.uuid = UUID().uuidString
        self.name = name
        self.allowedRecipients = Array(Set(allowedRecipients.filter { !$0.isEmpty })).sorted()
    }

    public func allows(_ recipient: String) -> Bool {
        allowedRecipients.contains(recipient)
    }

    public func isMet(context: ConnectContext) async -> ConditionState {
        .met
    }

    public func resolve(context: ConnectContext) async {}
}
