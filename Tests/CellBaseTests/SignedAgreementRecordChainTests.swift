// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

/// `signedAgreementEntity.records` stays keyed by contract uuid; each new record
/// carries `sequence` and `previousRecordHash` (Kjetil 2026-11-23).
final class SignedAgreementRecordChainTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private let vault = MockIdentityVault()

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        CellBase.defaultIdentityVault = vault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    private func request(vault: MockIdentityVault, metadata: Object = [:]) async throws -> SignedAgreementEntityCommitRequest {
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let subject = await vault.identity(for: "subject", makeNewIfNotFound: true)!
        let agreement = Agreement(owner: owner)
        agreement.addGrant("r---", for: "state")
        agreement.signatories.append(subject)
        agreement.state = .signed
        let contract = try await Contract.signed(agreement: agreement, issuer: owner, subject: subject, domain: "private",
                                                 issuedAt: Date(timeIntervalSince1970: 1_793_102_400))
        return SignedAgreementEntityCommitRequest(contract: contract, metadata: metadata)
    }

    /// Commits like the anchors do: read all records, prepare, store if new.
    @discardableResult
    private func commit(_ request: SignedAgreementEntityCommitRequest, into records: inout Object,
                        at date: Date = Date(timeIntervalSince1970: 1_793_102_400.25)) throws -> (record: Object, isNew: Bool) {
        let result = try SignedAgreementEntitySupport.prepareRecord(
            request: request,
            contractHash: try SignedAgreementEntitySupport.contractHash(request.contract),
            existingRecords: records,
            committedAt: date
        )
        if result.isNew { records[request.contract.uuid] = .object(result.record) }
        return result
    }

    private func chainError(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case SignedAgreementEntityCommitError.recordChainBroken = error else {
                return XCTFail("expected recordChainBroken, got \(error)", file: file, line: line)
            }
        }
    }

    func testRecordsAreKeyedByContractAndChainedInOrder() async throws {
        var records = Object()
        let first = try await request(vault: vault)
        let second = try await request(vault: vault)
        let third = try await request(vault: vault)

        let r1 = try commit(first, into: &records).record
        let r2 = try commit(second, into: &records).record
        let r3 = try commit(third, into: &records).record

        XCTAssertEqual(Set(records.keys), [first.contract.uuid, second.contract.uuid, third.contract.uuid])
        XCTAssertEqual(r1["sequence"].flatMap { if case let .integer(n) = $0 { return n } else { return nil } }, 1)
        XCTAssertNil(r1["previousRecordHash"])
        guard case let .string(link2)? = r2["previousRecordHash"], case let .string(link3)? = r3["previousRecordHash"] else {
            return XCTFail("missing links")
        }
        XCTAssertEqual(link2, try SignedAgreementEntitySupport.recordHash(r1))
        XCTAssertEqual(link3, try SignedAgreementEntitySupport.recordHash(r2))

        let chain = try SignedAgreementEntitySupport.verifyChain(records)
        XCTAssertEqual(chain.map(\.id), [first.contract.uuid, second.contract.uuid, third.contract.uuid])
        XCTAssertEqual(try SignedAgreementEntitySupport.nextLink(after: records),
                       .init(sequence: 4, previousRecordHash: try SignedAgreementEntitySupport.recordHash(r3)))
    }

    func testSameContentIsIdempotentAndDifferentContentConflicts() async throws {
        var records = Object()
        let original = try await request(vault: vault, metadata: ["note": .string("a")])
        let stored = try commit(original, into: &records)
        XCTAssertTrue(stored.isNew)

        // A retry with identical content returns the stored record and adds nothing.
        let retry = try commit(original, into: &records, at: Date(timeIntervalSince1970: 1_793_200_000))
        XCTAssertFalse(retry.isNew)
        XCTAssertEqual(try SignedAgreementEntitySupport.recordHash(retry.record),
                       try SignedAgreementEntitySupport.recordHash(stored.record))
        XCTAssertEqual(records.count, 1)

        // Same contract uuid, other content: refused, nothing changes.
        var changed = original
        changed.metadata = ["note": .string("b")]
        XCTAssertThrowsError(try commit(changed, into: &records)) { error in
            guard case SignedAgreementEntityCommitError.immutableRecordConflict = error else {
                return XCTFail("expected immutableRecordConflict, got \(error)")
            }
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try SignedAgreementEntitySupport.verifyChain(records).count, 1)
    }

    func testTamperedEarlierRecordBreaksTheChain() async throws {
        var records = Object()
        let first = try await request(vault: vault)
        try commit(first, into: &records)
        try commit(try await request(vault: vault), into: &records)

        guard case var .object(tampered)? = records[first.contract.uuid] else { return XCTFail("missing record") }
        tampered["metadata"] = .object(["note": .string("rewritten")])
        records[first.contract.uuid] = .object(tampered)

        chainError { try SignedAgreementEntitySupport.verifyChain(records) }
        // A broken chain also stops the next commit.
        let next = try await request(vault: vault)
        chainError { try commit(next, into: &records) }
    }

    func testGapsAndDuplicateSequencesAreRefused() async throws {
        var records = Object()
        let first = try await request(vault: vault)
        let second = try await request(vault: vault)
        try commit(first, into: &records)
        try commit(second, into: &records)

        var gap = records
        if case var .object(record)? = gap[second.contract.uuid] {
            record["sequence"] = .integer(3)
            gap[second.contract.uuid] = .object(record)
        }
        chainError { try SignedAgreementEntitySupport.verifyChain(gap) }

        var duplicate = records
        if case var .object(record)? = duplicate[second.contract.uuid] {
            record["sequence"] = .integer(1)
            duplicate[second.contract.uuid] = .object(record)
        }
        chainError { try SignedAgreementEntitySupport.verifyChain(duplicate) }

        var unlinked = records
        if case var .object(record)? = unlinked[second.contract.uuid] {
            record.removeValue(forKey: "previousRecordHash")
            unlinked[second.contract.uuid] = .object(record)
        }
        chainError { try SignedAgreementEntitySupport.verifyChain(unlinked) }
    }

    /// Records from before the chain have no sequence: left out, not rewritten.
    func testLegacyRecordsStayOutsideTheChain() async throws {
        let legacyRequest = try await request(vault: vault)
        let legacy = try SignedAgreementEntitySupport.recordObject(
            request: legacyRequest,
            contractHash: try SignedAgreementEntitySupport.contractHash(legacyRequest.contract))
        var records: Object = [legacyRequest.contract.uuid: .object(legacy)]

        let next = try await request(vault: vault)
        let stored = try commit(next, into: &records).record
        XCTAssertEqual(stored["sequence"].flatMap { if case let .integer(n) = $0 { return n } else { return nil } }, 1)
        XCTAssertNil(stored["previousRecordHash"])
        XCTAssertEqual(try SignedAgreementEntitySupport.verifyChain(records).map(\.id), [next.contract.uuid])
        guard case let .object(unchanged)? = records[legacyRequest.contract.uuid] else { return XCTFail("legacy record gone") }
        XCTAssertEqual(try SignedAgreementEntitySupport.recordHash(unchanged), try SignedAgreementEntitySupport.recordHash(legacy))
    }

    func testCommittedAtHasThreeFractionalDigitsTruncated() {
        XCTAssertEqual(SignedAgreementEntitySupport.committedAtString(Date(timeIntervalSince1970: 1_793_102_400)),
                       "2026-10-27T12:00:00.000Z")
        XCTAssertEqual(SignedAgreementEntitySupport.committedAtString(Date(timeIntervalSince1970: 1_793_102_400.9999)),
                       "2026-10-27T12:00:00.999Z")
        XCTAssertEqual(SignedAgreementEntitySupport.committedAtString(Date(timeIntervalSince1970: 1_793_102_400.25)),
                       "2026-10-27T12:00:00.250Z")
        XCTAssertEqual(SignedAgreementEntitySupport.committedAtString(Date(timeIntervalSince1970: -0.5)),
                       "1969-12-31T23:59:59.500Z")
    }

    /// The model reads chained and legacy records exactly as stored and writes them back unchanged.
    func testModelRoundTripsChainedAndLegacyRecordsWithoutLoss() async throws {
        let legacyRequest = try await request(vault: vault, metadata: ["counterparty": .string("Eldre")])
        var legacy = try SignedAgreementEntitySupport.recordObject(
            request: legacyRequest,
            contractHash: try SignedAgreementEntitySupport.contractHash(legacyRequest.contract))
        legacy["committedAt"] = .string("2026-10-27T12:00:00Z")   // whole seconds, as before the chain
        legacy["futureField"] = .string("kept")                    // a member this model does not know
        var records: Object = [legacyRequest.contract.uuid: .object(legacy)]
        let first = try await request(vault: vault)
        let second = try await request(vault: vault)
        try commit(first, into: &records)
        try commit(second, into: &records)

        let model = try SignedAgreementEntity(object: ["records": .object(records)])
        for (id, value) in records {
            guard case let .object(stored) = value else { return XCTFail("record \(id)") }
            let record = try XCTUnwrap(model.records[id])
            XCTAssertEqual(try bytes(record.asObject()), try bytes(stored), id)
            XCTAssertEqual(try SignedAgreementEntitySupport.recordHash(record.asObject()),
                           try SignedAgreementEntitySupport.recordHash(stored), id)
        }
        let legacyRecord = try XCTUnwrap(model.records[legacyRequest.contract.uuid])
        XCTAssertNil(legacyRecord.sequence)
        XCTAssertNil(legacyRecord.previousRecordHash)
        XCTAssertEqual(legacyRecord.additionalFields["futureField"], .string("kept"))
        XCTAssertEqual(legacyRecord.committedAtEpochSeconds, 1_793_102_400)

        XCTAssertEqual(model.orderedRecords.map(\.id), [first.contract.uuid, second.contract.uuid, legacyRequest.contract.uuid])
        XCTAssertEqual(model.agreementRefs().map(\.recordKeypath),
                       [first.contract.uuid, second.contract.uuid, legacyRequest.contract.uuid].map { "signedAgreementEntity.records.\($0)" })
        XCTAssertEqual(try bytes(model.asObject()), try bytes(["records": .object(records)]))

        let decoded = try JSONDecoder().decode(SignedAgreementEntity.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(try bytes(decoded.asObject()), try bytes(["records": .object(records)]))
    }

    /// ValueType's `==` is false for any two objects or lists, so compare bytes.
    private func bytes(_ object: Object) throws -> Data {
        try SignedAgreementEntitySupport.canonicalData(object)
    }

    func testModelRefusesARecordWithoutRequiredFields() {
        XCTAssertThrowsError(try SignedAgreementRecord(object: ["id": .string("x")])) { error in
            XCTAssertEqual(error as? SignedAgreementRecord.DecodingFailure, .missingField("recordState"))
        }
    }
}
