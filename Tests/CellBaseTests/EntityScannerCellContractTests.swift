// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@_spi(HAVENRuntime) @testable import CellBase
@testable import CellApple

final class EntityScannerCellContractTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousDocumentRoot: String?
    private var previousExploreMode: CellBase.ExploreContractEnforcementMode = .permissive

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousDocumentRoot = CellBase.documentRootPath
        previousExploreMode = CellBase.exploreContractEnforcementMode
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.documentRootPath = previousDocumentRoot
        CellBase.exploreContractEnforcementMode = previousExploreMode
        super.tearDown()
    }

    func testEntityScannerContractsAdvertiseCapabilitiesAndContactRequest() async throws {
        CellBase.exploreContractEnforcementMode = .strict
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "other", makeNewIfNotFound: true)!
        let cell = await EntityScannerCell(owner: owner)

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "capabilities",
            requester: owner,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "requestContact",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "oneOf",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertPermissions(
            on: cell,
            key: "requestContact",
            requester: owner,
            expected: ["-w--"]
        )

        let requestContract = try await CellContractHarness.contractObject(on: cell, key: "requestContact", requester: owner)
        let declaredTopics = ExploreContract.flowEffects(from: .object(requestContract)).compactMap {
            ExploreContract.string(from: $0[ExploreContract.Field.topic])
        }
        XCTAssertTrue(declaredTopics.isEmpty, "Conditional success/error topics must not be advertised as unconditional effects")

        for action in ["start", "stop"] {
            try await CellContractHarness.assertAdvertisedKey(
                on: cell,
                key: action,
                requester: owner,
                expectedMethod: .set,
                expectedInputType: "bool"
            )
            try await CellContractHarness.assertPermissions(
                on: cell,
                key: action,
                requester: owner,
                expected: ["-w--"]
            )
        }
        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "invite",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "oneOf"
        )

        let decoded = try JSONDecoder().decode(
            EntityScannerCell.self,
            from: JSONEncoder().encode(cell)
        )
        try await assertGetIsUnavailable(on: decoded, key: "start", requester: owner)
        try await assertGetIsUnavailable(on: decoded, key: "stop", requester: owner)
        try await assertGetIsUnavailable(on: decoded, key: "invite", requester: owner)
        try await assertGetIsUnavailable(on: decoded, key: "sharedToken", requester: owner)

        try await assertSetRejectsInvalidPayload(on: decoded, key: "start", value: .string("start"), requester: owner)
        try await assertSetRejectsInvalidPayload(on: decoded, key: "stop", value: .null, requester: owner)
        try await assertSetRejectsInvalidPayload(on: decoded, key: "invite", value: .bool(true), requester: owner)
        try await assertSetRejectsInvalidPayload(on: decoded, key: "sharedToken", value: .bool(true), requester: owner)

        try await CellContractHarness.assertSetTriggersFlow(
            testCase: self,
            on: decoded,
            key: "stop",
            input: .bool(true),
            requester: owner,
            expectedTopic: "scanner"
        )

        let actionKeys = Set([
            "start",
            "stop",
            "invite",
            "requestContact",
            "acceptContact",
            "exportEncounter",
            "exportEncounterJSON",
            "sharedToken"
        ])
        let actionGrants = decoded.agreementTemplate.grants.filter { actionKeys.contains($0.keypath) }
        XCTAssertEqual(actionGrants.count, actionKeys.count)
        XCTAssertTrue(actionGrants.allSatisfy { $0.permission.permissionString == "-w--" })

        try await CellContractHarness.assertSetDenied(
            on: cell,
            key: "requestContact",
            input: .string(UUID().uuidString),
            requester: outsider
        )
    }

    func testProductionScannerConfigurationsRoundTripWithExplicitActionPayloads() async throws {
        let configurations = try await SkeletonDescriptions.menuConfigurations()
        var scannerReferenceCount = 0
        var scannerButtonCount = 0
        var productionStopPayload: ValueType?

        for configuration in configurations {
            let encoded = try JSONEncoder().encode(configuration)
            let decoded = try JSONDecoder().decode(CellConfiguration.self, from: encoded)

            for reference in decoded.cellReferences ?? [] where reference.endpoint == "cell:///EntityScanner" {
                scannerReferenceCount += 1
                let startValues = reference.setKeysAndValues.filter { $0.key == "start" }
                XCTAssertFalse(startValues.isEmpty, "\(decoded.name) must configure EntityScanner.start explicitly")
                for start in startValues {
                    XCTAssertEqual(start.value, .bool(true), "\(decoded.name) must use SET-compatible scanner.start payload")
                }
            }

            let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(decoded))
            visitJSONDictionaries(in: json) { object in
                guard let keypath = object["keypath"] as? String,
                      keypath == "scanner.start" || keypath == "scanner.stop" else {
                    return
                }
                scannerButtonCount += 1
                XCTAssertEqual(
                    object["payload"] as? Bool,
                    true,
                    "\(decoded.name) \(keypath) must retain an explicit true payload after round-trip"
                )
                if keypath == "scanner.stop", let payload = object["payload"] as? Bool {
                    productionStopPayload = .bool(payload)
                }
            }
        }

        XCTAssertGreaterThan(scannerReferenceCount, 0)
        XCTAssertGreaterThan(scannerButtonCount, 0)

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellprotocol-scanner-orchestrator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        CellBase.documentRootPath = tempRoot.path

        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerCandidate = await vault.identity(for: "private", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerCandidate)
        let orchestrator = await OrchestratorCell(owner: owner)
        let fallbackMenu = try await orchestrator.buildOutwardMenu()
        XCTAssertEqual(scannerDemoStartValue(in: fallbackMenu), .bool(true))
        let reloadedMenu = try await orchestrator.buildOutwardMenu()
        XCTAssertEqual(scannerDemoStartValue(in: reloadedMenu), .bool(true))

        let sourceCell = await EntityScannerCell(owner: owner)
        let decodedCell = try JSONDecoder().decode(
            EntityScannerCell.self,
            from: JSONEncoder().encode(sourceCell)
        )
        try await CellContractHarness.assertSetTriggersFlow(
            testCase: self,
            on: decodedCell,
            key: "stop",
            input: try XCTUnwrap(productionStopPayload),
            requester: owner,
            expectedTopic: "scanner"
        )
    }

    private func assertGetIsUnavailable(
        on cell: EntityScannerCell,
        key: String,
        requester: Identity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await cell.get(keypath: key, requester: requester)
            XCTFail("GET \(key) must not remain as an unadvertised action path", file: file, line: line)
        } catch GeneralCell.KeyValueErrors.notFound {
            return
        } catch {
            XCTFail("Expected GET \(key) to be unavailable, got \(error)", file: file, line: line)
        }
    }

    private func assertSetRejectsInvalidPayload(
        on cell: EntityScannerCell,
        key: String,
        value: ValueType,
        requester: Identity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await cell.set(keypath: key, value: value, requester: requester)
            XCTFail("SET \(key) must reject payload \(value)", file: file, line: line)
        } catch SetValueError.paramErr {
            return
        } catch {
            XCTFail("Expected SET \(key) paramErr, got \(error)", file: file, line: line)
        }
    }

    private func scannerDemoStartValue(in menu: ValueType) -> ValueType? {
        guard case let .list(configurations) = menu else {
            return nil
        }
        for value in configurations {
            guard case let .cellConfiguration(configuration) = value,
                  configuration.name == "Scanner Demo",
                  let reference = configuration.cellReferences?.first(where: {
                      $0.endpoint == "cell:///EntityScanner"
                  }) else {
                continue
            }
            return reference.setKeysAndValues.first(where: { $0.key == "start" })?.value
        }
        return nil
    }

    private func visitJSONDictionaries(in value: Any, visit: ([String: Any]) -> Void) {
        if let object = value as? [String: Any] {
            visit(object)
            for nested in object.values {
                visitJSONDictionaries(in: nested, visit: visit)
            }
        } else if let list = value as? [Any] {
            for nested in list {
                visitJSONDictionaries(in: nested, visit: visit)
            }
        }
    }
}
