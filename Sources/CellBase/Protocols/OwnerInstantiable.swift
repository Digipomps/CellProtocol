// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public protocol OwnerInstantiable: AnyObject {
    init(owner: Identity) async
}
