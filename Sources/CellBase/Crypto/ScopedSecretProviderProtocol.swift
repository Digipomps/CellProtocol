// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum ScopedSecretProviderError: Error {
    case unavailable
    case invalidStoredSecret
}

public protocol ScopedSecretProviderProtocol: Sendable {
    func scopedSecretData(tag: String, minimumLength: Int) async throws -> Data
}

public extension ScopedSecretProviderProtocol {
    func scopedSecretData(tag: String) async throws -> Data {
        try await scopedSecretData(tag: tag, minimumLength: 32)
    }
}
