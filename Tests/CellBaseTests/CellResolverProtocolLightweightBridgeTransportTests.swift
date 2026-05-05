// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class CellResolverProtocolLightweightBridgeTransportTests: XCTestCase {
    func testRegisterDefaultWebSocketBridgeTransportsRegistersLightweightTransportForWSAndWSS() async throws {
        let resolver = MockCellResolver()

        try await resolver.registerDefaultWebSocketBridgeTransports()

        XCTAssertTrue(resolver.registeredTransportType(for: "ws") == LightweightBridgeTransport.self)
        XCTAssertTrue(resolver.registeredTransportType(for: "wss") == LightweightBridgeTransport.self)
    }
}
