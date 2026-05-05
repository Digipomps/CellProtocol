// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

enum CellContractHarness {
    static func assertAdvertisedKey(
        on cell: any CellProtocol,
        key: String,
        requester: Identity,
        expectedMethod: ExploreContractMethod,
        expectedInputType: String? = nil,
        expectedReturnType: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let keys = try await cell.keys(requester: requester)
        XCTAssertTrue(keys.contains(key), "Expected keys to contain \(key), got \(keys)", file: file, line: line)

        let contract = try await contractObject(on: cell, key: key, requester: requester, file: file, line: line)
        XCTAssertEqual(
            ExploreContract.int(from: contract[ExploreContract.Field.contractVersion]),
            ExploreContract.version,
            file: file,
            line: line
        )
        XCTAssertEqual(
            ExploreContract.string(from: contract[ExploreContract.Field.key]),
            key,
            file: file,
            line: line
        )
        XCTAssertEqual(
            ExploreContract.string(from: contract[ExploreContract.Field.method]),
            expectedMethod.rawValue,
            file: file,
            line: line
        )
        XCTAssertNotNil(contract[ExploreContract.Field.input], file: file, line: line)
        XCTAssertNotNil(contract[ExploreContract.Field.returns], file: file, line: line)
        XCTAssertNotNil(contract[ExploreContract.Field.permissions], file: file, line: line)
        XCTAssertNotNil(contract[ExploreContract.Field.required], file: file, line: line)
        XCTAssertNotNil(contract[ExploreContract.Field.flowEffects], file: file, line: line)
        XCTAssertNotNil(contract[ExploreContract.Field.summary], file: file, line: line)

        if let expectedInputType {
            XCTAssertEqual(
                ExploreContract.canonicalTypeName(ExploreContract.schemaType(from: contract[ExploreContract.Field.input]) ?? "unknown"),
                ExploreContract.canonicalTypeName(expectedInputType),
                file: file,
                line: line
            )
        }

        if let expectedReturnType {
            XCTAssertEqual(
                ExploreContract.canonicalTypeName(ExploreContract.schemaType(from: contract[ExploreContract.Field.returns]) ?? "unknown"),
                ExploreContract.canonicalTypeName(expectedReturnType),
                file: file,
                line: line
            )
        }
    }

    static func assertDescription(
        on cell: GeneralCell,
        key: String,
        requester: Identity,
        expected: ValueType,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let description = try await cell.schemaDescriptionForKey(key: key, requester: requester)
        assertValueTypeEqual(description, expected, file: file, line: line)
    }

    static func assertPermissions(
        on cell: any CellProtocol,
        key: String,
        requester: Identity,
        expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let contract = try await contractObject(on: cell, key: key, requester: requester, file: file, line: line)
        let actual = ExploreContract.list(from: contract[ExploreContract.Field.permissions])?.compactMap {
            ExploreContract.string(from: $0)
        } ?? []
        XCTAssertEqual(Set(actual), Set(expected), file: file, line: line)
    }

    static func assertGet(
        on cell: any CellProtocol,
        key: String,
        requester: Identity,
        expectedValue: ValueType,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let value = try await cell.get(keypath: key, requester: requester)
        assertValueTypeEqual(value, expectedValue, file: file, line: line)
    }

    static func assertSet(
        on cell: any CellProtocol,
        key: String,
        input: ValueType,
        requester: Identity,
        expectedResponse: ValueType?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let response = try await cell.set(keypath: key, value: input, requester: requester)
        assertValueTypeEqual(response, expectedResponse, file: file, line: line)
    }

    static func assertGetDenied(
        on cell: any CellProtocol,
        key: String,
        requester: Identity,
        expectedResponse: ValueType = .string("denied"),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            let response = try await cell.get(keypath: key, requester: requester)
            assertValueTypeEqual(response, expectedResponse, file: file, line: line)
        } catch let error as GeneralCell.KeyValueErrors {
            guard case .denied = error else {
                XCTFail("Expected denied error, got \(error)", file: file, line: line)
                return
            }
        }
    }

    static func assertSetDenied(
        on cell: any CellProtocol,
        key: String,
        input: ValueType,
        requester: Identity,
        expectedResponse: ValueType = .string("denied"),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            let response = try await cell.set(keypath: key, value: input, requester: requester)
            assertValueTypeEqual(response, expectedResponse, file: file, line: line)
        } catch let error as GeneralCell.KeyValueErrors {
            guard case .denied = error else {
                XCTFail("Expected denied error, got \(error)", file: file, line: line)
                return
            }
        }
    }

    static func assertSetReportsError(
        on cell: any CellProtocol,
        key: String,
        input: ValueType,
        requester: Identity,
        expectedStatus: String = "error",
        expectedOperation: String? = nil,
        expectedCode: String? = nil,
        messageContains: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let response = try await cell.set(keypath: key, value: input, requester: requester)
        try assertObjectResponseStatus(
            response,
            expectedStatus: expectedStatus,
            expectedOperation: expectedOperation,
            expectedCode: expectedCode,
            messageContains: messageContains,
            file: file,
            line: line
        )
    }

    static func assertSetTriggersFlow(
        testCase: XCTestCase,
        on cell: any CellProtocol,
        key: String,
        input: ValueType,
        requester: Identity,
        expectedTopic: String,
        minimumCount: Int = 1,
        expectedResponse: ValueType? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let contract = try await contractObject(on: cell, key: key, requester: requester, file: file, line: line)
        let declaredTopics = ExploreContract.flowEffects(from: .object(contract)).compactMap { effect in
            ExploreContract.string(from: effect[ExploreContract.Field.topic])
        }
        XCTAssertTrue(
            declaredTopics.contains(expectedTopic),
            "Expected contract for \(key) to declare flow topic \(expectedTopic), got \(declaredTopics)",
            file: file,
            line: line
        )

        let feed = try await cell.flow(requester: requester)
        let flowExpectation = testCase.expectation(description: "Expected topic \(expectedTopic)")
        flowExpectation.expectedFulfillmentCount = max(1, minimumCount)
        flowExpectation.assertForOverFulfill = false

        let lock = NSLock()
        var observedCount = 0
        let cancellable = feed.sink(
            receiveCompletion: { _ in },
            receiveValue: { flowElement in
                guard flowElement.topic == expectedTopic else {
                    return
                }
                lock.lock()
                observedCount += 1
                lock.unlock()
                flowExpectation.fulfill()
            }
        )
        defer { cancellable.cancel() }

        let response = try await cell.set(keypath: key, value: input, requester: requester)
        assertValueTypeEqual(response, expectedResponse, file: file, line: line)

        await testCase.fulfillment(of: [flowExpectation], timeout: 1.0)
        XCTAssertGreaterThanOrEqual(observedCount, minimumCount, file: file, line: line)
    }

    static func contractObject(
        on cell: any CellProtocol,
        key: String,
        requester: Identity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Object {
        let schema = try await cell.typeForKey(key: key, requester: requester)
        guard let object = ExploreContract.object(from: schema) else {
            XCTFail("Expected contract object for key \(key), got \(describe(schema))", file: file, line: line)
            return [:]
        }
        return object
    }

    static func assertObjectResponseStatus(
        _ response: ValueType?,
        expectedStatus: String,
        expectedOperation: String? = nil,
        expectedCode: String? = nil,
        messageContains: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case let .object(object)? = response else {
            XCTFail("Expected object response, got \(describe(response))", file: file, line: line)
            return
        }

        XCTAssertEqual(
            ExploreContract.string(from: object["status"]),
            expectedStatus,
            file: file,
            line: line
        )

        if let expectedOperation {
            XCTAssertEqual(
                ExploreContract.string(from: object["operation"]),
                expectedOperation,
                file: file,
                line: line
            )
        }

        if let expectedCode {
            XCTAssertEqual(
                ExploreContract.string(from: object["code"]),
                expectedCode,
                file: file,
                line: line
            )
        }

        if let messageContains {
            let message = ExploreContract.string(from: object["message"]) ?? ""
            XCTAssertTrue(
                message.contains(messageContains),
                "Expected message to contain \(messageContains), got \(message)",
                file: file,
                line: line
            )
        }
    }

    static func assertValueTypeEqual(
        _ actual: ValueType?,
        _ expected: ValueType?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (nil, nil):
            return
        case (nil, _), (_, nil):
            XCTFail("Expected \(describe(expected)), got \(describe(actual))", file: file, line: line)
        case (.null?, .null?):
            return
        case let (.string(actualValue)?, .string(expectedValue)?):
            XCTAssertEqual(actualValue, expectedValue, file: file, line: line)
        case let (.bool(actualValue)?, .bool(expectedValue)?):
            XCTAssertEqual(actualValue, expectedValue, file: file, line: line)
        case let (.number(actualValue)?, .number(expectedValue)?):
            XCTAssertEqual(actualValue, expectedValue, file: file, line: line)
        case let (.integer(actualValue)?, .integer(expectedValue)?):
            XCTAssertEqual(actualValue, expectedValue, file: file, line: line)
        case let (.float(actualValue)?, .float(expectedValue)?):
            XCTAssertEqual(actualValue, expectedValue, accuracy: 0.000_001, file: file, line: line)
        case let (.object(actualObject)?, .object(expectedObject)?):
            XCTAssertEqual(Set(actualObject.keys), Set(expectedObject.keys), file: file, line: line)
            for key in expectedObject.keys.sorted() {
                assertValueTypeEqual(actualObject[key], expectedObject[key], file: file, line: line)
            }
        case let (.list(actualList)?, .list(expectedList)?):
            XCTAssertEqual(actualList.count, expectedList.count, file: file, line: line)
            for (actualItem, expectedItem) in zip(actualList, expectedList) {
                assertValueTypeEqual(actualItem, expectedItem, file: file, line: line)
            }
        default:
            XCTFail("Expected \(describe(expected)), got \(describe(actual))", file: file, line: line)
        }
    }

    private static func describe(_ value: ValueType?) -> String {
        guard let value else {
            return "nil"
        }
        switch value {
        case .null:
            return "null"
        case let .string(string):
            return ".string(\(string))"
        case let .bool(bool):
            return ".bool(\(bool))"
        case let .number(number):
            return ".number(\(number))"
        case let .integer(int):
            return ".integer(\(int))"
        case let .float(float):
            return ".float(\(float))"
        case let .object(object):
            return ".object(\(object.keys.sorted()))"
        case let .list(list):
            return ".list(count: \(list.count))"
        default:
            return ".\(value.contractTypeName)"
        }
    }
}
