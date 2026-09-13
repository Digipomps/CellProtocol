// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// A Cell whose identity-origin challenges a locally initiated bridge operation
/// may answer. Hosts can pin scopes before discovery, including known child Cells.
public struct BridgeIdentityProofScope: Hashable, Sendable {
    public let domain: String
    public let resource: String

    public init(domain: String, resource: String) {
        self.domain = domain
        self.resource = resource
    }
}

/// Process-local authority. No field from an incoming command can create a lease.
final class BridgeIdentityProofAuthorization {
    struct Permit {
        let identity: Identity
        let vault: IdentityVaultProtocol
        let generation: UInt64
        let scope: BridgeIdentityProofScope
    }

    private struct Lease {
        let scopes: Set<BridgeIdentityProofScope>
        let expiresAt: Date?
    }

    private let lock = NSLock()
    private let principal: Identity
    private let vault: IdentityVaultProtocol?
    private let pinnedScopes: Set<BridgeIdentityProofScope>?
    private var discoveredScope: BridgeIdentityProofScope?
    private var leases: [Int: Lease] = [:]
    private var generation: UInt64 = 0

    init(owner: Identity, scopes: [BridgeIdentityProofScope]? = nil) {
        principal = owner.publicIdentitySnapshot()
        vault = owner.identityVault is BridgeIdentityVault ? nil : owner.identityVault
        pinnedScopes = scopes.map(Set.init)
    }

    func discovered(domain: String, resource: String) {
        lock.withLock { discoveredScope = BridgeIdentityProofScope(domain: domain, resource: resource) }
    }

    func begin(_ command: BridgeCommand, now: Date = Date()) {
        guard let identity = command.identity,
              identity.referencesSameSigningIdentity(as: principal),
              identity.identityVault != nil,
              !(identity.identityVault is BridgeIdentityVault),
              vault != nil else { return }
        switch command.command {
        case .description, .admit, .agreement, .feed, .get, .set, .connectEmitter,
             .absorbFlow, .removeConnecion, .dropFlow, .disconnectAll, .unsubscribeAll:
            break
        default:
            return
        }
        lock.withLock {
            purgeExpired(now: now)
            let scopes = pinnedScopes ?? Set(discoveredScope.map { [$0] } ?? [])
            guard !scopes.isEmpty else { return }
            leases[command.cid] = Lease(
                scopes: scopes,
                expiresAt: command.command == .feed ? nil : now.addingTimeInterval(5)
            )
        }
    }

    func permit(for challenge: IdentitySigningChallenge, identity: Identity, now: Date = Date()) -> Permit? {
        guard identity.referencesSameSigningIdentity(as: principal), let vault,
              challenge.action == "checkIdentityOrigin", challenge.audience == "GeneralCell" else { return nil }
        return lock.withLock {
            purgeExpired(now: now)
            let scope = BridgeIdentityProofScope(domain: challenge.domain, resource: challenge.resource)
            guard leases.values.contains(where: { $0.scopes.contains(scope) }) else { return nil }
            return Permit(identity: principal, vault: vault, generation: generation, scope: scope)
        }
    }

    func complete(_ commandID: Int) { lock.withLock { _ = leases.removeValue(forKey: commandID) } }

    func reset() {
        lock.withLock {
            generation &+= 1
            leases.removeAll()
            discoveredScope = nil
        }
    }

    func isCurrent(_ permit: Permit, now: Date = Date()) -> Bool {
        lock.withLock {
            purgeExpired(now: now)
            return generation == permit.generation && leases.values.contains { $0.scopes.contains(permit.scope) }
        }
    }

    private func purgeExpired(now: Date) {
        leases = leases.filter { $0.value.expiresAt.map { $0 > now } ?? true }
    }
}
