import XCTest
@testable import CellBase

final class ContactInboxCellTests: XCTestCase {
    private func identity(_ label: String) async -> Identity {
        let vault = EphemeralIdentityVault()
        var identity = Identity(UUID().uuidString, displayName: label, identityVault: vault)
        await vault.addIdentity(identity: &identity, for: "private")
        return identity
    }
    private func grant(_ cell: ContactInboxCell, owner: Identity, subject: Identity) async throws -> ValueType {
        let result = try await cell.set(keypath: "agreement.issue", value: .object([
            "subject": .identity(subject.publicIdentitySnapshot()), "durationSeconds": .integer(600)
        ]), requester: owner)
        return try XCTUnwrap(result)
    }
    private func request(_ id: String, grant: ValueType? = nil) -> ValueType {
        var object: Object = ["requestID": .string(id),
            "expiresAt": .float(Date().addingTimeInterval(300).timeIntervalSince1970),
            "payload": .object(["threadID": .string("synthetic-chat"), "title": .string("Synthetic invitation")])]
        object["agreement"] = grant
        return .object(object)
    }
    private func assertDenied(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Unauthorized operation succeeded", file: file, line: line) }
        catch {}
    }
    func testIndependentCellsAndSubjectBoundPostGrants() async throws {
        XCTAssertFalse(CellBase.debugValidateAccessForEverything)
        let owner = await identity("Owner"), b = await identity("B"), c = await identity("C")
        let k1 = await ContactInboxCell(owner: owner), k2 = await ContactInboxCell(owner: owner)
        let k3 = await ContactInboxCell(owner: owner)
        XCTAssertEqual(Set([k1.uuid, k2.uuid, k3.uuid]).count, 3)
        let bGrant = try await grant(k1, owner: owner, subject: b)
        let cGrant = try await grant(k2, owner: owner, subject: c)
        let bRequest = request("b-1", grant: bGrant), cRequest = request("c-1", grant: cGrant)
        let first = try await k1.set(keypath: "contact.request", value: bRequest, requester: b)
        let second = try await k2.set(keypath: "contact.request", value: cRequest, requester: c)
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        await assertDenied { _ = try await k2.set(keypath: "contact.request", value: bRequest, requester: b) }
        await assertDenied { _ = try await k1.set(keypath: "contact.request", value: cRequest, requester: c) }
        await assertDenied { _ = try await k1.get(keypath: "state", requester: b) }
        await assertDenied { _ = try await k1.set(keypath: "settings.update", value: .object(["context": .string("quiet")]), requester: b) }
        await assertDenied { _ = try await k1.set(keypath: "contact.request", value: bRequest, requester: c) }
        _ = try await k1.get(keypath: "state", requester: owner)
        _ = try await k2.get(keypath: "state", requester: owner)
        _ = try await k3.get(keypath: "state", requester: owner)
    }
    func testRevocationSurvivesFreshDecodeAndDoesNotAffectOtherCell() async throws {
        let owner = await identity("Owner"), b = await identity("B"), c = await identity("C")
        let k1 = await ContactInboxCell(owner: owner), k2 = await ContactInboxCell(owner: owner)
        let bGrant = try await grant(k1, owner: owner, subject: b)
        let cGrant = try await grant(k2, owner: owner, subject: c)
        _ = try await k1.set(keypath: "contact.request", value: request("b-first", grant: bGrant), requester: b)
        _ = try await k2.set(keypath: "contact.request", value: request("c-first", grant: cGrant), requester: c)
        let contract = try JSONDecoder().decode(Contract.self, from: JSONEncoder().encode(bGrant))
        let revocation = try await ContractRevocation.signed(contract: contract, owner: owner)
        let value = try JSONDecoder().decode(ValueType.self, from: JSONEncoder().encode(revocation))
        _ = try await k1.set(keypath: "agreement.revoke", value: value, requester: owner)
        let restored = try JSONDecoder().decode(ContactInboxCell.self, from: JSONEncoder().encode(k1))
        XCTAssertEqual(restored.uuid, k1.uuid)
        await assertDenied { _ = try await restored.set(keypath: "contact.request", value: self.request("replay", grant: bGrant), requester: b) }
        _ = try await k2.set(keypath: "contact.request", value: request("c-next"), requester: c)
        _ = try await restored.get(keypath: "state", requester: owner)
        let renewed = try await grant(restored, owner: owner, subject: b)
        _ = try await restored.set(keypath: "contact.request", value: request("renewed-after-signed-revoke", grant: renewed), requester: b)
    }
    func testRetryReturnsSameReceiptButChangedPayloadIsRejected() async throws {
        let owner = await identity("Owner"), b = await identity("B")
        let cell = await ContactInboxCell(owner: owner)
        let signed = try await grant(cell, owner: owner, subject: b)
        let payload = request("same-request", grant: signed)
        let first = try await cell.set(keypath: "contact.request", value: payload, requester: b)
        let replay = try await cell.set(keypath: "contact.request", value: payload, requester: b)
        let firstValue = try XCTUnwrap(first), replayValue = try XCTUnwrap(replay)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(firstValue), try encoder.encode(replayValue))
        guard case var .object(changed) = payload else { return XCTFail("fixture") }
        changed["payload"] = .string("changed invitation")
        await assertDenied { _ = try await cell.set(keypath: "contact.request", value: .object(changed), requester: b) }
        _ = try await cell.set(keypath: "retire", value: .object([:]), requester: owner)
        await assertDenied { _ = try await cell.set(keypath: "contact.request", value: self.request("after-retire"), requester: b) }
    }
    func testUnusedOfferCanBeRevokedAndRegistryIsSubjectScoped() async throws {
        let owner = await identity("Owner"), b = await identity("B"), stranger = await identity("Stranger")
        let cell = await ContactInboxCell(owner: owner)
        let signed = try await grant(cell, owner: owner, subject: b)
        let received = try await cell.sharedReferences(requester: b)
        let hidden = try await cell.sharedReferences(requester: stranger)
        XCTAssertEqual(received.count, 1); XCTAssertTrue(hidden.isEmpty)
        _ = try await cell.set(keypath: "access.revoke", value: .object(["subjectUUID": .string(b.uuid)]), requester: owner)
        let restored = try JSONDecoder().decode(ContactInboxCell.self, from: JSONEncoder().encode(cell))
        let remaining = try await restored.sharedReferences(requester: b)
        XCTAssertTrue(remaining.isEmpty)
        await assertDenied { _ = try await restored.set(keypath: "contact.request", value: self.request("unused-replay", grant: signed), requester: b) }
        let newGrant = try await grant(restored, owner: owner, subject: b)
        _ = try await restored.set(keypath: "contact.request", value: request("renewed", grant: newGrant), requester: b)
    }
    func testInvalidSettingsAreAtomicAndSenderCannotRevokeSomeoneElse() async throws {
        let owner = await identity("Owner"), b = await identity("B")
        let cell = await ContactInboxCell(owner: owner)
        _ = try await cell.set(keypath: "settings.update", value: .object(["label": .string("Original")]), requester: owner)
        await assertDenied { _ = try await cell.set(keypath: "settings.update", value: .object(["label": .string("Partial"), "context": .string("invalid")]), requester: owner) }
        let state = try await cell.get(keypath: "state", requester: owner)
        guard case let .object(object) = state else { return XCTFail("No state") }
        XCTAssertEqual(object["label"], .string("Original"))
        await assertDenied { _ = try await cell.set(keypath: "access.revoke", value: .object(["subjectUUID": .string(owner.uuid)]), requester: b) }
    }

    func testExploreDeclaresRequiredContactInputAndReceipt() async throws {
        let owner = await identity("Owner"), b = await identity("B")
        let cell = await ContactInboxCell(owner: owner)
        let signed = try await grant(cell, owner: owner, subject: b)
        let valid = request("schema", grant: signed)
        XCTAssertTrue(ExploreContractValidator.validate(value: valid, against: ContactInboxCell.inputSchema("contact.request")).ok)
        guard case let .object(original) = valid else { return XCTFail("fixture") }
        for key in ["requestID", "expiresAt", "payload"] {
            var missing = original; missing.removeValue(forKey: key)
            XCTAssertFalse(ExploreContractValidator.validate(value: .object(missing), against: ContactInboxCell.inputSchema("contact.request")).ok)
        }
        let receipt = try await cell.set(keypath: "contact.request", value: valid, requester: b)
        XCTAssertTrue(ExploreContractValidator.validate(value: receipt, against: ContactInboxCell.outputSchema("contact.request")).ok)
        let snapshot = try await cell.get(keypath: "state", requester: owner)
        XCTAssertTrue(ExploreContractValidator.validate(value: snapshot, against: ContactInboxCell.outputSchema("state")).ok)
        XCTAssertTrue(ExploreContractValidator.validate(value: signed, against: ContactInboxCell.outputSchema("agreement.issue")).ok)
        for key in ["settings.update", "retire", "inbox.clear"] {
            let response = try await cell.set(keypath: key, value: .object([:]), requester: owner)
            XCTAssertTrue(ExploreContractValidator.validate(value: response, against: ContactInboxCell.outputSchema(key)).ok)
        }
    }

}
