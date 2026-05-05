// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class FileCryptoCellTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    func testSealGeneratesCredentialAndRoundTripsWithChaChaPoly() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await FileCryptoCell(owner: owner)

        let plaintext = Data(repeating: 0x41, count: 8_192)
        let request = FileCryptoSealRequest(
            data: plaintext,
            incomingCredentials: [],
            algorithm: .chachaPoly,
            compression: .zlib,
            associatedData: Data("file:test.bin".utf8),
            credentialMode: .generateIfMissing
        )

        guard let response = try await cell.set(
            keypath: "fileCrypto.seal",
            value: try encodeRequest(request),
            requester: owner
        ) else {
            XCTFail("Expected response payload")
            return
        }

        let sealResponse = try decodeResponse(from: response, as: FileCryptoSealResponse.self)
        XCTAssertTrue(sealResponse.credentialWasGenerated)
        XCTAssertEqual(sealResponse.newCredentials.count, 1)
        XCTAssertLessThan(sealResponse.compressedByteCount, sealResponse.originalByteCount)

        let reopened = try FileCryptoUtility.open(
            encryptedData: sealResponse.encryptedData,
            credentials: sealResponse.newCredentials
        )
        XCTAssertEqual(reopened, plaintext)
    }

    func testSealReusesIncomingCredentialWhenRequested() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await FileCryptoCell(owner: owner)

        let plaintext = Data("Reusable symmetric credential".utf8)
        let credential = FileCryptoCredential(
            id: "credential-1",
            algorithm: .chachaPoly,
            keyMaterial: Data(repeating: 0x13, count: 32),
            createdAtEpochMs: 1_700_000_000_000
        )
        let request = FileCryptoSealRequest(
            data: plaintext,
            incomingCredentials: [credential],
            algorithm: .chachaPoly,
            compression: .zlib,
            associatedData: Data("doc:123".utf8),
            credentialMode: .reuseIncoming,
            preferredCredentialID: "credential-1"
        )

        guard let response = try await cell.set(
            keypath: "fileCrypto.seal",
            value: try encodeRequest(request),
            requester: owner
        ) else {
            XCTFail("Expected response payload")
            return
        }

        let sealResponse = try decodeResponse(from: response, as: FileCryptoSealResponse.self)
        XCTAssertFalse(sealResponse.credentialWasGenerated)
        XCTAssertEqual(sealResponse.newCredentials, [])
        XCTAssertEqual(sealResponse.resolvedCredentialID, credential.id)

        let reopened = try FileCryptoUtility.open(
            encryptedData: sealResponse.encryptedData,
            credentials: [credential]
        )
        XCTAssertEqual(reopened, plaintext)
    }

    func testSealReturnsStructuredErrorWhenIncomingCredentialIsRequiredButMissing() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await FileCryptoCell(owner: owner)

        let request = FileCryptoSealRequest(
            data: Data("No credential available".utf8),
            incomingCredentials: [],
            algorithm: .chachaPoly,
            compression: .zlib,
            credentialMode: .reuseIncoming
        )

        guard let response = try await cell.set(
            keypath: "fileCrypto.seal",
            value: try encodeRequest(request),
            requester: owner
        ) else {
            XCTFail("Expected response payload")
            return
        }

        guard case let .object(object) = response else {
            XCTFail("Expected object response")
            return
        }

        XCTAssertEqual(object["status"], .string("error"))
        XCTAssertEqual(object["code"], .string("credential_missing"))

        guard case let .list(fieldErrors)? = object["field_errors"] else {
            XCTFail("Expected field_errors list")
            return
        }

        let fields = fieldErrors.compactMap { entry -> String? in
            guard case let .object(errorObject) = entry,
                  case let .string(field)? = errorObject["field"] else {
                return nil
            }
            return field
        }

        XCTAssertTrue(fields.contains("incomingCredentials"))
    }

    func testOpenRoundTripsThroughCellResponse() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await FileCryptoCell(owner: owner)

        let plaintext = Data("Round trip via fileCrypto.open".utf8)
        let sealRequest = FileCryptoSealRequest(
            data: plaintext,
            algorithm: .chachaPoly,
            compression: .zlib,
            associatedData: Data("asset:open-roundtrip".utf8),
            credentialMode: .generateIfMissing
        )

        guard let sealValue = try await cell.set(
            keypath: "fileCrypto.seal",
            value: try encodeRequest(sealRequest),
            requester: owner
        ) else {
            XCTFail("Expected seal response payload")
            return
        }

        let sealResponse = try decodeResponse(from: sealValue, as: FileCryptoSealResponse.self)
        let openRequest = FileCryptoOpenRequest(
            encryptedData: sealResponse.encryptedData,
            incomingCredentials: sealResponse.newCredentials
        )

        guard let openValue = try await cell.set(
            keypath: "fileCrypto.open",
            value: try encodeRequest(openRequest),
            requester: owner
        ) else {
            XCTFail("Expected open response payload")
            return
        }

        let openResponse = try decodeResponse(from: openValue, as: FileCryptoOpenResponse.self)
        XCTAssertEqual(openResponse.decryptedData, plaintext)
        XCTAssertEqual(openResponse.resolvedCredentialID, sealResponse.resolvedCredentialID)
        XCTAssertEqual(openResponse.envelope, sealResponse.envelope)
    }

    func testOpenReturnsStructuredErrorWhenCredentialIsMissing() async throws {
        let encryptedData = try FileCryptoUtility.seal(
            request: FileCryptoSealRequest(
                data: Data("Open without credentials".utf8),
                algorithm: .chachaPoly,
                compression: .zlib,
                credentialMode: .generateNew
            )
        ).encryptedData

        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await FileCryptoCell(owner: owner)

        guard let response = try await cell.set(
            keypath: "fileCrypto.open",
            value: try encodeRequest(
                FileCryptoOpenRequest(
                    encryptedData: encryptedData,
                    incomingCredentials: []
                )
            ),
            requester: owner
        ) else {
            XCTFail("Expected response payload")
            return
        }

        guard case let .object(object) = response else {
            XCTFail("Expected object response")
            return
        }

        XCTAssertEqual(object["status"], .string("error"))
        XCTAssertEqual(object["code"], .string("credential_missing"))
        XCTAssertEqual(object["operation"], .string("fileCrypto.open"))
    }

    func testExploreContractsAdvertiseSealAndOpenSchemas() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "other", makeNewIfNotFound: true)!
        let cell = await FileCryptoCell(owner: owner)

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "fileCrypto.seal",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertPermissions(
            on: cell,
            key: "fileCrypto.open",
            requester: owner,
            expected: ["-w--"]
        )
        try await CellContractHarness.assertSetDenied(
            on: cell,
            key: "fileCrypto.seal",
            input: .object([:]),
            requester: outsider
        )
    }

    private func encodeRequest<T: Encodable>(_ request: T) throws -> ValueType {
        let data = try JSONEncoder().encode(request)
        return try JSONDecoder().decode(ValueType.self, from: data)
    }

    private func decodeResponse<T: Decodable>(from response: ValueType, as type: T.Type = T.self) throws -> T {
        guard case let .object(root) = response,
              case let .object(result)? = root["result"] else {
            throw NSError(domain: "FileCryptoCellTests", code: 1)
        }
        return try FileCryptoCellCodec.decode(.object(result), as: type)
    }
}
