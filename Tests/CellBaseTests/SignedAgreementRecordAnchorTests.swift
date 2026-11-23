// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase
@testable import CellApple
#if canImport(CellVapor)
@testable import CellVapor
#endif

/// Reads what the EntityAnchor commit flow actually stores in
/// `signedAgreementEntity` into the Swift model and back, without loss, for
/// both anchors (Kjetil 2026-11-23: the model follows storage).
final class SignedAgreementRecordAnchorTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousDocumentRoot: String?
    private var previousMasterKey: Data?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousDocumentRoot = CellBase.documentRootPath
        previousMasterKey = CellBase.persistedCellMasterKey
        CellBase.persistedCellMasterKey = Data(repeating: 0x73, count: 32)
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.documentRootPath = previousDocumentRoot
        CellBase.persistedCellMasterKey = previousMasterKey
        super.tearDown()
    }

    /// ValueType's `==` is false for any two objects or lists, so compare bytes.
    private func bytes(_ object: Object) throws -> Data {
        try SignedAgreementEntitySupport.canonicalData(object)
    }

    private func bytes(_ value: ValueType?) throws -> Data {
        try SignedAgreementEntitySupport.canonicalData(try XCTUnwrap(value))
    }

    private func owner(suffix: String) async throws -> Identity {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellprotocol-agreement-records-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let identity = await vault.identity(for: "private", makeNewIfNotFound: true)
        return try XCTUnwrap(identity)
    }

    private func contractObject(named name: String, owner: Identity) async throws -> (uuid: String, object: Object) {
        let agreement = Agreement(owner: owner)
        agreement.name = name
        agreement.conditions = []
        agreement.grants = [Grant(keypath: "document.body", permission: "r---")]
        let contract = try await Contract.ownerSignedSnapshot(
            agreement: agreement,
            signer: owner,
            domain: SignedAgreementEntitySupport.ownerEntityDomain(for: owner)
        )
        return (contract.uuid, try SignedAgreementEntitySupport.contractObject(contract))
    }

    /// Commits two contracts through `set`, reads `signedAgreementEntity` through
    /// `get`, and checks the model against the stored objects.
    private func assertStoredRecordsRoundTrip(
        owner: Identity,
        set: (String, ValueType) async throws -> ValueType?,
        get: (String) async throws -> ValueType
    ) async throws {
        let first = try await contractObject(named: "Første avtale", owner: owner)
        let second = try await contractObject(named: "Andre avtale", owner: owner)
        var receiptHashes: [String: String] = [:]
        for (contract, purpose) in [(first, "vise grunnprofil"), (second, "slippe inn")] {
            let result = try await set("signedAgreementEntity.commit", .object([
                "contract": .object(contract.object),
                "metadata": .object([
                    "templateTitle": .string("Mal"),
                    "counterparty": .string("Deltaker"),
                    "purpose": .string(purpose),
                    "dataPointer": .string("person.displayName"),
                    "durationDays": .integer(30),
                ]),
            ]))
            guard case let .object(commit)? = result, commit["status"] == .string("persisted"),
                  case let .object(receiptObject)? = commit["receipt"] else {
                return XCTFail("commit failed: \(String(describing: result))")
            }
            receiptHashes[contract.uuid] = try SignedAgreementEntityCommitReceipt.from(object: receiptObject).recordHash
        }

        guard case let .object(storedRoot) = try await get("signedAgreementEntity"),
              case let .object(storedRecords)? = storedRoot["records"] else {
            return XCTFail("signedAgreementEntity.records is not an object")
        }
        let model = try SignedAgreementEntity(object: storedRoot)

        // Keyed by contract uuid, chained in commit order.
        XCTAssertEqual(Set(model.records.keys), [first.uuid, second.uuid])
        XCTAssertEqual(model.orderedRecords.map(\.id), [first.uuid, second.uuid])
        XCTAssertEqual(model.orderedRecords.map(\.sequence), [1, 2])
        XCTAssertEqual(try SignedAgreementEntitySupport.verifyChain(storedRecords).map(\.id), [first.uuid, second.uuid])

        // Lossless: every record re-encodes to the stored object and the hash the receipt signed.
        for (id, value) in storedRecords {
            guard case let .object(stored) = value else { return XCTFail("record \(id) is not an object") }
            let record = try XCTUnwrap(model.records[id])
            XCTAssertEqual(try bytes(record.asObject()), try bytes(stored), "\(id): model changed the stored record")
            XCTAssertEqual(try SignedAgreementEntitySupport.recordHash(record.asObject()), receiptHashes[id])
            XCTAssertTrue(record.committedAt.hasSuffix("Z") && record.committedAt.contains("."), record.committedAt)
            XCTAssertNoThrow(try record.decodedContract())
        }
        XCTAssertEqual(try bytes(model.asObject()["records"]), try bytes(.object(storedRecords)))

        // Codable goes through the same stored form.
        let decoded = try JSONDecoder().decode(SignedAgreementEntity.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(try bytes(decoded.asObject()["records"]), try bytes(.object(storedRecords)))

        let refs = model.agreementRefs()
        XCTAssertEqual(refs.map(\.label), ["Første avtale", "Andre avtale"])
        XCTAssertEqual(refs.map(\.purpose), ["vise grunnprofil", "slippe inn"])
        XCTAssertEqual(refs.first?.counterparty, "Deltaker")
        XCTAssertEqual(refs.first?.dataPointer, "person.displayName")
        XCTAssertEqual(refs.first?.recordState, .signed)
        XCTAssertNotNil(refs.first?.savedAt)
        XCTAssertEqual(refs.first?.recordKeypath, "signedAgreementEntity.records.\(first.uuid)")
    }

    func testAppleEntityAnchorStoredRecordsMatchTheModel() async throws {
        let owner = try await owner(suffix: "apple")
        let entity = await CellApple.EntityAnchorCell(owner: owner)
        try await assertStoredRecordsRoundTrip(
            owner: owner,
            set: { try await entity.set(keypath: $0, value: $1, requester: owner) },
            get: { try await entity.get(keypath: $0, requester: owner) }
        )
    }

    #if canImport(CellVapor)
    func testVaporEntityAnchorStoredRecordsMatchTheModel() async throws {
        let owner = try await owner(suffix: "vapor")
        let entity = await CellVapor.EntityAnchorCell(owner: owner)
        try await assertStoredRecordsRoundTrip(
            owner: owner,
            set: { try await entity.set(keypath: $0, value: $1, requester: owner) },
            get: { try await entity.get(keypath: $0, requester: owner) }
        )
    }
    #endif
}
