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
        let commandID: Int
        let scope: BridgeIdentityProofScope
    }

    private struct Lease {
        let scopes: Set<BridgeIdentityProofScope>
        let expiresAt: Date?
        let monotonicDeadline: TimeInterval?
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

    func begin(_ command: BridgeCommand, now: Date = Date(), monotonic: TimeInterval = ProcessInfo.processInfo.systemUptime) {
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
            purgeExpired(now: now, monotonic: monotonic)
            let scopes = pinnedScopes ?? Set(discoveredScope.map { [$0] } ?? [])
            guard !scopes.isEmpty else { return }
            leases[command.cid] = Lease(
                scopes: scopes,
                expiresAt: command.command == .feed ? nil : now.addingTimeInterval(5),
                monotonicDeadline: command.command == .feed ? nil : monotonic + 5
            )
        }
    }

    func permit(for challenge: IdentitySigningChallenge, identity: Identity, now: Date = Date(), monotonic: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Permit? {
        guard identity.referencesSameSigningIdentity(as: principal), let vault,
              challenge.action == "checkIdentityOrigin", challenge.audience == "GeneralCell" else { return nil }
        return lock.withLock {
            purgeExpired(now: now, monotonic: monotonic)
            let scope = BridgeIdentityProofScope(domain: challenge.domain, resource: challenge.resource)
            // Prefer the authority with the longest remaining lifetime. Dictionary
            // order must not bind a streaming proof to a transient operation.
            let lease = leases.filter { $0.value.scopes.contains(scope) }.sorted {
                switch ($0.value.monotonicDeadline, $1.value.monotonicDeadline) {
                case (nil, .some): return true
                case (.some, nil): return false
                case let (.some(lhs), .some(rhs)) where lhs != rhs: return lhs > rhs
                default: break
                }
                if let lhs = $0.value.expiresAt, let rhs = $1.value.expiresAt, lhs != rhs {
                    return lhs > rhs
                }
                return $0.key < $1.key
            }.first
            guard let lease else { return nil }
            return Permit(identity: principal, vault: vault, generation: generation, commandID: lease.key, scope: scope)
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

    func isCurrent(_ permit: Permit, now: Date = Date(), monotonic: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock {
            purgeExpired(now: now, monotonic: monotonic)
            return generation == permit.generation && leases[permit.commandID]?.scopes.contains(permit.scope) == true
        }
    }

    private func purgeExpired(now: Date, monotonic: TimeInterval) {
        leases = leases.filter {
            ($0.value.expiresAt.map { $0 > now } ?? true) &&
            ($0.value.monotonicDeadline.map { $0 > monotonic } ?? true)
        }
    }
}
