// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public protocol Condition: Codable /*, Equatable */ {
    var uuid: String { get }
    var name: String { get set }
    func isMet(context: ConnectContext) async -> ConditionState
    func resolve(context: ConnectContext) async
}


