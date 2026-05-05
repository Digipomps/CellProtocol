// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

protocol Grantable {
    func granted(_ grant: Grant) -> Bool
    mutating func addGrant(_ grant: Grant)
    mutating func removeGrant(_ grant: Grant)
    // Consider function for returning a grants publisher ... and identity
}
