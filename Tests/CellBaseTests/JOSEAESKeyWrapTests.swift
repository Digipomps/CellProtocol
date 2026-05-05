// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class JOSEAESKeyWrapTests: XCTestCase {
    func testWrapsAndUnwrapsRFC3394Vector() throws {
        let kek = Data(hex: "000102030405060708090A0B0C0D0E0F")
        let plaintext = Data(hex: "00112233445566778899AABBCCDDEEFF")
        let expectedCiphertext = Data(hex: "1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5")

        let ciphertext = try JOSEAESKeyWrap.wrap(plaintextKey: plaintext, using: kek)
        XCTAssertEqual(ciphertext, expectedCiphertext)
        XCTAssertEqual(try JOSEAESKeyWrap.unwrap(wrappedKey: ciphertext, using: kek), plaintext)
    }

    func testRejectsUnwrapWhenIntegrityCheckFails() throws {
        let kek = Data(hex: "000102030405060708090A0B0C0D0E0F")
        let ciphertext = Data(hex: "1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE4")

        XCTAssertThrowsError(try JOSEAESKeyWrap.unwrap(wrappedKey: ciphertext, using: kek)) { error in
            XCTAssertEqual(error as? JOSEAESKeyWrapError, .integrityCheckFailed)
        }
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            self.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
    }
}
