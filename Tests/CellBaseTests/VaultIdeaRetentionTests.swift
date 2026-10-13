// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import XCTest
@testable import CellBase

final class VaultIdeaRetentionTests: XCTestCase {
    let day = VaultIdeaRetention.dayMs

    func testExpiryGivesFullWeekOfQuarantineEvenAfterDowntime() throws {
        var policy = VaultIdeaRetention()
        policy.enroll(id: "idea", now: 0)
        XCTAssertEqual(policy.records["idea"]?.expiresAtEpochMs, 7 * day)
        XCTAssertEqual(policy.sweep(now: 30 * day, existingIDs: ["idea", "legacy"], linkedIDs: []), [])
        XCTAssertEqual(policy.records["idea"]?.quarantinedAtEpochMs, 30 * day)
        XCTAssertNil(policy.records["legacy"])
        XCTAssertEqual(policy.sweep(now: 37 * day - 1, existingIDs: ["idea"], linkedIDs: []), [])
        XCTAssertEqual(policy.sweep(now: 37 * day, existingIDs: ["idea"], linkedIDs: []), ["idea"])
        XCTAssertEqual(policy.sweep(now: 38 * day, existingIDs: [], linkedIDs: []), [])
        policy.enroll(id: "idea", now: 40 * day)
        XCTAssertNil(policy.records["idea"], "A tombstoned ID cannot be recreated by a stale client")
    }

    func testActivityExtendsOncePerDayAndInspectionDoesNotRestoreQuarantine() throws {
        var policy = VaultIdeaRetention()
        policy.enroll(id: "idea", now: 0)
        policy.touch(id: "idea", now: day)
        policy.touch(id: "idea", now: day + 1)
        XCTAssertEqual(policy.records["idea"]?.expiresAtEpochMs, 8 * day)
        _ = policy.sweep(now: 8 * day, existingIDs: ["idea"], linkedIDs: [])
        policy.touch(id: "idea", now: 9 * day)
        XCTAssertEqual(policy.records["idea"]?.quarantinedAtEpochMs, 8 * day)
        try policy.restore(id: "idea", now: 10 * day)
        XCTAssertNil(policy.records["idea"]?.quarantinedAtEpochMs)
        XCTAssertEqual(policy.records["idea"]?.expiresAtEpochMs, 17 * day)
    }

    func testDefaultAndPerIdeaTTLHaveSeparateScopesAndValidateBounds() throws {
        var policy = VaultIdeaRetention()
        policy.enroll(id: "old", now: 0)
        try policy.configure(days: 14)
        policy.enroll(id: "new", now: 0)
        XCTAssertEqual(policy.records["old"]?.ttlDays, 7)
        XCTAssertEqual(policy.records["new"]?.ttlDays, 14)
        try policy.setTTL(id: "old", days: 3, now: day)
        XCTAssertEqual(policy.records["old"]?.expiresAtEpochMs, 4 * day)
        for invalid in [-1, 0, 3651, Int.max] {
            XCTAssertThrowsError(try policy.configure(days: invalid))
            XCTAssertThrowsError(try policy.setTTL(id: "new", days: invalid, now: 0))
        }
    }

    func testDependencyProtectionIsMonotonicAndRescuesQuarantinedIdeas() throws {
        var policy = VaultIdeaRetention()
        for id in ["todo", "link"] { policy.enroll(id: id, now: 0) }
        _ = policy.sweep(now: 7 * day, existingIDs: ["todo", "link"], linkedIDs: [])
        policy.protect(id: "todo", reference: "todo:1")
        XCTAssertEqual(policy.sweep(now: 50 * day, existingIDs: ["todo", "link"], linkedIDs: ["link"]), [])
        XCTAssertNil(policy.records["todo"]?.quarantinedAtEpochMs)
        XCTAssertNil(policy.records["link"]?.quarantinedAtEpochMs)
        XCTAssertEqual(policy.sweep(now: 100 * day, existingIDs: ["todo", "link"], linkedIDs: []), [])
        let decoded = try JSONDecoder().decode(VaultIdeaRetention.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(decoded, policy)
    }
}

final class VaultIdeaRetentionCellTests: XCTestCase {
    func testOwnerLifecycleAndOutsiderDenial() async throws {
        let previous = CellBase.defaultIdentityVault
        defer { CellBase.defaultIdentityVault = previous }
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "retention-owner", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "retention-outsider", makeNewIfNotFound: true)!
        let cell = await VaultCell(owner: owner)
        let note: ValueType = .object([
            "id": .string("new-idea"), "title": .string("Keep me"), "content": .string("Body"),
            "tags": .list([.string("idea")]), "createdAtEpochMs": .integer(1), "updatedAtEpochMs": .integer(1)
        ])
        _ = try await cell.set(keypath: "vault.note.create", value: note, requester: owner)
        let initial = try await cell.get(keypath: "vault.retention.state", requester: owner)
        let policy = try JSONDecoder().decode(VaultIdeaRetention.self, from: JSONEncoder().encode(initial))
        XCTAssertEqual(policy.records["new-idea"]?.ttlDays, 7)
        _ = try? await cell.set(keypath: "vault.note.retention.set",
            value: .object(["id": .string("new-idea"), "ttlDays": .integer(1)]), requester: outsider)
        let afterDenial = try await cell.get(keypath: "vault.retention.state", requester: owner)
        XCTAssertEqual(try JSONDecoder().decode(VaultIdeaRetention.self, from: JSONEncoder().encode(afterDenial)), policy)
        _ = try await cell.set(keypath: "vault.note.retention.protect",
            value: .object(["id": .string("new-idea"), "reference": .string("todo:1")]), requester: owner)
        let protected = try await cell.get(keypath: "vault.retention.state", requester: owner)
        XCTAssertTrue(try JSONDecoder().decode(VaultIdeaRetention.self,
            from: JSONEncoder().encode(protected)).records["new-idea"]?.isProtected == true)
        let rejected = try await cell.set(keypath: "vault.retention.sweep",
            value: .object(["checkedStateVersion": .integer(-1), "externalDependenciesChecked": .bool(true)]), requester: owner)
        guard case .object(let response)? = rejected else { return XCTFail("Expected rejection envelope") }
        XCTAssertEqual(response["status"], .string("error"))
    }
}
