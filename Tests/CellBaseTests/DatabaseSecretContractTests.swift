import XCTest
@testable import CellBase
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class DatabaseSecretContractTests: XCTestCase {
    func testV1FileDerivationGoldenAndScopeSeparation() throws {
        let root = try SecretKeyMaterial(Data(0..<32))
        let uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let file = try DatabaseFileKeyDerivation.derive(root: root, cellUUID: uuid, filename: "graph.sqlite")
        XCTAssertEqual(file.withBytes { $0.map { String(format: "%02x", $0) }.joined() }, "cdf83c3aa070f1f0dcdd51b1e4863d24d2fabfdd26813af8b256fc1f5a253581")
        let other = try DatabaseFileKeyDerivation.derive(root: root, cellUUID: uuid, filename: "sqlite.db")
        XCTAssertFalse(file.withBytes { a in other.withBytes { a == $0 } })
        XCTAssertThrowsError(try DatabaseFileKeyDerivation.derive(root: root, cellUUID: uuid, filename: "../outside.db"))
        XCTAssertEqual(String(reflecting: root), "<secret material redacted>")
    }
    func testOwnerSealedRecordRoundTripAndRecipientSubstitutionDenial() async throws {
        let vault = await EphemeralIdentityVault().initialize()
        let resolved = await vault.identity(for: "database-contract", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(resolved)
        let context = try DatabaseSecretContext(secretID: UUID().uuidString, cellUUID: UUID().uuidString,
            ownerFingerprint: XCTUnwrap(owner.signingPublicKeyFingerprint), domain: "private", audience: UUID().uuidString)
        let primary = Curve25519.KeyAgreement.PrivateKey(), recovery = Curve25519.KeyAgreement.PrivateKey()
        let p = try SecretRecipient(publicKey: primary.publicKey.rawRepresentation)
        let r = try SecretRecipient(publicKey: recovery.publicKey.rawRepresentation)
        let record = try await DatabaseSecretCrypto.seal(.generate(), context: context, recipients: [p,r], owner: owner)
        let decoded = try JSONDecoder().decode(SealedDatabaseSecret.self, from: JSONEncoder().encode(record))
        try decoded.validate(owner: owner.publicIdentitySnapshot())
        let envelope = try XCTUnwrap(decoded.envelopes.first { $0.recipient == r })
        _ = try DatabaseSecretCrypto.open(envelope, context: context, privateKey: recovery)
        XCTAssertThrowsError(try DatabaseSecretCrypto.open(envelope, context: context, privateKey: primary))
        let request = try await DatabaseServiceRequest.signed(record: record, filename: "graph.sqlite",
            purpose: "purpose://contract.test", audience: "trusted-runtime", runtime: owner, recipient: p)
        try request.validate()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        var scope = try XCTUnwrap(object["scope"] as? [String: Any]); scope["filename"] = "other.sqlite"; object["scope"] = scope
        let tampered = try JSONDecoder().decode(DatabaseServiceRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try tampered.validate())
    }
    func testTransportRejectsUnsafeEndpoints() throws {
        for value in ["http://example.com/secrets", "https://user:password@example.com/secrets", "https://example.com/secrets?key=x", "https://example.com/secrets#ref"] {
            XCTAssertThrowsError(try HTTPSSecretCredentialTransport(endpoint: XCTUnwrap(URL(string: value))))
        }
    }
}
