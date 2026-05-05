// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct FlowProvenance: Codable, Hashable {
    public var originCell: String
    public var originIdentity: String
    public var originPayloadHash: String?
    public var originSignature: Data?

    public init(
        originCell: String,
        originIdentity: String,
        originPayloadHash: String? = nil,
        originSignature: Data? = nil
    ) {
        self.originCell = originCell
        self.originIdentity = originIdentity
        self.originPayloadHash = originPayloadHash
        self.originSignature = originSignature
    }
}

public struct FlowRevisionLink: Codable, Hashable {
    public var revision: Int
    public var previousRevisionHash: String?

    public init(revision: Int = 0, previousRevisionHash: String? = nil) {
        self.revision = revision
        self.previousRevisionHash = previousRevisionHash
    }
}
