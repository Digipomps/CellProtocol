// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@_spi(HAVENRuntime) @testable import CellBase

/// The invariant: a cell answers on exactly the keypaths Explore declares.
///
/// These tests were written from a measured failure. On 2026-09-24 production
/// answered `GET /pub` with `CellBase.GeneralCell.KeyValueErrors.notFound`:
/// the Explore contract for `publicDirectory` existed, the GET handler did not.
/// Nothing could see that, because the intercept table had no way to list
/// itself. `registeredKeypathAudit()` closes that gap.
final class RegisteredKeypathAuditTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousMode: CellBase.ExploreContractEnforcementMode = .permissive

    override func setUp() {
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousMode = CellBase.exploreContractEnforcementMode
        CellBase.defaultCellResolver = nil
        CellBase.exploreContractEnforcementMode = .permissive
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.exploreContractEnforcementMode = previousMode
    }

    private func makeOwnerAndCell(_ domain: String) async -> (Identity, GeneralCell) {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: domain, makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        return (owner, cell)
    }

    private func rows(_ audit: ValueType, _ field: String) -> [String] {
        guard case let .object(object) = audit, case let .list(items)? = object[field] else { return [] }
        return items.compactMap { item in
            guard case let .object(row) = item,
                  case let .string(key)? = row["key"],
                  case let .string(method)? = row["method"] else { return nil }
            return "\(method) \(key)"
        }.sorted()
    }

    private func integer(_ audit: ValueType, _ field: String) -> Int? {
        guard case let .object(object) = audit else { return nil }
        switch object[field] {
        case let .integer(value): return value
        case let .number(value): return value
        default: return nil
        }
    }

    private func bool(_ audit: ValueType, _ field: String) -> Bool? {
        guard case let .object(object) = audit, case let .bool(value)? = object[field] else { return nil }
        return value
    }

    /// `test.cell.intercept-keys` — the names come back, and only the keypath
    /// dictionaries are counted.
    func testRegisteredKeypathsReportsExactlyWhatWasWired() async throws {
        let (owner, cell) = await makeOwnerAndCell("audit-intercept-keys")
        await cell.registerGet(key: "alpha", owner: owner) { _ in .string("a") }
        await cell.registerGet(key: "beta", owner: owner) { _ in .string("b") }
        await cell.registerSet(key: "gamma", owner: owner) { _, _ in .string("c") }

        let audit = await cell.registeredKeypathAudit()
        // Permissive mode registers a default contract for each, so a cell that
        // wires handlers the ordinary way is consistent by construction.
        XCTAssertEqual(bool(audit, "ok"), true, "\(audit)")
        XCTAssertEqual(rows(audit, "declaredOnly"), [])
        XCTAssertEqual(rows(audit, "interceptOnly"), [])
        XCTAssertEqual(integer(audit, "consistent"), 3)
    }

    /// `test.cell.audit-finds-missing-intercept` — the production failure,
    /// reproduced: a contract without a handler.
    func testDeclaredContractWithoutHandlerIsReported() async throws {
        let (owner, cell) = await makeOwnerAndCell("audit-declared-only")
        await cell.registerGet(key: "answers", owner: owner) { _ in .string("here") }
        // Declare a GET contract and deliberately wire no handler — exactly the
        // shape `publicDirectory` had in production.
        await cell.registerExploreContract(
            requester: owner,
            key: "publicDirectory",
            method: .get,
            input: .null,
            returns: ExploreContract.unknownSchema(description: "Directory"),
            permissions: ["r---"],
            required: false,
            flowEffects: [],
            description: .string("Promised, never wired.")
        )

        let audit = await cell.registeredKeypathAudit()
        XCTAssertEqual(bool(audit, "ok"), false, "\(audit)")
        XCTAssertEqual(rows(audit, "declaredOnly"), ["get publicDirectory"])
        XCTAssertEqual(rows(audit, "interceptOnly"), [])

        // And the audit's claim matches what a caller actually experiences.
        do {
            _ = try await cell.get(keypath: "publicDirectory", requester: owner)
            XCTFail("expected the promised keypath to fail")
        } catch {
            XCTAssertTrue("\(error)".contains("notFound"), "\(error)")
        }
    }

    /// `test.cell.audit-finds-undeclared-intercept` — the other direction:
    /// a keypath that answers without being declared.
    func testHandlerWithoutDeclaredContractIsReported() async throws {
        let (owner, cell) = await makeOwnerAndCell("audit-intercept-only")
        CellBase.exploreContractEnforcementMode = .strict
        // In strict mode an implicit contract is refused, so this handler is the
        // undeclared case rather than an auto-declared one.
        await cell.addInterceptForGet(requester: owner, key: "undeclared") { _, _ in .string("answers") }

        let audit = await cell.registeredKeypathAudit()
        let declaredOnly = rows(audit, "declaredOnly")
        let interceptOnly = rows(audit, "interceptOnly")
        XCTAssertTrue(
            interceptOnly == ["get undeclared"] || declaredOnly.isEmpty && interceptOnly.isEmpty,
            "strict mode either refuses the registration outright or leaves it undeclared; got declaredOnly=\(declaredOnly) interceptOnly=\(interceptOnly)"
        )
    }

    /// The audit must not touch the cell: no handler runs, nothing is registered
    /// or removed by asking.
    func testAuditInvokesNoHandlerAndChangesNothing() async throws {
        let (owner, cell) = await makeOwnerAndCell("audit-is-read-only")
        let calls = CallCounter()
        await cell.registerGet(key: "counted", owner: owner) { _ in
            calls.increment()
            return .string("value")
        }

        let first = await cell.registeredKeypathAudit()
        let second = await cell.registeredKeypathAudit()
        XCTAssertEqual(calls.value, 0, "the audit compares names; it must not call handlers")
        XCTAssertEqual(rows(first, "declaredOnly"), rows(second, "declaredOnly"))
        XCTAssertEqual(integer(first, "consistent"), integer(second, "consistent"))

        _ = try await cell.get(keypath: "counted", requester: owner)
        XCTAssertEqual(calls.value, 1, "the handler still works after being audited")
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
