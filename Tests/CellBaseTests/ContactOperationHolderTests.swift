// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import Crypto
@testable import CellBase

final class ContactOperationHolderTests: XCTestCase {
    private actor Barrier {
        nonisolated let entered = XCTestExpectation(description: "source vault entered signing await")
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        func hold() async {
            entered.fulfill()
            if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
        }
        func release() {
            released = true
            let waiters = releaseWaiters; releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    /// An actual in-memory signing key and a real final fence. The barrier is
    /// inside the source vault's async work, not outside the holder call.
    private actor LocalVault: ContactLocalSigningVault {
        private let key = Curve25519.Signing.PrivateKey()
        private let uuid = UUID().uuidString
        private let home = "contact-test:" + UUID().uuidString
        private var barrier: Barrier?
        private var count = 0
        private var omitContext = false
        private var failSigning = false

        func identity() -> Identity {
            let result = Identity(uuid, displayName: "Synthetic contact subject", identityVault: self)
            result.homeVaultReference = home
            result.publicSecureKey = SecureKey(date: Date(timeIntervalSince1970: 0), privateKey: false,
                use: .signature, algorithm: .EdDSA, size: 256, curveType: .Curve25519,
                x: nil, y: nil, compressedKey: key.publicKey.rawRepresentation)
            return result
        }
        func configure(barrier: Barrier? = nil, omitContext: Bool = false, failSigning: Bool = false) {
            self.barrier = barrier; self.omitContext = omitContext; self.failSigning = failSigning
        }
        func signingCount() -> Int { count }
        func identityVaultReference() async -> String? { home }
        func initialize() async -> IdentityVaultProtocol { self }
        func addIdentity(identity: inout Identity, for identityContext: String) async {}
        func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? { nil }
        func identity(forUUID uuid: String) async -> Identity? { uuid == self.uuid ? identity() : nil }
        func identityExistInVault(_ identity: Identity) async -> Bool {
            identity.homeVaultReference == home && identity.referencesSameSigningIdentity(as: self.identity())
        }
        func saveIdentity(_ identity: Identity) async {}
        func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
            // The holder MUST NOT fall back to this ordinary entry point.
            throw IdentityVaultError.signingFailed
        }
        func signContactMessage(messageData: Data, originalIdentity: Identity,
            context: ContactSigningContext) async throws -> Data {
            await barrier?.hold()
            let identity = originalIdentity
            guard identity.homeVaultReference == home,
                  identity.referencesSameSigningIdentity(as: self.identity()) else { throw IdentityVaultError.wrongVault }
            if omitContext { return try key.signature(for: messageData) }
            return try context.withSignature(from: self, messageData: messageData, originalIdentity: identity) {
                count += 1
                if failSigning { throw IdentityVaultError.signingFailed }
                return try key.signature(for: messageData)
            }
        }
        func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
            IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: messageData, identity: identity)
        }
        func randomBytes64() async -> Data? { randomData(count: 64) }
        func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) { throw IdentityVaultError.signingFailed }
    }

    private struct Fixture {
        let vault: LocalVault
        let subject: Identity
        let binding: VerifiedContactBinding
        let admission: ContactApplicationAdmission
        let request: ValueType
        let lease: ContactOperationLease
    }

    private func fixture() async throws -> Fixture {
        let vault = LocalVault(), subject = await vault.identity()
        let ownerVault = EphemeralIdentityVault()
        var owner = Identity(UUID().uuidString, displayName: "Synthetic owner", identityVault: ownerVault)
        await ownerVault.addIdentity(identity: &owner, for: "private")
        let cellUUID = UUID().uuidString
        let agreement = Agreement(owner: owner)
        agreement.state = .signed; agreement.conditions = []
        agreement.grants = [Grant(keypath: "contact.request", permission: "-w--")]
        agreement.signatories = [owner, subject]; agreement.duration = 600
        let now = Date(), issued = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) - 1)
        let contract = try await Contract.signed(agreement: agreement, issuer: owner, subject: subject,
            domain: ContactInboxCell.domain, issuedAt: issued, targetCellUUID: cellUUID)
        let contractBytes = try ContactReferenceCodec.encode(contract)
        let endpoint = try XCTUnwrap(URL(string: "cell://contact.example:443/Contact-" + cellUUID))
        let referenceBytes = try await ContactReferenceCodec.issue(contractBytes: contractBytes, endpoint: endpoint,
            owner: owner, issuedAt: issued, expiresAt: issued.addingTimeInterval(300))
        let binding = try await ContactReferenceCodec.verify(referenceBytes: referenceBytes, contractBytes: contractBytes,
            expectedOwner: .init(owner), expectedSubject: .init(subject), approvedEndpoint: endpoint, now: now)
        let admission = ContactApplicationAdmission(attemptID: UUID(), bindingRecordID: "synthetic-binding",
            bindingGeneration: 1, authenticationReference: "synthetic-current-session", authenticationRevision: 2,
            personLinkRevision: 3, intentRevision: 4, routePolicyRevision: 5, expiresAt: issued.addingTimeInterval(200))
        let request = ValueType.object([
            "requestID": .string("synthetic-request"), "expiresAt": .float(issued.addingTimeInterval(200).timeIntervalSince1970),
            "payload": .object(["kind": .string("synthetic")]),
            "agreement": try JSONDecoder().decode(ValueType.self, from: contractBytes),
            "targetBinding": try JSONDecoder().decode(ValueType.self, from: referenceBytes)
        ])
        let lease = try ContactOperationLease(binding: binding, requester: subject, admission: admission, request: request)
        return Fixture(vault: vault, subject: subject, binding: binding, admission: admission, request: request, lease: lease)
    }

    func testLocalHolderUsesExplicitFinalSignerAndPreservesOriginalHome() async throws {
        let f = try await fixture()
        let holder = try await ContactOperationHolder.prepare(lease: f.lease, requester: f.subject)
        XCTAssertTrue(holder.lease === f.lease)
        XCTAssertEqual(holder.lease.snapshot.homeVaultReference, f.subject.homeVaultReference)
        let count = await f.vault.signingCount()
        XCTAssertEqual(count, 1)
        XCTAssertFalse(f.lease.applicationDispatchWasAdmitted)
    }

    func testRetirementInsideVaultAwaitPreventsPrivateSigningAndSiblingStillSucceeds() async throws {
        let f = try await fixture(), barrier = Barrier()
        await f.vault.configure(barrier: barrier)
        let task = Task { try await ContactOperationHolder.prepare(lease: f.lease, requester: f.subject) }
        await fulfillment(of: [barrier.entered], timeout: 5)
        f.lease.retire(.linkChanged)
        await barrier.release()
        do { _ = try await task.value; XCTFail("Retired operation returned a holder") } catch {}
        let count = await f.vault.signingCount()
        XCTAssertEqual(count, 0)
        await f.vault.configure()
        let sibling = try ContactOperationLease(binding: f.binding, requester: f.subject, admission: f.admission, request: f.request)
        _ = try await ContactOperationHolder.prepare(lease: sibling, requester: f.subject)
        let afterSibling = await f.vault.signingCount()
        XCTAssertEqual(afterSibling, 1)
    }

    func testCancellationInsideVaultAwaitPreventsPrivateSigning() async throws {
        let f = try await fixture(), barrier = Barrier()
        await f.vault.configure(barrier: barrier)
        let task = Task { try await ContactOperationHolder.prepare(lease: f.lease, requester: f.subject) }
        await fulfillment(of: [barrier.entered], timeout: 5)
        task.cancel(); await barrier.release()
        do { _ = try await task.value; XCTFail("Cancelled holder returned") } catch {}
        let count = await f.vault.signingCount()
        XCTAssertEqual(count, 0)
    }

    func testCallerMutationCannotReplaceCapturedPrincipalDuringVaultAwait() async throws {
        let f = try await fixture(), barrier = Barrier()
        await f.vault.configure(barrier: barrier)
        let task = Task { try await ContactOperationHolder.prepare(lease: f.lease, requester: f.subject) }
        await fulfillment(of: [barrier.entered], timeout: 5)
        // No code reads the caller Identity after source sign entry.
        f.subject.homeVaultReference = "unrelated-home"
        f.subject.identityVault = nil
        f.subject.publicSecureKey = nil
        await barrier.release()
        let holder = try await task.value
        XCTAssertEqual(holder.lease.snapshot.requester, f.binding.reference.subject)
        XCTAssertNotEqual(holder.lease.snapshot.homeVaultReference, f.subject.homeVaultReference)
        let count = await f.vault.signingCount(); XCTAssertEqual(count, 1)
    }

    func testNilHomeSnapshotCannotMintHolder() async throws {
        let f = try await fixture(), snapshot = f.subject.publicIdentitySnapshot()
        snapshot.identityVault = f.vault
        do { _ = try await ContactOperationHolder.prepare(lease: f.lease, requester: snapshot); XCTFail("nil home admitted") } catch {}
        let count = await f.vault.signingCount(); XCTAssertEqual(count, 0)
    }

    func testSameUUIDWithAnotherKeyCannotMintHolder() async throws {
        let f = try await fixture(), other = LocalVault()
        let wrong = await other.identity()
        f.subject.publicSecureKey = wrong.publicSecureKey
        do { _ = try await ContactOperationHolder.prepare(lease: f.lease, requester: f.subject); XCTFail("wrong key admitted") } catch {}
        let count = await f.vault.signingCount(); XCTAssertEqual(count, 0)
    }

    func testLegacyVaultIsNotAnImplicitContactSigner() async throws {
        let f = try await fixture()
        f.subject.identityVault = EphemeralIdentityVault()
        do { _ = try await ContactOperationHolder.prepare(lease: f.lease, requester: f.subject); XCTFail("legacy fallback") } catch {}
        let count = await f.vault.signingCount(); XCTAssertEqual(count, 0)
    }

    func testValidSignatureWithoutContextConsumptionIsRejected() async throws {
        let f = try await fixture()
        await f.vault.configure(omitContext: true)
        do { _ = try await ContactOperationHolder.prepare(lease: f.lease, requester: f.subject); XCTFail("unguarded signer accepted") } catch {}
    }

    func testFinalContextRejectsChangedBytesHomeAndKeyBeforeEffect() async throws {
        let f = try await fixture(), bytes = Data("exact synthetic bytes".utf8)
        let context = ContactSigningContext(lease: f.lease, source: f.vault, messageData: bytes)
        var calls = 0
        let sign = { calls += 1; return Data([1]) }
        XCTAssertThrowsError(try context.withSignature(from: f.vault, messageData: Data([2]), originalIdentity: f.subject, sign))
        let noHome = f.subject.publicIdentitySnapshot()
        XCTAssertThrowsError(try context.withSignature(from: f.vault, messageData: bytes, originalIdentity: noHome, sign))
        let other = await LocalVault().identity()
        XCTAssertThrowsError(try context.withSignature(from: f.vault, messageData: bytes, originalIdentity: other, sign))
        XCTAssertEqual(calls, 0)
        _ = try context.withSignature(from: f.vault, messageData: bytes, originalIdentity: f.subject, sign)
        XCTAssertEqual(calls, 1)
        XCTAssertThrowsError(try context.withSignature(from: f.vault, messageData: bytes, originalIdentity: f.subject, sign))
        XCTAssertEqual(calls, 1)
    }

    func testFailedSigningConsumesContextAndRetirementDoesNotUndoPriorEffect() async throws {
        let f = try await fixture(), bytes = Data([1])
        let context = ContactSigningContext(lease: f.lease, source: f.vault, messageData: bytes)
        var calls = 0
        XCTAssertThrowsError(try context.withSignature(from: f.vault, messageData: bytes, originalIdentity: f.subject) {
            calls += 1; throw IdentityVaultError.signingFailed
        })
        XCTAssertTrue(context.didConsume)
        f.lease.retire(.authRevoked)
        XCTAssertThrowsError(try context.withSignature(from: f.vault, messageData: bytes, originalIdentity: f.subject) { calls += 1; return Data([1]) })
        XCTAssertEqual(calls, 1)
    }

    func testDifferentConcreteVaultCannotUseContextWithOriginalDescriptor() async throws {
        let f = try await fixture(), otherVault = LocalVault(), bytes = Data([1])
        let context = ContactSigningContext(lease: f.lease, source: f.vault, messageData: bytes)
        var calls = 0
        XCTAssertThrowsError(try context.withSignature(from: otherVault, messageData: bytes, originalIdentity: f.subject) {
            calls += 1; return Data([1])
        })
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(context.didConsume)
        _ = try context.withSignature(from: f.vault, messageData: bytes, originalIdentity: f.subject) {
            calls += 1; return Data([1])
        }
        XCTAssertEqual(calls, 1)
    }

    func testInvalidatedContextAndFailedLiveScopePerformNoSigning() async throws {
        let f = try await fixture(), bytes = Data([1])
        let invalid = ContactSigningContext(lease: f.lease, source: f.vault, messageData: bytes)
        invalid.invalidate()
        let stale = ContactSigningContext(lease: f.lease, source: f.vault, messageData: bytes) { throw ContactOperationFailure.channelClosed }
        var calls = 0
        for context in [invalid, stale] {
            XCTAssertThrowsError(try context.withSignature(from: f.vault, messageData: bytes, originalIdentity: f.subject) { calls += 1; return Data([1]) })
            XCTAssertFalse(context.didConsume)
        }
        XCTAssertEqual(calls, 0)
    }

    func testReferenceEndpointRequiresCanonicalCellAndExplicitPort() throws {
        let id = "F0000000-0000-4000-8000-000000000001"
        try ContactReferenceCodec.validateEndpoint("cell://contact.example:443/Contact-" + id, cellUUID: id)
        for endpoint in ["cell://contact.example/Contact-" + id,
                         "cell://contact.example:443/Contact-" + id + "?redirect=1",
                         "cell://CONTACT.example:443/Contact-" + id] {
            XCTAssertThrowsError(try ContactReferenceCodec.validateEndpoint(endpoint, cellUUID: id))
        }
        XCTAssertThrowsError(try ContactReferenceCodec.validateEndpoint("cell://contact.example:443/Contact-" + id.lowercased(), cellUUID: id.lowercased()))
    }

    func testRetainedRequestRoundTripPreservesIntegralExpiryAndDigest() async throws {
        let f = try await fixture()
        let bytes = try ContactReferenceCodec.encode(f.request)
        let decoded = try JSONDecoder().decode(ValueType.self, from: bytes)
        let lease = try ContactOperationLease(binding: f.binding, requester: f.subject,
                                             admission: f.admission, request: decoded)
        XCTAssertEqual(lease.snapshot.canonicalPayloadBytes, bytes)
        XCTAssertEqual(lease.snapshot.payloadDigest, f.lease.snapshot.payloadDigest)
    }

    func testReferenceRejectsWrongOwnerSubjectRouteAndChangedSignedFields() async throws {
        let f = try await fixture(), other = await LocalVault().identity()
        let endpoint = try XCTUnwrap(URL(string: f.binding.reference.logicalEndpoint))
        let wrongEndpoint = try XCTUnwrap(URL(string: f.binding.reference.logicalEndpoint.replacingOccurrences(of: ":443/", with: ":8443/")))
        let wrongKey = try BridgeChannelAuthentication.PublicIdentity(other)
        for (owner, subject, route) in [
            (wrongKey, f.binding.reference.subject, endpoint),
            (f.binding.reference.owner, wrongKey, endpoint),
            (f.binding.reference.owner, f.binding.reference.subject, wrongEndpoint)
        ] {
            do {
                _ = try await ContactReferenceCodec.verify(referenceBytes: f.binding.referenceBytes,
                    contractBytes: f.binding.contractBytes, expectedOwner: owner,
                    expectedSubject: subject, approvedEndpoint: route)
                XCTFail("Unverified target became a binding")
            } catch {}
        }
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: f.binding.referenceBytes) as? [String: Any])
        changed["expiresAtMilliseconds"] = f.binding.reference.expiresAtMilliseconds - 1
        let changedBytes = try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys, .withoutEscapingSlashes])
        do {
            _ = try await ContactReferenceCodec.verify(referenceBytes: changedBytes,
                contractBytes: f.binding.contractBytes, expectedOwner: f.binding.reference.owner,
                expectedSubject: f.binding.reference.subject, approvedEndpoint: endpoint)
            XCTFail("Changed signed expiry accepted")
        } catch {}
        // A valid control still verifies after every negative case.
        _ = try await ContactReferenceCodec.verify(referenceBytes: f.binding.referenceBytes,
            contractBytes: f.binding.contractBytes, expectedOwner: f.binding.reference.owner,
            expectedSubject: f.binding.reference.subject, approvedEndpoint: endpoint)
    }

    func testCanonicalReferenceRejectsDuplicateUnknownAndNoncanonicalJSON() async throws {
        let f = try await fixture()
        let canonical = try XCTUnwrap(String(data: f.binding.referenceBytes, encoding: .utf8))
        for bytes in [Data(("{\"profile\":\"ignored\"," + String(canonical.dropFirst())).utf8),
                      Data(("{\"unknown\":true," + String(canonical.dropFirst())).utf8),
                      Data((" " + canonical).utf8)] {
            XCTAssertThrowsError(try ContactReferenceCodec.decode(ContactInboxReferenceV1.self, from: bytes,
                maximumBytes: ContactReferenceCodec.maximumReferenceBytes))
        }
        let decoded = try ContactReferenceCodec.decode(ContactInboxReferenceV1.self, from: f.binding.referenceBytes,
            maximumBytes: ContactReferenceCodec.maximumReferenceBytes)
        XCTAssertEqual(try ContactReferenceCodec.encode(decoded), f.binding.referenceBytes)
    }

    func testActualContactCellAcceptsIntegralAndFractionalJSONExpiry() async throws {
        let ownerVault = EphemeralIdentityVault(), subjectVault = EphemeralIdentityVault()
        var owner = Identity(UUID().uuidString, displayName: "Synthetic owner", identityVault: ownerVault)
        var subject = Identity(UUID().uuidString, displayName: "Synthetic subject", identityVault: subjectVault)
        await ownerVault.addIdentity(identity: &owner, for: "private")
        await subjectVault.addIdentity(identity: &subject, for: "private")
        let cell = await ContactInboxCell(owner: owner)
        let grant = try await cell.set(keypath: "agreement.issue", value: .object([
            "subject": .identity(subject.publicIdentitySnapshot()), "durationSeconds": .integer(600)
        ]), requester: owner)
        let expiry = floor(Date().timeIntervalSince1970) + 300
        for (index, value) in [ValueType.float(expiry), .float(expiry + 0.25)].enumerated() {
            let request = ValueType.object(["requestID": .string("wire-\(index)"), "expiresAt": value,
                "payload": .object(["synthetic": .bool(true)]), "agreement": try XCTUnwrap(grant)])
            let decoded = try JSONDecoder().decode(ValueType.self, from: ContactReferenceCodec.encode(request))
            let response = try await cell.set(keypath: "contact.request", value: decoded, requester: subject)
            guard case let .object(receipt)? = response else { return XCTFail("Missing contact receipt") }
            XCTAssertEqual(receipt["status"], .string("queued"))
        }
        for invalid in [ValueType.string(String(expiry)), .bool(true), .float(.infinity), .null] {
            let request = ValueType.object(["requestID": .string("invalid"), "expiresAt": invalid,
                                           "payload": .object([:])])
            do { _ = try await cell.set(keypath: "contact.request", value: request, requester: subject); XCTFail("Invalid expiry accepted") } catch {}
        }
    }
}
