// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@_spi(HAVENRuntime) @testable import CellBase
@testable import CellApple

final class LobbyCellContractTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousExploreMode: CellBase.ExploreContractEnforcementMode = .permissive

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousExploreMode = CellBase.exploreContractEnforcementMode
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.exploreContractEnforcementMode = previousExploreMode
        super.tearDown()
    }

    func testLobbyStrictContractsPersistPurposesAndRejectLegacyOrUnauthorizedMutation() async throws {
        CellBase.exploreContractEnforcementMode = .strict
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerCandidate = await vault.identity(for: "lobby-owner", makeNewIfNotFound: true)
        let outsiderCandidate = await vault.identity(for: "lobby-outsider", makeNewIfNotFound: true)
        let otherKeyOwnerCandidate = await vault.identity(for: "lobby-other-key", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerCandidate)
        let outsider = try XCTUnwrap(outsiderCandidate)
        let otherKeyOwner = try XCTUnwrap(otherKeyOwnerCandidate)
        let sameUUIDWrongKey = Identity(owner.uuid, displayName: "same UUID wrong key", identityVault: vault)
        sameUUIDWrongKey.publicSecureKey = otherKeyOwner.publicSecureKey
        let cell = await LobbyCell(owner: owner)

        try await assertContracts(on: cell, requester: owner)
        try await assertLegacyDevelopmentActionsAreUnavailable(on: cell, requester: owner)
        try await assertInvalidUpdateIsRejected(on: cell, value: .bool(true), requester: owner)
        try await assertInvalidUpdateIsRejected(
            on: cell,
            value: .object(["quality": .string("Robust runtime"), "invalid": .bool(true)]),
            requester: owner
        )

        let expected: ValueType = .object([
            "quality": .string("Robust runtime"),
            "privacy": .string("Explicit owner publication")
        ])
        let updateResult = try await cell.set(keypath: "purposes.update", value: expected, requester: owner)
        XCTAssertEqual(updateResult, .string("ok"))
        let purposesAfterUpdate = try await cell.get(keypath: "purposes", requester: owner)
        CellContractHarness.assertValueTypeEqual(purposesAfterUpdate, expected)
        try await assertInvalidUpdateIsRejected(
            on: cell,
            value: .object(["quality": .integer(1)]),
            requester: owner
        )
        let purposesAfterInvalidUpdate = try await cell.get(keypath: "purposes", requester: owner)
        CellContractHarness.assertValueTypeEqual(purposesAfterInvalidUpdate, expected)

        cell.agreementTemplate.addGrant("rw--", for: "purposes")
        cell.agreementTemplate.addGrant("rw--", for: "start")
        cell.agreementTemplate.addGrant("rw--", for: "stop")
        cell.agreementTemplate.addGrant("rw--", for: "purposes.update")
        let decoded = try JSONDecoder().decode(
            LobbyCell.self,
            from: JSONEncoder().encode(cell)
        )
        let decodedPurposes = try await decoded.get(keypath: "purposes", requester: owner)
        CellContractHarness.assertValueTypeEqual(decodedPurposes, expected)
        try await assertContracts(on: decoded, requester: owner)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try? await decoded.ensureRuntimeReady()
                }
            }
        }
        let templateGrants = decoded.agreementTemplate.grants
        XCTAssertEqual(templateGrants.filter { $0.keypath == "purposes" }.map(\.permission.permissionString), ["r---"])
        XCTAssertFalse(templateGrants.contains { ["start", "stop", "purposes.update"].contains($0.keypath) })

        for deniedRequester in [outsider, sameUUIDWrongKey] {
            try await CellContractHarness.assertSetDenied(
                on: decoded,
                key: "purposes.update",
                input: .object(["attacker": .string("must not persist")]),
                requester: deniedRequester
            )
            try await CellContractHarness.assertGetDenied(on: decoded, key: "purposes", requester: deniedRequester)
        }
        let purposesAfterDeniedUpdates = try await decoded.get(keypath: "purposes", requester: owner)
        CellContractHarness.assertValueTypeEqual(purposesAfterDeniedUpdates, expected)

        let publicReadAgreement = Agreement(owner: owner)
        publicReadAgreement.addGrant("r---", for: "purposes")
        publicReadAgreement.signatories.append(outsider)
        let agreementState = await decoded.addAgreement(
            publicReadAgreement,
            for: outsider,
            authorizedBy: owner
        )
        XCTAssertEqual(agreementState, .signed)
        let publishedPurposes = try await decoded.get(keypath: "purposes", requester: outsider)
        CellContractHarness.assertValueTypeEqual(publishedPurposes, expected)
        try await CellContractHarness.assertSetDenied(
            on: decoded,
            key: "purposes.update",
            input: .object(["attacker": .string("must not persist")]),
            requester: outsider
        )

        let actionFirstDecoded = try JSONDecoder().decode(
            LobbyCell.self,
            from: JSONEncoder().encode(decoded)
        )
        let replacement: ValueType = .object(["quality": .string("Immediate decoded action")])
        let immediateUpdate = try await actionFirstDecoded.set(
            keypath: "purposes.update",
            value: replacement,
            requester: owner
        )
        XCTAssertEqual(immediateUpdate, .string("ok"))
        let immediatelyUpdatedPurposes = try await actionFirstDecoded.get(keypath: "purposes", requester: owner)
        CellContractHarness.assertValueTypeEqual(immediatelyUpdatedPurposes, replacement)
    }

    func testEntityScannerReadsLobbyPurposesThroughRequesterAwareContract() async throws {
        CellBase.exploreContractEnforcementMode = .strict
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver
        let ownerCandidate = await vault.identity(for: "scanner-owner", makeNewIfNotFound: true)
        let outsiderCandidate = await vault.identity(for: "scanner-outsider", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerCandidate)
        let outsider = try XCTUnwrap(outsiderCandidate)
        let lobby = await LobbyCell(owner: owner)
        let scanner = await EntityScannerCell(owner: owner)
        try await resolver.registerNamedEmitCell(
            name: "Lobby",
            emitCell: lobby,
            scope: .scaffoldUnique,
            identity: owner
        )

        let payload: ValueType = .object(["quality": .string("Contract-backed discovery")])
        _ = try await lobby.set(keypath: "purposes.update", value: payload, requester: owner)
        let loadedPurposes = try await scanner.lobbyPublicPurposes(requester: owner)
        XCTAssertEqual(loadedPurposes, ["quality": "Contract-backed discovery"])
        do {
            _ = try await scanner.lobbyPublicPurposes(requester: outsider)
            XCTFail("Requester-aware Lobby loading must not turn denied reads into empty discovery data")
        } catch {
            // Expected.
        }
    }

    private func assertContracts(on cell: LobbyCell, requester: Identity) async throws {
        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "purposes",
            requester: requester,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "object"
        )
        try await CellContractHarness.assertPermissions(
            on: cell,
            key: "purposes",
            requester: requester,
            expected: ["r---"]
        )
        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "purposes.update",
            requester: requester,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "string"
        )
        try await CellContractHarness.assertPermissions(
            on: cell,
            key: "purposes.update",
            requester: requester,
            expected: ["-w--"]
        )
    }

    private func assertLegacyDevelopmentActionsAreUnavailable(
        on cell: LobbyCell,
        requester: Identity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for key in ["start", "stop"] {
            do {
                _ = try await cell.get(keypath: key, requester: requester)
                XCTFail("GET \(key) must not expose the removed development emitter", file: file, line: line)
            } catch GeneralCell.KeyValueErrors.notFound {
                // Expected.
            }
            do {
                _ = try await cell.set(keypath: key, value: .bool(true), requester: requester)
                XCTFail("SET \(key) must not expose the removed development emitter", file: file, line: line)
            } catch GeneralCell.KeyValueErrors.notFound {
                // Expected.
            }
        }
        do {
            _ = try await cell.set(keypath: "purposes", value: .object([:]), requester: requester)
            XCTFail("SET purposes must not remain as a second method for the GET key", file: file, line: line)
        } catch GeneralCell.KeyValueErrors.notFound {
            // Expected.
        }
    }

    private func assertInvalidUpdateIsRejected(
        on cell: LobbyCell,
        value: ValueType,
        requester: Identity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await cell.set(keypath: "purposes.update", value: value, requester: requester)
            XCTFail("purposes.update must reject \(value)", file: file, line: line)
        } catch SetValueError.paramErr {
            // Expected.
        }
    }
}
