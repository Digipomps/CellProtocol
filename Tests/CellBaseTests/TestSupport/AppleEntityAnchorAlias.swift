// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

@testable import CellApple

/// `CellApple` is both a module and a type, so `CellApple.EntityAnchorCell`
/// does not resolve from a file that also imports CellVapor. This file
/// imports one module only and hands the type on under an unambiguous name.
typealias AppleEntityAnchorCell = EntityAnchorCell
