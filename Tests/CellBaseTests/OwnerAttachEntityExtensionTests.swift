// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import CellBase

final class OwnerAttachEntityExtensionTests: XCTestCase {
    actor Store: OwnerAttachExtensionStore {
        var data: [String: Data] = [:]
        var writes = 0
        var fail = false
        func read(id: String) -> Data? { data[id] }
        func write(_ value: Data, id: String) throws {
            if fail { throw OwnerAttachExtensionError.persistenceFailed }
            data[id] = value; writes += 1
        }
        func setFail() { fail = true }
    }
    actor Counter {
        var value = 0
        func increment() { value += 1 }
    }
    final class SharedCell: GeneralCell {
        override func validateCellSpecificAccess(_ requestedAccess: String, at keypath: String, for identity: Identity) async -> Bool { true }
        override func admit(context: ConnectContext) async -> ConnectState { .connected }
    }
    let vault = OrganizerAccessTestIdentityVault()
    var oldDebug = false
    override func setUp() { oldDebug = CellBase.debugValidateAccessForEverything; CellBase.debugValidateAccessForEverything = false }
    override func tearDown() { CellBase.debugValidateAccessForEverything = oldDebug }

    func testGoldenOfferUsesISO8601AndRejectsMissingSignature() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try String(contentsOf: root.appendingPathComponent(
            "fixtures/owner-attach/v1/offer-missing-signature.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let offer = try OwnerAttachWire.decode(OwnerAttachExtensionOffer.self, data: Data(fixture.utf8))
        XCTAssertEqual(String(decoding: try OwnerAttachWire.encode(offer), as: UTF8.self), fixture)
        XCTAssertEqual(offer.expiresAt, ISO8601DateFormatter().date(from: "2026-09-28T00:05:00Z"))
        XCTAssertThrowsError(try offer.validate(now: offer.expiresAt.addingTimeInterval(-60))) {
            XCTAssertEqual($0 as? OwnerAttachExtensionError, .invalidProof)
        }
        let transported = try OwnerAttachWire.decode(OwnerAttachExtensionOffer.self,
            from: OwnerAttachWire.value(from: offer))
        XCTAssertEqual(try OwnerAttachWire.encode(transported), try OwnerAttachWire.encode(offer))
    }

    func fixture() async -> (Identity, GeneralCell, OwnerAttachEntityExtensionHost, Store) {
        let owner = await vault.makeIdentity(displayName: "human")
        let receiver = await vault.makeIdentity(displayName: "receipt signer")
        let cell = await GeneralCell(owner: owner)
        let store = Store()
        return (owner, cell, OwnerAttachEntityExtensionHost(receiver: receiver, label: "Test receiver", store: store), store)
    }

    func testRealAttachOnlyInvokesExplicitUserContext() async throws {
        let (owner, cell, _, _) = await fixture()
        let source = await GeneralCell(owner: owner)
        let count = Counter()
        _ = try await source.attach(emitter: cell, label: "passive", requester: owner)
        var value = await count.value; XCTAssertEqual(value, 0)
        _ = try await OwnerAttachExtensionContext.$handler.withValue({ _, _, _, _ in await count.increment() }) {
            try await source.attach(emitter: cell, label: "explicit", requester: owner)
        }
        value = await count.value; XCTAssertEqual(value, 1)
    }

    func testFreshOwnerConsentCompletesOnceAcrossRetry() async throws {
        let (owner, cell, host, store) = await fixture()
        let offer = try await host.offer(cell: cell, requester: owner)
        let consent = try await OwnerAttachExtensionConsent.make(offer: offer, choice: .once, identity: owner)
        let first = try await host.accept(consent, cell: cell, requester: owner)
        let second = try await host.accept(consent, cell: cell, requester: owner)
        XCTAssertEqual(try OwnerAttachWire.encode(first), try OwnerAttachWire.encode(second))
        let writes = await store.writes; XCTAssertEqual(writes, 1)
        try first.validate(for: offer.binding)
        let links = await IdentityLinkRegistry.shared.activeLinks(ownerUUID: owner.uuid)
        XCTAssertTrue(links.isEmpty, "Presence must not create an enrollment or link the scaffold identity")
    }

    func testSharedAccessCopiedDescriptorAndDebugBypassNeverQualify() async throws {
        let (owner, _, host, _) = await fixture()
        let shared = await SharedCell(owner: owner)
        let visitor = await vault.makeIdentity(displayName: "visitor")
        let access = await shared.validateAccess("r---", at: "content", for: visitor)
        XCTAssertTrue(access)
        for candidate in [visitor, owner.publicIdentitySnapshot()] {
            do { _ = try await host.offer(cell: shared, requester: candidate); XCTFail("Must prove owner control") }
            catch { XCTAssertEqual(error as? OwnerAttachExtensionError, .ownerProofRequired) }
        }
        CellBase.debugValidateAccessForEverything = true
        do { _ = try await host.offer(cell: shared, requester: owner); XCTFail("Debug is not proof") }
        catch { XCTAssertEqual(error as? OwnerAttachExtensionError, .ownerProofRequired) }
    }

    func testOfferIsBoundToReceiverCellDomainAndHumanKey() async throws {
        let (owner, cell, host, _) = await fixture()
        let offer = try await host.offer(cell: cell, requester: owner)
        let other = await vault.makeIdentity(displayName: "other")
        do { _ = try await OwnerAttachExtensionConsent.make(offer: offer, choice: .once, identity: other); XCTFail("Requires enrollment") }
        catch { XCTAssertEqual(error as? OwnerAttachExtensionError, .enrollmentRequired) }
        let consent = try await OwnerAttachExtensionConsent.make(offer: offer, choice: .once, identity: owner)
        let anotherCell = await GeneralCell(owner: owner)
        do { _ = try await host.accept(consent, cell: anotherCell, requester: owner); XCTFail("Wrong cell") }
        catch { XCTAssertEqual(error as? OwnerAttachExtensionError, .wrongContext) }
        cell.identityDomain = "another-domain"
        do { _ = try await host.accept(consent, cell: cell, requester: owner); XCTFail("Wrong domain") }
        catch { XCTAssertEqual(error as? OwnerAttachExtensionError, .wrongContext) }
        do { try offer.validate(now: offer.expiresAt); XCTFail("Expired") }
        catch { XCTAssertEqual(error as? OwnerAttachExtensionError, .expired) }
        var tampered = consent; tampered.signature = Data(repeating: 0, count: 64)
        do { _ = try await host.accept(tampered, cell: cell, requester: owner); XCTFail("Bad signature") }
        catch { XCTAssertEqual(error as? OwnerAttachExtensionError, .invalidProof) }
    }

    func testPersistenceFailureDoesNotClaimCompletion() async throws {
        let (owner, cell, host, store) = await fixture()
        let offer = try await host.offer(cell: cell, requester: owner)
        let consent = try await OwnerAttachExtensionConsent.make(offer: offer, choice: .once, identity: owner)
        await store.setFail()
        do { _ = try await host.accept(consent, cell: cell, requester: owner); XCTFail("No completion") }
        catch { XCTAssertEqual(error as? OwnerAttachExtensionError, .persistenceFailed) }
        let writes = await store.writes; XCTAssertEqual(writes, 0)
    }

    func testRevokedLinkedOwnerCannotReplaySavedConsent() async throws {
        let (owner, cell, host, _) = await fixture()
        let phone = await vault.makeIdentity(displayName: "phone")
        let record = IdentityLinkRecord(linkID: UUID().uuidString,
            entityBinding: EntityBindingDescriptor(mode: .localEntityAnchor, entityAnchorReference: "cell:///EntityAnchor"),
            linkedIdentity: try IdentityLinkProtocolService.descriptor(for: phone), approvedDomains: [cell.identityDomain],
            approvedIdentityContexts: ["private"], approvedScopes: [IdentityLinkScope.sameEntity],
            issuerIdentityUUID: owner.uuid, issuerType: .existingDevice, status: .active,
            linkedAt: IdentityLinkProtocolService.iso8601(Date()))
        await IdentityLinkRegistry.shared.restore(ownerUUID: owner.uuid, records: [record])
        let phoneSurface = await GeneralCell(owner: phone)
        let attached = try await phoneSurface.attach(emitter: cell, label: "linked-owned", requester: phone)
        XCTAssertEqual(attached, .connected, "An existing verified same-entity identity must be admitted as owner")
        let offer = try await host.offer(cell: cell, requester: phone)
        let consent = try await OwnerAttachExtensionConsent.make(offer: offer, choice: .once, identity: phone)
        _ = try await host.accept(consent, cell: cell, requester: phone)
        await IdentityLinkRegistry.shared.revoke(ownerUUID: owner.uuid, linkID: record.linkID,
            revokedAt: IdentityLinkProtocolService.iso8601(Date()))
        let stateAfterRevocation = await cell.determineIdentityState(identity: phone)
        XCTAssertNotEqual(stateAfterRevocation, .owner)
        do { _ = try await host.accept(consent, cell: cell, requester: phone); XCTFail("Revocation must still apply") }
        catch { XCTAssertEqual(error as? OwnerAttachExtensionError, .ownerProofRequired) }
        await IdentityLinkRegistry.shared.clear(ownerUUID: owner.uuid)
    }

    func testRuntimeMeddleClientPolicySurvivesRestartAndCanBeRemoved() async throws {
        let (owner, cell, host, store) = await fixture()
        await OwnerAttachExtensionRuntime.shared.install(host)
        let clientStore = Store()
        let count = Counter()
        let client = OwnerAttachEntityExtensionClient(store: clientStore)
        let review: OwnerAttachEntityExtensionClient.Review = { _ in await count.increment(); return .alwaysHere }
        _ = try await client.consider(emitter: cell, activeHuman: owner, requester: owner, stillAttached: { true }, review: review)
        let offer = try await host.offer(cell: cell, requester: owner)
        let firstData = await clientStore.read(id: offer.binding.storageID)!
        let firstRecord = try OwnerAttachWire.decode(OwnerAttachExtensionClientRecord.self, data: firstData)
        let later = Date().addingTimeInterval(30)
        let restarted = OwnerAttachEntityExtensionClient(store: clientStore, clock: { later })
        _ = try await restarted.consider(emitter: cell, activeHuman: owner, requester: owner, stillAttached: { true }, review: review)
        let secondData = await clientStore.read(id: offer.binding.storageID)!
        let secondRecord = try OwnerAttachWire.decode(OwnerAttachExtensionClientRecord.self, data: secondData)
        XCTAssertEqual(firstRecord.policy?.expiresAt, secondRecord.policy?.expiresAt,
            "Automatic use must not silently renew one-year consent")
        var reviews = await count.value; XCTAssertEqual(reviews, 1)
        let writes = await store.writes; XCTAssertEqual(writes, 1)
        try await restarted.forgetPolicy(for: offer.binding)
        _ = try await restarted.consider(emitter: cell, activeHuman: owner, requester: owner, stillAttached: { true }, review: { _ in await count.increment(); return nil })
        reviews = await count.value; XCTAssertEqual(reviews, 2)
        await OwnerAttachExtensionRuntime.shared.install(nil)
    }

    func testDeclineAndDetachDoNotWritePresenceOrBreakCellAccess() async throws {
        let (owner, cell, host, store) = await fixture()
        await OwnerAttachExtensionRuntime.shared.install(host)
        let client = OwnerAttachEntityExtensionClient(store: Store())
        _ = try await client.consider(emitter: cell, activeHuman: owner, requester: owner,
            stillAttached: { true }, review: { _ in nil })
        _ = try await client.consider(emitter: cell, activeHuman: owner, requester: owner,
            stillAttached: { false }, review: { _ in XCTFail("No detached prompt"); return .once })
        let writes = await store.writes; XCTAssertEqual(writes, 0)
        let source = await GeneralCell(owner: owner)
        let connected = try await source.attach(emitter: cell, label: "still-usable", requester: owner)
        XCTAssertEqual(connected, .connected)
        await OwnerAttachExtensionRuntime.shared.install(nil)
    }

    func testEncryptedStoreRoundTripAndTamperRejection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try SecureRandom.data(count: 32)
        let store = try OwnerAttachEncryptedStore(directory: root, key: key)
        let id = String(repeating: "a", count: 64)
        let data = Data("private person-to-runtime presence".utf8)
        try await store.write(data, id: id)
        let recovered = try await OwnerAttachEncryptedStore(directory: root, key: key).read(id: id)
        XCTAssertEqual(recovered, data)
        let ids = try await store.identifiers()
        XCTAssertEqual(ids, [id])
        let file = root.appendingPathComponent(id + ".sealed")
        var sealed = try Data(contentsOf: file)
        XCTAssertNil(String(data: sealed, encoding: .utf8))
        sealed[sealed.count - 1] ^= 1
        try sealed.write(to: file)
        do { try await store.write(data, id: id); XCTFail("Never overwrite corrupt evidence") } catch {}
    }

    func testExpiredAndOnceOnlyPoliciesCannotAuthorizeAutomatically() async throws {
        let (owner, cell, host, _) = await fixture()
        let offer = try await host.offer(cell: cell, requester: owner)
        XCTAssertFalse(OwnerAttachExtensionPolicy(binding: offer.binding, choice: .once,
            expiresAt: Date().addingTimeInterval(100)).applies(to: offer))
        XCTAssertFalse(OwnerAttachExtensionPolicy(binding: offer.binding, choice: .alwaysHere,
            expiresAt: Date().addingTimeInterval(-1)).applies(to: offer))
        let policy = OwnerAttachExtensionPolicy(binding: offer.binding, choice: .alwaysHere,
            expiresAt: Date().addingTimeInterval(100))
        cell.identityDomain = "another-domain"
        let otherDomain = try await host.offer(cell: cell, requester: owner)
        XCTAssertFalse(policy.applies(to: otherDomain))
        let receiver = await vault.makeIdentity(displayName: "Test receiver")
        let rotatedHost = OwnerAttachEntityExtensionHost(receiver: receiver, label: "Test receiver", store: Store())
        let otherReceiver = try await rotatedHost.offer(cell: cell, requester: owner)
        XCTAssertFalse(policy.applies(to: otherReceiver))
    }

    func testNeverPolicySurvivesClientRestartWithoutSavingPresence() async throws {
        let (owner, cell, host, store) = await fixture()
        await OwnerAttachExtensionRuntime.shared.install(host)
        let clientStore = Store()
        let first = OwnerAttachEntityExtensionClient(store: clientStore)
        _ = try await first.consider(emitter: cell, activeHuman: owner, requester: owner,
            stillAttached: { true }, review: { _ in .neverHere })
        let offer = try await host.offer(cell: cell, requester: owner)
        let firstData = await clientStore.read(id: offer.binding.storageID)!
        let firstRecord = try OwnerAttachWire.decode(OwnerAttachExtensionClientRecord.self, data: firstData)
        let later = Date().addingTimeInterval(30)
        let second = OwnerAttachEntityExtensionClient(store: clientStore, clock: { later })
        _ = try await second.consider(emitter: cell, activeHuman: owner, requester: owner,
            stillAttached: { true }, review: { _ in XCTFail("Stored never policy must not prompt"); return .once })
        let secondData = await clientStore.read(id: offer.binding.storageID)!
        let secondRecord = try OwnerAttachWire.decode(OwnerAttachExtensionClientRecord.self, data: secondData)
        XCTAssertEqual(firstRecord.policy?.expiresAt, secondRecord.policy?.expiresAt)
        let writes = await store.writes; XCTAssertEqual(writes, 0)
        await OwnerAttachExtensionRuntime.shared.install(nil)
    }
}
