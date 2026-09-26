// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
@testable import CellBase

/// One entity for a test: its own vault, its own keys, its own identities.
///
/// `MockIdentityVault` and `EphemeralIdentityVault` both mint deterministic
/// UUIDs (`…000001`, `…000002`), so two vaults collide on UUID. The key
/// fingerprints still differ, which is what authorization compares — but a
/// test about *two entities* should not have to explain that away. Every
/// identity here gets a random UUID, and every entity gets its own vault.
///
/// This is the in-process forerunner of the swarm scaffold
/// (PDD_invitasjon-tillit §0.1c): good enough to prove that a boundary holds,
/// not a stand-in for two real HAVENs.
struct SimulatedEntity {
    let name: String
    let vault: EphemeralIdentityVault
    let owner: Identity

    static func make(_ name: String, domain: String = "private") async -> SimulatedEntity {
        let vault = EphemeralIdentityVault()
        var owner = Identity(UUID().uuidString, displayName: "\(name)-\(domain)", identityVault: nil)
        await vault.addIdentity(identity: &owner, for: domain)
        return SimulatedEntity(name: name, vault: vault, owner: owner)
    }

    /// A further identity of the same entity (another device, another domain).
    func identity(_ context: String) async -> Identity {
        var identity = Identity(UUID().uuidString, displayName: "\(name)-\(context)", identityVault: nil)
        await vault.addIdentity(identity: &identity, for: context)
        return identity
    }

    /// Same UUID and public key as `identity`, but no vault: it cannot answer
    /// a challenge. The shape of an impostor who copied a descriptor.
    static func keylessClaimant(of identity: Identity) -> Identity {
        let claimant = Identity(identity.uuid, displayName: "claimant", identityVault: nil)
        claimant.publicSecureKey = identity.publicSecureKey
        return claimant
    }
}
