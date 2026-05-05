// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct FeedProperties: Codable {
    var endpoint: URL?
    var type: FeedType
    var mimetype: String?
}
