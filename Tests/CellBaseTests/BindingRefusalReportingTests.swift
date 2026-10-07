// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class BindingRefusalReportingTests: XCTestCase {
    private var previousMode: CellBase.ExploreContractEnforcementMode = .permissive
    override func setUp() {
        previousMode = CellBase.exploreContractEnforcementMode
        CellBase.exploreContractEnforcementMode = .permissive
    }
    override func tearDown() {
        CellBase.exploreContractEnforcementMode = previousMode
    }
    func owner() async throws -> Identity {
        let vault = EphemeralIdentityVault()
        let identity = await awaitIdentity(vault: vault)
        return try XCTUnwrap(identity)
    }
    // Keep vault authority in the fixture, never in a decoded descriptor.
    func awaitIdentity(vault: EphemeralIdentityVault) async -> Identity? {
        await vault.identity(for: "binding-refusal", makeNewIfNotFound: true)
    }
    func audit(_ cell: GeneralCell) async throws -> [String: Any] {
        let data = try JSONEncoder().encode(await cell.registeredKeypathAudit())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testDecodedLegacySetupReportsMissingVaultAndLogs() async throws {
        let owner = try await owner()
        let source = await RefusalFixture(owner: owner)
        let previous = CellBase.defaultIdentityVault
        CellBase.defaultIdentityVault = EphemeralIdentityVault()
        defer { CellBase.defaultIdentityVault = previous }
        let messages = RefusalLogCapture()
        let previousHandler = CellBase.diagnosticLogHandler
        CellBase.diagnosticLogHandler = { _, message in messages.append(message) }
        defer { CellBase.diagnosticLogHandler = previousHandler }
        let decoded = try JSONDecoder().decode(RefusalFixture.self, from: JSONEncoder().encode(source))
        await decoded.legacyAttempt?.value
        let result = try await audit(decoded)
        XCTAssertEqual(result["ok"] as? Bool, false)
                XCTAssertTrue(messages.snapshot().contains { $0.contains("Binding setup refused") && $0.contains("condition=identityMissingVault") && $0.contains("key=state") && $0.contains("uuid=\(decoded.uuid)") && $0.contains("requesterUUID=\(owner.uuid)") && $0.contains("cell=RefusalFixture") })
        let rows = try XCTUnwrap(result["refused"] as? [[String: Any]])
        XCTAssertTrue(rows.contains { $0["condition"] as? String == "identityMissingVault" && $0["key"] as? String == "state" })
    }
    func testDecodedRuntimeSetupReadsStateWithoutRefusals() async throws {
        let owner = try await owner()
        let previous = CellBase.defaultIdentityVault
        CellBase.defaultIdentityVault = EphemeralIdentityVault()
        defer { CellBase.defaultIdentityVault = previous }
        let source = await RuntimeRefusalFixture(owner: owner)
        let decoded = try JSONDecoder().decode(RuntimeRefusalFixture.self, from: JSONEncoder().encode(source))
        try await decoded.ensureRuntimeReady()
        let state = try await decoded.get(keypath: "state", requester: owner)
        XCTAssertEqual(state, .string("ready"))
        let result = try await audit(decoded)
        XCTAssertEqual((result["refused"] as? [Any])?.count, 0)
    }
    func testRefusalDuringInstallationMakesReadinessThrow() async throws {
        let cell = await DetachedRefusalFixture(owner: try await owner())
        do { try await cell.ensureRuntimeReady(); XCTFail("Readiness accepted refused setup") }
        catch { XCTAssertEqual(String(describing: error), "setupRefused") }
        let result = try await audit(cell)
        XCTAssertEqual(result["ok"] as? Bool, false)
    }
    func testProvenOwnerOutsideTokenStillAllowed() async throws {
        let owner = try await owner()
        let cell = await GeneralCell(owner: owner)
        await cell.addInterceptForGet(requester: owner, key: "state") { _, _ in .string("ready") }
        let state = try await cell.get(keypath: "state", requester: owner)
        XCTAssertEqual(state, .string("ready"))
        let result = try await audit(cell)
        XCTAssertEqual((result["refused"] as? [Any])?.count, 0)
    }
    func testForeignIdentityReportsNotOwnerAndConnectsNoKey() async throws {
        let cell = await GeneralCell(owner: try await owner())
        await cell.addInterceptForSet(requester: try await owner(), key: "state") { _, _, _ in nil }
        let result = try await audit(cell)
        XCTAssertEqual(result["consistent"] as? Int, 0)
        XCTAssertEqual((result["interceptOnly"] as? [Any])?.count, 0)
        XCTAssertEqual((result["declaredOnly"] as? [Any])?.count, 0)
        XCTAssertEqual(result["ok"] as? Bool, false)
        let rows = try XCTUnwrap(result["refused"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["condition"] as? String, "requesterNotOwner")
    }
}
private class RefusalFixture: GeneralCell {
    var legacyAttempt: Task<Void, Never>?
    required init(owner: Identity) async { await super.init(owner: owner) }
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        legacyAttempt = Task { [weak self] in
            guard let self else { return }
            await self.addInterceptForGet(requester: self.storedOwnerIdentity, key: "state") { _, _ in .string("ready") }
        }
    }
}
private class RuntimeRefusalFixture: GeneralCell {
    required init(owner: Identity) async { await super.init(owner: owner) }
    required init(from decoder: Decoder) throws { try super.init(from: decoder) }
    override func installCellRuntimeBindingsForAccess() async throws {
        await addInterceptForGet(requester: storedOwnerIdentity, key: "state") { _, _ in .string("ready") }
    }
}
private final class DetachedRefusalFixture: RuntimeRefusalFixture {
    override func installCellRuntimeBindingsForAccess() async throws {
        await Task.detached { [self] in
            await addInterceptForGet(requester: storedOwnerIdentity, key: "state") { _, _ in .string("must-not-install") }
        }.value
    }
}

private final class RefusalLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func append(_ message: String) { lock.lock(); defer { lock.unlock() }; messages.append(message) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return messages }
}
