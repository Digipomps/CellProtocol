// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
@testable import CellBase

final class MockBridgeTransport: BridgeTransportProtocol {
    private var delegate: BridgeDelegateProtocol?
    private(set) var endpointURL: URL?
    private(set) var identity: Identity?
    private let vault: IdentityVaultProtocol
    private let sentDataLock = NSLock()

    private var _sentData: [Data] = []
    var sentData: [Data] {
        sentDataLock.withLock {
            _sentData
        }
    }

    init(vault: IdentityVaultProtocol = MockIdentityVault()) {
        self.vault = vault
    }

    static func new() -> BridgeTransportProtocol {
        return MockBridgeTransport()
    }

    func setDelegate(_ delegate: BridgeDelegateProtocol) {
        self.delegate = delegate
    }

    func setup(_ endpointURL: URL, identity: Identity) async throws {
        self.endpointURL = endpointURL
        self.identity = identity
    }

    func sendData(_ data: Data) async throws {
        sentDataLock.withLock {
            _sentData.append(data)
        }
    }

    func identityVault(for: Identity?) async -> IdentityVaultProtocol {
        return vault
    }
}
