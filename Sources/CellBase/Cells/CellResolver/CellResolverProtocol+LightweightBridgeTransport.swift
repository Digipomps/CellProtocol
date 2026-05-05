// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public extension CellResolverProtocol {
    public func registerDefaultWebSocketBridgeTransports() async throws {
        try await registerTransport(LightweightBridgeTransport.self, for: "ws")
        try await registerTransport(LightweightBridgeTransport.self, for: "wss")
    }
}
