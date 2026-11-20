import XCTest
@testable import CellBase

/// AP1 (PDD_kontosletting_2026-11-20): account erasure contract.
final class AccountErasureContractTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let fixedID = UUID(uuidString: "6F1D7C2A-0000-4000-8000-000000000001")!

    private func identity(_ context: String, in vault: EphemeralIdentityVault = EphemeralIdentityVault()) async throws -> Identity {
        let found = await vault.identity(for: context, makeNewIfNotFound: true)
        return try XCTUnwrap(found)
    }

    private func sortedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: request

    func testSignedRequestIsAccepted() async throws {
        let owner = try await identity("owner")
        let request = try await ErasureRequest.make(owner: owner, linkedIdentities: ["ipad-uuid"], keyChoice: .lock30,
                                                    requestID: fixedID, now: now)
        XCTAssertNoThrow(try request.verify(owner: owner))
        XCTAssertEqual(request.identities, [owner.uuid, "ipad-uuid"])
        XCTAssertEqual(request.purpose, "purpose://account.erasure")

        // Survives the wire.
        let decoded = try JSONDecoder().decode(ErasureRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
        XCTAssertNoThrow(try decoded.verify(owner: owner))
    }

    func testMissingSignatureIsRefused() async throws {
        let owner = try await identity("owner")
        let signed = try await ErasureRequest.make(owner: owner, keyChoice: .destroy, now: now)
        let unsigned = ErasureRequest(domain: signed.domain, purpose: signed.purpose, requestID: signed.requestID,
                                      ownerEntity: signed.ownerEntity, identities: signed.identities,
                                      keyChoice: signed.keyChoice, issuedAt: signed.issuedAt,
                                      signer: signed.signer, signature: Data())
        XCTAssertThrowsError(try unsigned.verify(owner: owner)) {
            XCTAssertEqual($0 as? ErasureContractError, .missingSignature)
        }
    }

    func testWrongSignatureIsRefused() async throws {
        let owner = try await identity("owner")
        let signed = try await ErasureRequest.make(owner: owner, keyChoice: .destroy, now: now)
        // Same fields, but keyChoice changed after signing.
        let tampered = ErasureRequest(domain: signed.domain, purpose: signed.purpose, requestID: signed.requestID,
                                      ownerEntity: signed.ownerEntity, identities: signed.identities,
                                      keyChoice: .lock30, issuedAt: signed.issuedAt,
                                      signer: signed.signer, signature: signed.signature)
        XCTAssertThrowsError(try tampered.verify(owner: owner)) {
            XCTAssertEqual($0 as? ErasureContractError, .invalidSignature)
        }
        var flipped = signed.signature; flipped[0] ^= 0xFF
        let badBytes = ErasureRequest(domain: signed.domain, purpose: signed.purpose, requestID: signed.requestID,
                                      ownerEntity: signed.ownerEntity, identities: signed.identities,
                                      keyChoice: signed.keyChoice, issuedAt: signed.issuedAt,
                                      signer: signed.signer, signature: flipped)
        XCTAssertThrowsError(try badBytes.verify(owner: owner)) {
            XCTAssertEqual($0 as? ErasureContractError, .invalidSignature)
        }
    }

    func testRequestFromAnotherIdentityIsRefused() async throws {
        let vault = EphemeralIdentityVault()
        let owner = try await identity("owner", in: vault)
        let stranger = try await identity("stranger", in: vault)
        // Stranger signs a valid request for themself; the holder of owner's data refuses it.
        let strangers = try await ErasureRequest.make(owner: stranger, keyChoice: .destroy, now: now)
        XCTAssertNoThrow(try strangers.verify(owner: stranger))
        XCTAssertThrowsError(try strangers.verify(owner: owner)) {
            XCTAssertEqual($0 as? ErasureContractError, .notOwner)
        }
        // Stranger claims owner's entity but signs with their own key.
        var descriptor = strangers.signer; descriptor.uuid = owner.uuid
        let forged = ErasureRequest(domain: ErasureRequest.domain, purpose: ErasureRequest.purpose, requestID: fixedID,
                                    ownerEntity: owner.uuid, identities: [owner.uuid], keyChoice: .destroy,
                                    issuedAt: now, signer: descriptor, signature: Data())
        let strangerSignature = try await stranger.sign(data: forged.signingPayload())
        let forgedSigned = ErasureRequest(domain: forged.domain, purpose: forged.purpose, requestID: forged.requestID,
                                          ownerEntity: forged.ownerEntity, identities: forged.identities,
                                          keyChoice: forged.keyChoice, issuedAt: forged.issuedAt, signer: forged.signer,
                                          signature: try XCTUnwrap(strangerSignature))
        XCTAssertThrowsError(try forgedSigned.verify(owner: owner)) {
            XCTAssertEqual($0 as? ErasureContractError, .notOwner)
        }
    }

    func testUnknownPurposeIsRefused() async throws {
        let owner = try await identity("owner")
        let signed = try await ErasureRequest.make(owner: owner, keyChoice: .destroy, now: now)
        let unknown = ErasureRequest(domain: signed.domain, purpose: "purpose://prompt.unknown", requestID: signed.requestID,
                                     ownerEntity: signed.ownerEntity, identities: signed.identities,
                                     keyChoice: signed.keyChoice, issuedAt: signed.issuedAt, signer: signed.signer,
                                     signature: Data())
        let ownerSignature = try await owner.sign(data: unknown.signingPayload())
        let resigned = ErasureRequest(domain: unknown.domain, purpose: unknown.purpose, requestID: unknown.requestID,
                                      ownerEntity: unknown.ownerEntity, identities: unknown.identities,
                                      keyChoice: unknown.keyChoice, issuedAt: unknown.issuedAt, signer: unknown.signer,
                                      signature: try XCTUnwrap(ownerSignature))
        XCTAssertThrowsError(try resigned.verify(owner: owner)) {
            XCTAssertEqual($0 as? ErasureContractError, .unknownPurpose("purpose://prompt.unknown"))
        }
    }

    // MARK: receipt

    func testReceiptIsSignedByHolderAndAnswersRequest() async throws {
        let vault = EphemeralIdentityVault()
        let owner = try await identity("owner", in: vault)
        let holder = try await identity("holder", in: vault)
        let request = try await ErasureRequest.make(owner: owner, keyChoice: .destroy, now: now)
        let receipt = try await ErasureReceipt.make(for: request, holder: "chat", removedCount: 3,
                                                    remainsWithOthers: ["peer-history"], holderIdentity: holder, now: now)
        XCTAssertNoThrow(try receipt.verify(request: request, holderIdentity: holder))
        XCTAssertThrowsError(try receipt.verify(request: request, holderIdentity: owner))
        let other = try await ErasureRequest.make(owner: owner, keyChoice: .destroy, now: now)
        XCTAssertThrowsError(try receipt.verify(request: other, holderIdentity: holder))
    }

    // MARK: holder contract

    func testInMemoryHolderRoundTrip() async throws {
        let vault = EphemeralIdentityVault()
        let owner = try await identity("owner", in: vault)
        let stranger = try await identity("stranger", in: vault)
        let holderIdentity = try await identity("holder", in: vault)
        let holder = InMemoryHolder(holderIdentity: holderIdentity)
        await holder.put(owner: owner.uuid, .object(["text": .string("hei"), "at": .integer(1)]))
        await holder.put(owner: owner.uuid, .object(["text": .string("igjen"), "at": .integer(2)]))
        await holder.put(owner: stranger.uuid, .object(["text": .string("annen"), "at": .integer(3)]))

        let rows = try await holder.inventory(owner: owner)
        XCTAssertEqual(rows, [PersonalDataInventoryRow(holder: "test.memory", kind: "note", count: 2)])

        let export = try await holder.export(owner: owner)
        let expected = PersonalDataExportPart(holder: "test.memory", ownerEntity: owner.uuid, records: [
            .object(["at": .integer(1), "text": .string("hei")]),
            .object(["at": .integer(2), "text": .string("igjen")]),
        ])
        XCTAssertEqual(try sortedJSON(export), try sortedJSON(expected))

        let expiry = try await holder.expireAfter(owner: owner, ttl: 7 * 86_400)
        XCTAssertEqual(expiry.ownerEntity, owner.uuid)

        // Stranger's request for owner's data is refused and nothing is removed.
        let strangers = try await ErasureRequest.make(owner: stranger, keyChoice: .destroy, now: now)
        let forged = ErasureRequest(domain: strangers.domain, purpose: strangers.purpose, requestID: strangers.requestID,
                                    ownerEntity: owner.uuid, identities: [owner.uuid], keyChoice: .destroy,
                                    issuedAt: now, signer: strangers.signer, signature: strangers.signature)
        do { _ = try await holder.erase(forged); XCTFail("forged request accepted") } catch {}
        let afterRefusal = try await holder.inventory(owner: owner)
        XCTAssertEqual(afterRefusal.first?.count, 2)

        let request = try await ErasureRequest.make(owner: owner, keyChoice: .destroy, now: now)
        let receipt = try await holder.erase(request)
        XCTAssertEqual(receipt.removedCount, 2)
        XCTAssertNoThrow(try receipt.verify(request: request, holderIdentity: holderIdentity))
        let ownerAfter = try await holder.inventory(owner: owner)
        let strangerAfter = try await holder.inventory(owner: stranger)
        XCTAssertEqual(ownerAfter, [])
        XCTAssertEqual(strangerAfter.first?.count, 1)
        // Idempotent: a second erase removes nothing and still answers.
        let second = try await holder.erase(request)
        XCTAssertEqual(second.removedCount, 0)
    }

    // MARK: vault

    func testDefaultVaultRefusesDestroyAndLock() async throws {
        let vault = EphemeralIdentityVault()
        let owner = try await identity("owner", in: vault)
        do { try await vault.destroyIdentity(owner); XCTFail("destroy pretended to succeed") } catch {
            XCTAssertEqual(error as? IdentityVaultLifecycleError, .notSupported)
        }
        do { try await vault.lockIdentity(owner, until: now.addingTimeInterval(30 * 86_400)); XCTFail("lock pretended to succeed") } catch {
            XCTAssertEqual(error as? IdentityVaultLifecycleError, .notSupported)
        }
        // Nothing was removed.
        let stillThere = await vault.identity(forUUID: owner.uuid)
        XCTAssertNotNil(stillThere)
    }

    // MARK: contract fixtures

    /// Writes contract fixtures when ACCOUNT_ERASURE_FIXTURE_DIR is set; otherwise only checks shapes.
    func testContractFixtureShapes() async throws {
        let vault = EphemeralIdentityVault()
        let owner = try await identity("owner", in: vault)
        let holder = try await identity("holder", in: vault)
        let request = try await ErasureRequest.make(owner: owner, linkedIdentities: ["linked-ipad"], keyChoice: .lock30,
                                                    requestID: fixedID, now: now)
        let receipt = try await ErasureReceipt.make(for: request, holder: "test.memory", removedCount: 2,
                                                    holderIdentity: holder, now: now)
        let requestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(requestObject.keys), ["domain", "purpose", "requestID", "ownerEntity", "identities",
                                                 "keyChoice", "issuedAt", "signer", "signature"])
        let receiptObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        XCTAssertEqual(Set(receiptObject.keys), ["domain", "holder", "requestID", "ownerEntity", "removedCount",
                                                 "remainsWithOthers", "at", "holderSigner", "signature"])
        if let dir = ProcessInfo.processInfo.environment["ACCOUNT_ERASURE_FIXTURE_DIR"] {
            let url = URL(fileURLWithPath: dir)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(request).write(to: url.appendingPathComponent("request.valid.json"))
            try encoder.encode(receipt).write(to: url.appendingPathComponent("receipt.valid.json"))
            try encoder.encode(owner.publicSecureKey?.compressedKey).write(to: url.appendingPathComponent("owner.publicKey.json"))
            try encoder.encode(holder.publicSecureKey?.compressedKey).write(to: url.appendingPathComponent("holder.publicKey.json"))
        }
    }
}

private actor InMemoryHolder: PersonalDataHolder {
    nonisolated let personalDataHolderID = "test.memory"
    private let holderIdentity: Identity
    private var records: [String: [ValueType]] = [:]
    private var expiries: [String: Date] = [:]

    init(holderIdentity: Identity) { self.holderIdentity = holderIdentity }

    func put(owner: String, _ value: ValueType) { records[owner, default: []].append(value) }

    func inventory(owner: Identity) async throws -> [PersonalDataInventoryRow] {
        let count = records[owner.uuid]?.count ?? 0
        return count == 0 ? [] : [PersonalDataInventoryRow(holder: personalDataHolderID, kind: "note", count: count)]
    }

    func export(owner: Identity) async throws -> PersonalDataExportPart {
        PersonalDataExportPart(holder: personalDataHolderID, ownerEntity: owner.uuid, records: records[owner.uuid] ?? [])
    }

    func erase(_ request: ErasureRequest) async throws -> ErasureReceipt {
        // The holder knows the owner only by the key it stored with the data; here the request's entity.
        guard let ownerIdentity = await holderIdentity.identityVault?.identity(forUUID: request.ownerEntity) else {
            throw ErasureContractError.notOwner
        }
        try request.verify(owner: ownerIdentity)
        let removed = records.removeValue(forKey: request.ownerEntity)?.count ?? 0
        expiries.removeValue(forKey: request.ownerEntity)
        return try await ErasureReceipt.make(for: request, holder: personalDataHolderID, removedCount: removed,
                                             holderIdentity: holderIdentity)
    }

    func expireAfter(owner: Identity, ttl: TimeInterval) async throws -> PersonalDataExpiry {
        let at = Date().addingTimeInterval(ttl)
        expiries[owner.uuid] = at
        return PersonalDataExpiry(holder: personalDataHolderID, ownerEntity: owner.uuid, expiresAt: at)
    }
}
