// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum IdentityKeyRole: String, Codable, Sendable {
    case signing
    case keyAgreement
}

public protocol IdentityKeyRoleProviderProtocol: Sendable {
    func publicSecureKey(for identity: Identity, role: IdentityKeyRole) async throws -> SecureKey?
    func privateKeyData(for identity: Identity, role: IdentityKeyRole) async throws -> Data?
}

public extension IdentityKeyRoleProviderProtocol {
    func publicSecureKey(for identity: Identity, role: IdentityKeyRole) async throws -> SecureKey? {
        switch role {
        case .signing:
            return identity.publicSecureKey
        case .keyAgreement:
            return identity.publicKeyAgreementSecureKey
        }
    }

    func privateKeyData(for identity: Identity, role: IdentityKeyRole) async throws -> Data? {
        _ = identity
        _ = role
        return nil
    }

    func keyIdentifier(for identity: Identity, role: IdentityKeyRole, secureKey: SecureKey) -> String {
        "\(identity.uuid)#\(role.rawValue):\(secureKey.algorithm.rawValue):\(secureKey.curveType.rawValue)"
    }
}
