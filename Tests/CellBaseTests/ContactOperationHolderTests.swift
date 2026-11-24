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

    func testContactReferenceSubjectWriteOnlyRoundTrips() async throws {
        let f = try await fixture()
        let contract = try ContactReferenceCodec.decode(Contract.self,
            from: f.binding.contractBytes, maximumBytes: ContactReferenceCodec.maximumContractBytes)
        XCTAssertEqual(contract.agreement.grants.count, 1)
        XCTAssertEqual(contract.agreement.grants[0].permission.fullPermissionString, "-w------")
        let verified = try await ContactReferenceCodec.verify(
            referenceBytes: f.binding.referenceBytes, contractBytes: f.binding.contractBytes,
            expectedOwner: f.binding.reference.owner, expectedSubject: .init(f.subject),
            approvedEndpoint: try XCTUnwrap(URL(string: f.binding.reference.logicalEndpoint)))
        XCTAssertEqual(verified.referenceBytes, f.binding.referenceBytes)
    }

    func testContactReferenceRejectsBroaderSignedGroupAndOtherGrants() async throws {
        let ownerVault = EphemeralIdentityVault()
        var owner = Identity(UUID().uuidString, displayName: "Synthetic issuer", identityVault: ownerVault)
        await ownerVault.addIdentity(identity: &owner, for: "private")
        let subject = await LocalVault().identity()
        let ownerDescriptor = try BridgeChannelAuthentication.PublicIdentity(owner)
        let subjectDescriptor = try BridgeChannelAuthentication.PublicIdentity(subject)
        let issued = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 1)
        let expiry = issued.addingTimeInterval(300)
        for permission in ["-w--r---", "-w---w--", "-w----x-", "-w-----s",
                           "rw------", "-wx-----", "-w-s----", "--------"] {
            let cellUUID = UUID().uuidString
            let endpoint = try XCTUnwrap(URL(string: "cell://contact.example:443/Contact-" + cellUUID))
            let agreement = Agreement(owner: owner)
            agreement.state = .signed
            agreement.conditions = []
            agreement.grants = [Grant(keypath: "contact.request", permission: permission)]
            agreement.signatories = [owner, subject]
            agreement.duration = 600
            let contract = try await Contract.signed(agreement: agreement, issuer: owner, subject: subject,
                domain: ContactInboxCell.domain, issuedAt: issued, targetCellUUID: cellUUID)
            let contractBytes = try ContactReferenceCodec.encode(contract)
            XCTAssertEqual(contract.agreement.grants[0].permission.fullPermissionString, permission)
            let signatureValid = await contract.verifySignature(now: issued)
            XCTAssertTrue(signatureValid, "Negative case must have a valid signed contract")
            do {
                _ = try await ContactReferenceCodec.issue(contractBytes: contractBytes, endpoint: endpoint,
                    owner: owner, issuedAt: issued, expiresAt: expiry)
                XCTFail("Issued an overbroad contact reference: \(permission)")
            } catch {
                XCTAssertEqual(error as? ContactOperationFailure, .invalidBinding)
            }

            // Model an incoming, correctly signed reference from the real owner.
            // Bypass only the issuer helper so receiver validation is tested too.
            let unsigned = ContactInboxReferenceV1(profile: ContactInboxReferenceV1.profileName,
                logicalEndpoint: endpoint.absoluteString, cellUUID: cellUUID,
                identityDomain: ContactInboxCell.domain, owner: ownerDescriptor, subject: subjectDescriptor,
                contractDigest: try contract.signedContentDigest(),
                issuedAtMilliseconds: Int64(issued.timeIntervalSince1970 * 1000),
                expiresAtMilliseconds: Int64(expiry.timeIntervalSince1970 * 1000), signature: Data())
            var unsignedObject = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: ContactReferenceCodec.encode(unsigned)) as? [String: Any])
            XCTAssertNotNil(unsignedObject.removeValue(forKey: "signature"))
            var message = Data((ContactInboxReferenceV1.profileName + "\n").utf8)
            message.append(try JSONSerialization.data(withJSONObject: unsignedObject,
                options: [.sortedKeys, .withoutEscapingSlashes]))
            let signedBytes = try await owner.sign(data: message)
            let signature = try XCTUnwrap(signedBytes)
            XCTAssertTrue(IdentityPublicKeySignatureVerifier.verify(signature: signature,
                messageData: message, identity: ownerDescriptor.makeIdentity()))
            let reference = ContactInboxReferenceV1(profile: unsigned.profile,
                logicalEndpoint: unsigned.logicalEndpoint, cellUUID: cellUUID,
                identityDomain: unsigned.identityDomain, owner: ownerDescriptor, subject: subjectDescriptor,
                contractDigest: unsigned.contractDigest, issuedAtMilliseconds: unsigned.issuedAtMilliseconds,
                expiresAtMilliseconds: unsigned.expiresAtMilliseconds, signature: signature)
            do {
                _ = try await ContactReferenceCodec.verify(referenceBytes: ContactReferenceCodec.encode(reference),
                    contractBytes: contractBytes, expectedOwner: ownerDescriptor,
                    expectedSubject: subjectDescriptor, approvedEndpoint: endpoint, now: issued)
                XCTFail("Accepted an incoming overbroad signed reference: \(permission)")
            } catch {
                XCTAssertEqual(error as? ContactOperationFailure, .invalidBinding)
            }
        }
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
    // R2 additive review coverage. The seventeen R1 methods remain unchanged.
    private final class ControlledClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        private var uptime: TimeInterval
        init(date: Date, uptime: TimeInterval = 100) { self.date = date; self.uptime = uptime }
        func wall() -> Date { lock.withLock { date } }
        func monotonic() -> TimeInterval { lock.withLock { uptime } }
        func advance(wall: TimeInterval, monotonic: TimeInterval) {
            lock.withLock { date = date.addingTimeInterval(wall); uptime += monotonic }
        }
    }

    func testEachClockExpiryInsideVaultAwaitPreventsPrivateSigning() async throws {
        for expireWallClock in [false, true] {
            let f = try await fixture(), barrier = Barrier(), clock = ControlledClock(date: Date())
            let lease = try ContactOperationLease(binding: f.binding, requester: f.subject,
                admission: f.admission, request: f.request,
                wallClock: { clock.wall() }, monotonic: { clock.monotonic() })
            let secondsToExpiry = lease.snapshot.expiresAt.timeIntervalSince(clock.wall())
            XCTAssertGreaterThan(secondsToExpiry, 0)
            let originalWall = clock.wall(), originalMonotonic = clock.monotonic()
            await f.vault.configure(barrier: barrier)
            let task = Task { try await ContactOperationHolder.prepare(lease: lease, requester: f.subject) }
            await fulfillment(of: [barrier.entered], timeout: 5)
            // Change one injected clock only, after entry in the actual vault
            // await. No retire() call and no real time delay supplies the denial.
            clock.advance(wall: expireWallClock ? secondsToExpiry + 1 : 0,
                          monotonic: expireWallClock ? 0 : secondsToExpiry + 1)
            if expireWallClock { XCTAssertEqual(clock.monotonic(), originalMonotonic) }
            else { XCTAssertEqual(clock.wall(), originalWall) }
            await barrier.release()
            do { _ = try await task.value; XCTFail("Expired operation returned a holder") }
            catch { XCTAssertEqual(error as? ContactOperationFailure, .expired) }
            let count = await f.vault.signingCount()
            XCTAssertEqual(count, 0)
            XCTAssertFalse(lease.applicationDispatchWasAdmitted)

            // A fresh operation with a current independent clock still works.
            await f.vault.configure()
            let freshClock = ControlledClock(date: Date())
            let fresh = try ContactOperationLease(binding: f.binding, requester: f.subject,
                admission: f.admission, request: f.request,
                wallClock: { freshClock.wall() }, monotonic: { freshClock.monotonic() })
            _ = try await ContactOperationHolder.prepare(lease: fresh, requester: f.subject)
            let afterFresh = await f.vault.signingCount()
            XCTAssertEqual(afterFresh, 1)
        }
    }

    func testFailedPrivateCallCannotRetryConsumedContextWhileLeaseRemainsActive() async throws {
        let f = try await fixture(), bytes = Data("synthetic failed signing attempt".utf8)
        let context = ContactSigningContext(lease: f.lease, source: f.vault, messageData: bytes)
        await f.vault.configure(failSigning: true)
        do {
            _ = try await f.vault.signContactMessage(messageData: bytes, originalIdentity: f.subject, context: context)
            XCTFail("Injected private signer failure did not throw")
        } catch {}
        let afterFailure = await f.vault.signingCount()
        XCTAssertEqual(afterFailure, 1, "Must reach the injected failure inside the signer closure")
        XCTAssertTrue(context.didConsume)
        XCTAssertNoThrow(try f.lease.withCurrent {})

        // Remove the signer fault. Only consumption may reject this retry:
        // the original lease has not been retired, cancelled or expired.
        await f.vault.configure()
        do {
            _ = try await f.vault.signContactMessage(messageData: bytes, originalIdentity: f.subject, context: context)
            XCTFail("Consumed context admitted a second private call")
        } catch { XCTAssertEqual(error as? ContactOperationFailure, .signingDenied) }
        let afterRetry = await f.vault.signingCount()
        XCTAssertEqual(afterRetry, 1)
        XCTAssertNoThrow(try f.lease.withCurrent {})

        let freshContext = ContactSigningContext(lease: f.lease, source: f.vault, messageData: bytes)
        let signature = try await f.vault.signContactMessage(messageData: bytes,
            originalIdentity: f.subject, context: freshContext)
        XCTAssertTrue(IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: bytes, identity: f.subject))
        let afterFresh = await f.vault.signingCount()
        XCTAssertEqual(afterFresh, 2)
    }

    func testActualBridgeIdentityVaultCannotMintLocalHolder() async throws {
        let f = try await fixture()
        let remote = f.subject.publicIdentitySnapshot()
        // Same public key and full-looking home cannot turn this actual proxy
        // type into a local holder. It has no live network connection in this test.
        remote.homeVaultReference = f.subject.homeVaultReference
        remote.identityVault = BridgeIdentityVault(cloudBridge: nil)
        XCTAssertTrue(remote.identityVault is BridgeIdentityVault)
        do {
            _ = try await ContactOperationHolder.prepare(lease: f.lease, requester: remote)
            XCTFail("Proxy vault acquired local signing authority")
        } catch { XCTAssertEqual(error as? ContactOperationFailure, .unsupportedSigner) }
        let count = await f.vault.signingCount()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(f.lease.applicationDispatchWasAdmitted)
        XCTAssertNoThrow(try f.lease.withCurrent {})
        _ = try await ContactOperationHolder.prepare(lease: f.lease, requester: f.subject)
        let afterLocal = await f.vault.signingCount()
        XCTAssertEqual(afterLocal, 1)
    }
    // End R2 additive review coverage.
    // R4 additive registry-owner coverage. The twenty R2 methods remain unchanged.
    // Synthetic trusted-host restore/register inputs exercise retirement, not
    // the enrollment verification ceremony (covered in the existing tests).
    private func registryRecord(owner: Identity, linkID: String = "synthetic-link") async throws -> IdentityLinkRecord {
        let phone = await LocalVault().identity()
        return IdentityLinkRecord(linkID: linkID,
            entityBinding: EntityBindingDescriptor(mode: .localEntityAnchor,
                entityAnchorReference: EntityGenesisService.anchorReference),
            linkedIdentity: try IdentityLinkProtocolService.descriptor(for: phone),
            approvedDomains: ["private"], approvedIdentityContexts: [],
            approvedScopes: [IdentityLinkScope.sameEntity], issuerIdentityUUID: owner.uuid,
            issuerType: .existingDevice, status: .active,
            linkedAt: IdentityLinkProtocolService.iso8601(Date()))
    }

    private func registryCompletion(_ record: IdentityLinkRecord) -> IdentityLinkCompletionResult {
        IdentityLinkCompletionResult(record: record, requestHash: Data([1]),
            approvalJTI: "synthetic", credentialID: "synthetic", presentationID: "synthetic")
    }

    private func attach(_ lease: ContactOperationLease, registry: IdentityLinkRegistry,
        owner: String, record: IdentityLinkRecord) async throws -> IdentityLinkContactAttachment {
        let observed = await registry.contactOperationRevision(ownerUUID: owner, matching: record)
        let revision = try XCTUnwrap(observed)
        let attached = await registry.attachContactOperation(lease, to: revision)
        return try XCTUnwrap(attached)
    }

    func testRegistryMutationsDuringActualSignerAwaitRetireOriginalOperation() async throws {
        for mutation in ["register-key", "register-scope", "register-identical", "restore-identical", "revoke", "clear"] {
            let f = try await fixture(), registry = IdentityLinkRegistry(), barrier = Barrier()
            let record = try await registryRecord(owner: f.subject)
            var replacement = record
            if mutation == "register-key" {
                let other = await LocalVault().identity()
                replacement.linkedIdentity = try IdentityLinkProtocolService.descriptor(for: other)
                replacement.linkedIdentity.uuid = record.linkedIdentity.uuid
            }
            if mutation == "register-scope" { replacement.approvedScopes = ["contact-only"] }
            await registry.restore(ownerUUID: f.subject.uuid, records: [record])
            _ = try await attach(f.lease, registry: registry, owner: f.subject.uuid, record: record)
            await f.vault.configure(barrier: barrier)
            let task = Task { try await ContactOperationHolder.prepare(lease: f.lease, requester: f.subject) }
            await fulfillment(of: [barrier.entered], timeout: 5)
            // The actual authority owner, not a direct test lease.retire call.
            switch mutation {
            case "register-key", "register-scope", "register-identical":
                await registry.register(ownerUUID: f.subject.uuid, completion: registryCompletion(replacement))
            case "restore-identical": await registry.restore(ownerUUID: f.subject.uuid, records: [record])
            case "revoke": await registry.revoke(ownerUUID: f.subject.uuid, linkID: record.linkID, revokedAt: "synthetic-now")
            default: await registry.clear(ownerUUID: f.subject.uuid)
            }
            let published = await registry.activeLinks(ownerUUID: f.subject.uuid)
            if mutation == "revoke" || mutation == "clear" { XCTAssertTrue(published.isEmpty, mutation) }
            else { XCTAssertEqual(published, [replacement], mutation) }
            XCTAssertThrowsError(try f.lease.withCurrent {}) {
                XCTAssertEqual($0 as? ContactOperationFailure, .staleIntent, mutation)
            }
            await barrier.release()
            do { _ = try await task.value; XCTFail("Stale signer returned: \(mutation)") }
            catch { XCTAssertEqual(error as? ContactOperationFailure, .staleIntent, mutation) }
            let count = await f.vault.signingCount()
            XCTAssertEqual(count, 0, mutation)
            XCTAssertFalse(f.lease.applicationDispatchWasAdmitted)

            // Restoring authority permits a NEW operation; never revives old one.
            await registry.restore(ownerUUID: f.subject.uuid, records: [record])
            await f.vault.configure()
            let fresh = try ContactOperationLease(binding: f.binding, requester: f.subject,
                admission: f.admission, request: f.request)
            _ = try await attach(fresh, registry: registry, owner: f.subject.uuid, record: record)
            _ = try await ContactOperationHolder.prepare(lease: fresh, requester: f.subject)
            let afterFresh = await f.vault.signingCount()
            XCTAssertEqual(afterFresh, 1, mutation)
            XCTAssertThrowsError(try f.lease.withCurrent {})
            await registry.clear(ownerUUID: f.subject.uuid)
        }
    }

    func testRegistryRevisionRequiresCompleteActiveRecordAndOriginalRegistry() async throws {
        let f = try await fixture(), registry = IdentityLinkRegistry(), foreign = IdentityLinkRegistry()
        let record = try await registryRecord(owner: f.subject)
        await registry.restore(ownerUUID: f.subject.uuid, records: [record])
        var wrongKey = record, wrongScope = record, inactive = record
        let other = await LocalVault().identity()
        wrongKey.linkedIdentity = try IdentityLinkProtocolService.descriptor(for: other)
        wrongKey.linkedIdentity.uuid = record.linkedIdentity.uuid
        wrongScope.approvedScopes = []; inactive.status = .revoked
        for mismatch in [wrongKey, wrongScope, inactive] {
            let observed = await registry.contactOperationRevision(ownerUUID: f.subject.uuid, matching: mismatch)
            XCTAssertNil(observed)
        }
        let wrongOwner = await registry.contactOperationRevision(ownerUUID: "unrelated-owner", matching: record)
        XCTAssertNil(wrongOwner)
        await foreign.restore(ownerUUID: f.subject.uuid, records: [record])
        let observed = await registry.contactOperationRevision(ownerUUID: f.subject.uuid, matching: record)
        let revision = try XCTUnwrap(observed)
        let rejected = await foreign.attachContactOperation(f.lease, to: revision)
        XCTAssertNil(rejected)
        XCTAssertThrowsError(try f.lease.withCurrent {})
        let count = await f.vault.signingCount(); XCTAssertEqual(count, 0)
        let fresh = try ContactOperationLease(binding: f.binding, requester: f.subject,
            admission: f.admission, request: f.request)
        _ = try await attach(fresh, registry: foreign, owner: f.subject.uuid, record: record)
        _ = try await ContactOperationHolder.prepare(lease: fresh, requester: f.subject)
        await foreign.clear(ownerUUID: f.subject.uuid)
        await registry.restore(ownerUUID: f.subject.uuid, records: [inactive])
        let inactiveObserved = await registry.contactOperationRevision(ownerUUID: f.subject.uuid, matching: inactive)
        XCTAssertNil(inactiveObserved)
    }

    func testRegistryRevisionCannotAttachAfterSameRecordABA() async throws {
        let f = try await fixture(), registry = IdentityLinkRegistry()
        let record = try await registryRecord(owner: f.subject)
        await registry.restore(ownerUUID: f.subject.uuid, records: [record])
        let observed = await registry.contactOperationRevision(ownerUUID: f.subject.uuid, matching: record)
        let original = try XCTUnwrap(observed)
        var changed = record; changed.approvedScopes = []
        await registry.restore(ownerUUID: f.subject.uuid, records: [changed])
        await registry.restore(ownerUUID: f.subject.uuid, records: [record])
        let stale = await registry.attachContactOperation(f.lease, to: original)
        XCTAssertNil(stale)
        XCTAssertThrowsError(try f.lease.withCurrent {})
        let fresh = try ContactOperationLease(binding: f.binding, requester: f.subject,
            admission: f.admission, request: f.request)
        _ = try await attach(fresh, registry: registry, owner: f.subject.uuid, record: record)
        _ = try await ContactOperationHolder.prepare(lease: fresh, requester: f.subject)
        let count = await f.vault.signingCount(); XCTAssertEqual(count, 1)
        await registry.clear(ownerUUID: f.subject.uuid)
    }

    func testRegistryDetachIsExactInstanceAndCannotDetachSuccessor() async throws {
        let f = try await fixture(), registry = IdentityLinkRegistry()
        let record = try await registryRecord(owner: f.subject)
        await registry.restore(ownerUUID: f.subject.uuid, records: [record])
        let original = try await attach(f.lease, registry: registry, owner: f.subject.uuid, record: record)
        let duplicate = try await attach(f.lease, registry: registry, owner: f.subject.uuid, record: record)
        XCTAssertEqual(original, duplicate)
        let sibling = try ContactOperationLease(binding: f.binding, requester: f.subject,
            admission: f.admission, request: f.request)
        let siblingHandle = try await attach(sibling, registry: registry, owner: f.subject.uuid, record: record)
        XCTAssertNotEqual(original, siblingHandle)
        let wrongInstance = await registry.detachContactOperation(sibling, attachment: original)
        XCTAssertFalse(wrongInstance)
        XCTAssertNoThrow(try f.lease.withCurrent {}); XCTAssertNoThrow(try sibling.withCurrent {})
        let detached = await registry.detachContactOperation(f.lease, attachment: original)
        XCTAssertTrue(detached); XCTAssertThrowsError(try f.lease.withCurrent {})
        _ = try await ContactOperationHolder.prepare(lease: sibling, requester: f.subject)
        await registry.restore(ownerUUID: f.subject.uuid, records: [record])
        XCTAssertThrowsError(try sibling.withCurrent {})
        let successor = try ContactOperationLease(binding: f.binding, requester: f.subject,
            admission: f.admission, request: f.request)
        let successorHandle = try await attach(successor, registry: registry, owner: f.subject.uuid, record: record)
        let staleOriginal = await registry.detachContactOperation(f.lease, attachment: original)
        let staleSibling = await registry.detachContactOperation(successor, attachment: siblingHandle)
        XCTAssertFalse(staleOriginal); XCTAssertFalse(staleSibling)
        _ = try await ContactOperationHolder.prepare(lease: successor, requester: f.subject)
        let finalDetach = await registry.detachContactOperation(successor, attachment: successorHandle)
        XCTAssertTrue(finalDetach); XCTAssertThrowsError(try successor.withCurrent {})
        let count = await f.vault.signingCount(); XCTAssertEqual(count, 2)
    }

    func testRegistryFreshRevisionCannotReattachRetiredOriginalOperation() async throws {
        let f = try await fixture(), registry = IdentityLinkRegistry()
        let record = try await registryRecord(owner: f.subject)
        await registry.restore(ownerUUID: f.subject.uuid, records: [record])
        _ = try await attach(f.lease, registry: registry, owner: f.subject.uuid, record: record)
        await registry.clear(ownerUUID: f.subject.uuid)
        await registry.restore(ownerUUID: f.subject.uuid, records: [record])
        let observed = await registry.contactOperationRevision(ownerUUID: f.subject.uuid, matching: record)
        let revision = try XCTUnwrap(observed)
        let rejected = await registry.attachContactOperation(f.lease, to: revision)
        XCTAssertNil(rejected)
        do { _ = try await ContactOperationHolder.prepare(lease: f.lease, requester: f.subject); XCTFail("Retired lease revived") }
        catch { XCTAssertEqual(error as? ContactOperationFailure, .staleIntent) }
        let count = await f.vault.signingCount(); XCTAssertEqual(count, 0)
        let fresh = try ContactOperationLease(binding: f.binding, requester: f.subject,
            admission: f.admission, request: f.request)
        _ = try await attach(fresh, registry: registry, owner: f.subject.uuid, record: record)
        _ = try await ContactOperationHolder.prepare(lease: fresh, requester: f.subject)
        await registry.clear(ownerUUID: f.subject.uuid)
    }

    func testRegistryMutationPreservesOtherLinkAndOtherOwnerOperations() async throws {
        let f = try await fixture(), registry = IdentityLinkRegistry()
        let first = try await registryRecord(owner: f.subject, linkID: "first")
        let second = try await registryRecord(owner: f.subject, linkID: "second")
        let other = try await fixture()
        let otherRecord = try await registryRecord(owner: other.subject, linkID: "first")
        await registry.restore(ownerUUID: f.subject.uuid, records: [first, second])
        await registry.restore(ownerUUID: other.subject.uuid, records: [otherRecord])
        let sibling = try ContactOperationLease(binding: f.binding, requester: f.subject,
            admission: f.admission, request: f.request)
        _ = try await attach(f.lease, registry: registry, owner: f.subject.uuid, record: first)
        _ = try await attach(sibling, registry: registry, owner: f.subject.uuid, record: second)
        _ = try await attach(other.lease, registry: registry, owner: other.subject.uuid, record: otherRecord)
        await registry.revoke(ownerUUID: f.subject.uuid, linkID: first.linkID, revokedAt: "synthetic-now")
        XCTAssertThrowsError(try f.lease.withCurrent {})
        _ = try await ContactOperationHolder.prepare(lease: sibling, requester: f.subject)
        await registry.clear(ownerUUID: f.subject.uuid)
        XCTAssertThrowsError(try sibling.withCurrent {})
        _ = try await ContactOperationHolder.prepare(lease: other.lease, requester: other.subject)
        let count = await f.vault.signingCount(), otherCount = await other.vault.signingCount()
        XCTAssertEqual(count, 1); XCTAssertEqual(otherCount, 1)
        await registry.clear(ownerUUID: other.subject.uuid)
    }
    func testRegistryPartialMultiOwnerAttachFailureRetiresAndDetachesOriginal() async throws {
        let f = try await fixture(), firstOwner = IdentityLinkRegistry(), secondOwner = IdentityLinkRegistry()
        let record = try await registryRecord(owner: f.subject)
        await firstOwner.restore(ownerUUID: f.subject.uuid, records: [record])
        await secondOwner.restore(ownerUUID: f.subject.uuid, records: [record])
        let first = try await attach(f.lease, registry: firstOwner, owner: f.subject.uuid, record: record)
        let observed = await secondOwner.contactOperationRevision(ownerUUID: f.subject.uuid, matching: record)
        let originalSecond = try XCTUnwrap(observed)
        await secondOwner.restore(ownerUUID: f.subject.uuid, records: [record])
        let rejected = await secondOwner.attachContactOperation(f.lease, to: originalSecond)
        XCTAssertNil(rejected)
        XCTAssertThrowsError(try f.lease.withCurrent {})
        let removed = await firstOwner.detachContactOperation(f.lease, attachment: first)
        let removedAgain = await firstOwner.detachContactOperation(f.lease, attachment: first)
        XCTAssertTrue(removed); XCTAssertFalse(removedAgain)
        do { _ = try await ContactOperationHolder.prepare(lease: f.lease, requester: f.subject); XCTFail("Partial admission signed") }
        catch { XCTAssertEqual(error as? ContactOperationFailure, .staleIntent) }
        let count = await f.vault.signingCount(); XCTAssertEqual(count, 0)
        let fresh = try ContactOperationLease(binding: f.binding, requester: f.subject,
            admission: f.admission, request: f.request)
        _ = try await attach(fresh, registry: firstOwner, owner: f.subject.uuid, record: record)
        _ = try await attach(fresh, registry: secondOwner, owner: f.subject.uuid, record: record)
        _ = try await ContactOperationHolder.prepare(lease: fresh, requester: f.subject)
        await secondOwner.clear(ownerUUID: f.subject.uuid)
        XCTAssertThrowsError(try fresh.withCurrent {})
        await firstOwner.clear(ownerUUID: f.subject.uuid)
    }
    func testRegistryPerLinkCapacityPreservesExistingOperationsAndDetachReleasesSlot() async throws {
        let f = try await fixture(), registry = IdentityLinkRegistry()
        let record = try await registryRecord(owner: f.subject)
        await registry.restore(ownerUUID: f.subject.uuid, records: [record])
        let observed = await registry.contactOperationRevision(ownerUUID: f.subject.uuid, matching: record)
        let revision = try XCTUnwrap(observed)
        var retained: [(ContactOperationLease, IdentityLinkContactAttachment)] = []
        for _ in 0..<IdentityLinkRegistry.maximumContactOperationsPerLink {
            let lease = try ContactOperationLease(binding: f.binding, requester: f.subject,
                admission: f.admission, request: f.request)
            let result = await registry.attachContactOperation(lease, to: revision)
            retained.append((lease, try XCTUnwrap(result)))
        }
        let duplicate = await registry.attachContactOperation(retained[0].0, to: revision)
        XCTAssertEqual(duplicate, retained[0].1)
        let rejected = await registry.attachContactOperation(f.lease, to: revision)
        XCTAssertNil(rejected); XCTAssertThrowsError(try f.lease.withCurrent {})
        for entry in retained { XCTAssertNoThrow(try entry.0.withCurrent {}) }
        _ = try await ContactOperationHolder.prepare(lease: retained[1].0, requester: f.subject)
        let detached = await registry.detachContactOperation(retained[0].0, attachment: retained[0].1)
        XCTAssertTrue(detached)
        let fresh = try ContactOperationLease(binding: f.binding, requester: f.subject,
            admission: f.admission, request: f.request)
        _ = try await attach(fresh, registry: registry, owner: f.subject.uuid, record: record)
        _ = try await ContactOperationHolder.prepare(lease: fresh, requester: f.subject)
        await registry.clear(ownerUUID: f.subject.uuid)
        for entry in retained { XCTAssertThrowsError(try entry.0.withCurrent {}) }
        XCTAssertThrowsError(try fresh.withCurrent {})
        await registry.restore(ownerUUID: f.subject.uuid, records: [record])
        let afterClear = try ContactOperationLease(binding: f.binding, requester: f.subject,
            admission: f.admission, request: f.request)
        _ = try await attach(afterClear, registry: registry, owner: f.subject.uuid, record: record)
        await registry.clear(ownerUUID: f.subject.uuid)
    }

    func testRegistryGlobalCapacityBoundsDifferentLinksAndOnlyExactDetachReleasesSlot() async throws {
        let f = try await fixture(), registry = IdentityLinkRegistry()
        let base = try await registryRecord(owner: f.subject)
        let linkCount = IdentityLinkRegistry.maximumContactRegistrations / IdentityLinkRegistry.maximumContactOperationsPerLink + 1
        let records = (0..<linkCount).map { index -> IdentityLinkRecord in
            var record = base; record.linkID = "capacity-\(index)"; return record
        }
        await registry.restore(ownerUUID: f.subject.uuid, records: records)
        var retained: [(ContactOperationLease, IdentityLinkContactAttachment)] = []
        for index in 0..<IdentityLinkRegistry.maximumContactRegistrations {
            let lease = try ContactOperationLease(binding: f.binding, requester: f.subject,
                admission: f.admission, request: f.request)
            let handle = try await attach(lease, registry: registry, owner: f.subject.uuid,
                record: records[index / IdentityLinkRegistry.maximumContactOperationsPerLink])
            retained.append((lease, handle))
        }
        let spareRecord = try XCTUnwrap(records.last)
        let observed = await registry.contactOperationRevision(ownerUUID: f.subject.uuid, matching: spareRecord)
        let spareRevision = try XCTUnwrap(observed)
        let rejected = await registry.attachContactOperation(f.lease, to: spareRevision)
        XCTAssertNil(rejected); XCTAssertThrowsError(try f.lease.withCurrent {})
        for entry in retained { XCTAssertNoThrow(try entry.0.withCurrent {}) }
        let wrong = await registry.detachContactOperation(retained[1].0, attachment: retained[0].1)
        XCTAssertFalse(wrong)
        let stillFull = try ContactOperationLease(binding: f.binding, requester: f.subject,
            admission: f.admission, request: f.request)
        let rejectedAgain = await registry.attachContactOperation(stillFull, to: spareRevision)
        XCTAssertNil(rejectedAgain); XCTAssertThrowsError(try stillFull.withCurrent {})
        let detached = await registry.detachContactOperation(retained[0].0, attachment: retained[0].1)
        XCTAssertTrue(detached)
        let fresh = try ContactOperationLease(binding: f.binding, requester: f.subject,
            admission: f.admission, request: f.request)
        _ = try await attach(fresh, registry: registry, owner: f.subject.uuid, record: spareRecord)
        _ = try await ContactOperationHolder.prepare(lease: fresh, requester: f.subject)
        await registry.clear(ownerUUID: f.subject.uuid)
        for entry in retained { XCTAssertThrowsError(try entry.0.withCurrent {}) }
        XCTAssertThrowsError(try fresh.withCurrent {})
    }

    func testRegistryExpiredRegistrationsStayBoundedUntilExactOwnerCleanup() async throws {
        let f = try await fixture(), registry = IdentityLinkRegistry(), clock = ControlledClock(date: Date())
        let record = try await registryRecord(owner: f.subject)
        await registry.restore(ownerUUID: f.subject.uuid, records: [record])
        let observed = await registry.contactOperationRevision(ownerUUID: f.subject.uuid, matching: record)
        let revision = try XCTUnwrap(observed)
        var retained: [(ContactOperationLease, IdentityLinkContactAttachment)] = []
        for _ in 0..<IdentityLinkRegistry.maximumContactOperationsPerLink {
            let lease = try ContactOperationLease(binding: f.binding, requester: f.subject,
                admission: f.admission, request: f.request,
                wallClock: { clock.wall() }, monotonic: { clock.monotonic() })
            let result = await registry.attachContactOperation(lease, to: revision)
            retained.append((lease, try XCTUnwrap(result)))
        }
        clock.advance(wall: 1000, monotonic: 1000)
        // Expired entries cannot grow or silently evict a different operation.
        // The admitting owner remains responsible for exact terminal cleanup.
        for _ in 0..<3 {
            let fresh = try ContactOperationLease(binding: f.binding, requester: f.subject,
                admission: f.admission, request: f.request)
            let rejected = await registry.attachContactOperation(fresh, to: revision)
            XCTAssertNil(rejected); XCTAssertThrowsError(try fresh.withCurrent {})
        }
        for entry in retained {
            XCTAssertThrowsError(try entry.0.withCurrent {}) { XCTAssertEqual($0 as? ContactOperationFailure, .expired) }
            let detached = await registry.detachContactOperation(entry.0, attachment: entry.1)
            XCTAssertTrue(detached)
        }
        let fresh = try ContactOperationLease(binding: f.binding, requester: f.subject,
            admission: f.admission, request: f.request)
        _ = try await attach(fresh, registry: registry, owner: f.subject.uuid, record: record)
        _ = try await ContactOperationHolder.prepare(lease: fresh, requester: f.subject)
        let count = await f.vault.signingCount(); XCTAssertEqual(count, 1)
        await registry.clear(ownerUUID: f.subject.uuid)
    }
    func testRegistryColdRestoreAllowsFirstCaptureButRejectsReplacedEvidence() async throws {
        let f = try await fixture(), registry = IdentityLinkRegistry()
        let originalEvidenceRecord = try await registryRecord(owner: f.subject)
        let beforeRecovery = await registry.contactOperationRevision(ownerUUID: f.subject.uuid,
            matching: originalEvidenceRecord)
        XCTAssertNil(beforeRecovery)
        // Actual registry recovery boundary. The application must independently
        // revalidate its authenticated evidence after this await; this test
        // supplies synthetic trusted evidence and does not simulate CS auth.
        await registry.restore(ownerUUID: f.subject.uuid, records: [originalEvidenceRecord])
        _ = try await attach(f.lease, registry: registry, owner: f.subject.uuid, record: originalEvidenceRecord)
        _ = try await ContactOperationHolder.prepare(lease: f.lease, requester: f.subject)
        var replacement = originalEvidenceRecord; replacement.approvedScopes = ["contact-only"]
        await registry.restore(ownerUUID: f.subject.uuid, records: [replacement])
        let staleEvidence = await registry.contactOperationRevision(ownerUUID: f.subject.uuid,
            matching: originalEvidenceRecord)
        XCTAssertNil(staleEvidence)
        XCTAssertThrowsError(try f.lease.withCurrent {})
        // The old operation cannot use even a current observation as a rescue.
        let current = await registry.contactOperationRevision(ownerUUID: f.subject.uuid, matching: replacement)
        let currentRevision = try XCTUnwrap(current)
        let oldOperation = await registry.attachContactOperation(f.lease, to: currentRevision)
        XCTAssertNil(oldOperation)
        let count = await f.vault.signingCount(); XCTAssertEqual(count, 1)
        await registry.clear(ownerUUID: f.subject.uuid)
    }
    // End R4 additive registry-owner coverage.
}
