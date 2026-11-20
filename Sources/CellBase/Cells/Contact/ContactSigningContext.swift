// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Opt-in by a LOCAL vault implementation. There is deliberately no default
/// implementation forwarding to the ordinary or Bridge-connect signing method.
/// The source must repeat its own home/key checks after its final await and run
/// only the synchronous private-key call inside context.withSignature.
public protocol ContactLocalSigningVault: IdentityVaultProtocol, AnyObject {
    func signContactMessage(messageData: Data, originalIdentity: Identity,
        context: ContactSigningContext) async throws -> Data
}

/// CP-issued, process-local and single-use. Neither Codable nor a bearer grant.
/// It binds the exact bytes, original full-home key and original operation. The
/// synchronous closure is essential: consuming a flag before an awaited signer
/// would leave a retirement gap. It must not await, schedule work, or reenter the
/// lease. Lock order is operation lease, then this context, then private signer.
public final class ContactSigningContext: @unchecked Sendable {
    private let lease: ContactOperationLease
    private let source: ContactLocalSigningVault
    private let bytes: Data
    private let principal: BridgeChannelAuthentication.PublicIdentity
    private let home: String
    private let validateScope: () throws -> Void
    private let lock = NSLock()
    private var active = true
    private var consumed = false

    init(lease: ContactOperationLease, source: ContactLocalSigningVault, messageData: Data,
         validateScope: @escaping () throws -> Void = {}) {
        self.lease = lease; self.source = source; bytes = messageData
        principal = lease.snapshot.requester; home = lease.snapshot.homeVaultReference
        self.validateScope = validateScope
    }

    public func withSignature(from vault: any ContactLocalSigningVault, messageData: Data, originalIdentity: Identity,
        _ sign: () throws -> Data) throws -> Data {
        // Freeze and check the caller's descriptor before entering our locks.
        let actual = try BridgeChannelAuthentication.PublicIdentity(originalIdentity)
        let actualHome = originalIdentity.homeVaultReference
        return try lease.withCurrent {
            try lock.withLock {
                try Task.checkCancellation()
                guard ObjectIdentifier(vault) == ObjectIdentifier(source),
                      active, !consumed, actual == principal, actualHome == home,
                      messageData == bytes else { throw ContactOperationFailure.signingDenied }
                try validateScope()
                // A failed private-key call also consumes this one-shot context.
                consumed = true
                return try sign()
            }
        }
    }

    var didConsume: Bool { lock.withLock { consumed } }
    func invalidate() { lock.withLock { active = false } }
}

/// Narrow holder for an independently authenticated local application caller.
/// This type exposes no IdentityVaultProtocol adapter, arbitrary signing method,
/// raw key, or serializable capability. Resolver/channel integration is separate;
/// constructing a holder does not open a route or authorize a remote Cell.
public final class ContactOperationHolder: @unchecked Sendable {
    public let lease: ContactOperationLease
    private let source: ContactLocalSigningVault
    private let principal: BridgeChannelAuthentication.PublicIdentity
    private let home: String

    private init(lease: ContactOperationLease, source: ContactLocalSigningVault) {
        self.lease = lease; self.source = source
        principal = lease.snapshot.requester; home = lease.snapshot.homeVaultReference
    }

    public static func prepare(lease: ContactOperationLease, requester: Identity) async throws -> ContactOperationHolder {
        try Task.checkCancellation()
        // Capture the source once. No mutable caller Identity is retained through
        // the source's loading/signing awaits, and no default vault is consulted.
        guard !(requester.identityVault is BridgeIdentityVault),
              let source = requester.identityVault as? ContactLocalSigningVault,
              requester.homeVaultReference == lease.snapshot.homeVaultReference,
              try BridgeChannelAuthentication.PublicIdentity(requester) == lease.snapshot.requester else {
            throw ContactOperationFailure.unsupportedSigner
        }
        let holder = ContactOperationHolder(lease: lease, source: source)
        try lease.withCurrent {}
        guard await source.identityVaultReference() == holder.home else { throw ContactOperationFailure.unsupportedSigner }
        try lease.withCurrent {}
        guard await source.identityExistInVault(holder.localIdentity()) else { throw ContactOperationFailure.unsupportedSigner }
        try lease.withCurrent {}
        guard let nonce = randomData(count: 64) else { throw ContactOperationFailure.signingDenied }
        let local = holder.localIdentity()
        let bytes = try IdentitySigningChallenge.signingData(for: local, trustedIdentity: local,
            domain: "cellprotocol.contact-operation", resource: lease.snapshot.admission.operationID.uuidString,
            action: "bindLocalHolder", audience: "ContactOperationHolder", nonce: nonce)
        // The actual source implementation must use the final synchronous fence,
        // including when a link is retired during its own actor/vault load awaits.
        _ = try await holder.signExact(bytes)
        try lease.withCurrent {}
        return holder
    }

    private func localIdentity() -> Identity {
        let identity = principal.makeIdentity()
        identity.homeVaultReference = home
        identity.identityVault = source
        return identity
    }

    // Internal only. Future CP resolver/channel owners must supply an exact live
    // scope validator; this is not an application-facing signing facility.
    private func signExact(_ bytes: Data) async throws -> Data {
        let context = ContactSigningContext(lease: lease, source: source, messageData: bytes)
        defer { context.invalidate() }
        let signature = try await source.signContactMessage(messageData: bytes,
            originalIdentity: localIdentity(), context: context)
        try Task.checkCancellation()
        try lease.withCurrent {}
        guard context.didConsume,
              IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: bytes,
                                                         identity: principal.makeIdentity()) else {
            throw ContactOperationFailure.signingDenied
        }
        return signature
    }

    public func retire(_ reason: ContactRetirement) { lease.retire(reason) }
}
