// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

/// PDD_modell-i-felles-chat_2026-11-15, WP8: a host moves an existing
/// conversation into a chat with the same messages, authors, times and order.
final class ChatHistoryImportTests: XCTestCase {
    private var previousDebugFlag = false

    override func setUp() {
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() {
        CellBase.debugValidateAccessForEverything = previousDebugFlag
    }

    private func legacy(_ count: Int) -> ValueType {
        .object(["messages": .list((0 ..< count).map { index in
            .object([
                "id": .string("msg-\(index)"),
                "authorUUID": .string(index.isMultiple(of: 2) ? "uuid-sara" : "uuid-ola"),
                "authorDisplayName": .string(index.isMultiple(of: 2) ? "Sara" : "Ola"),
                "content": .string("melding \(index)"),
                "createdAt": .string(String(format: "2026-11-01T10:%02d:00Z", index % 60))
            ])
        })])
    }

    private func object(_ value: ValueType?) -> Object {
        if case let .object(object)? = value { return object }
        return [:]
    }

    private func isDenied(_ operation: () async throws -> ValueType?) async -> Bool {
        do {
            return try await operation() == .string("denied")
        } catch {
            return "\(error)".contains("denied")
        }
    }

    // test.modellchat.migrering
    func testImportKeepsMessagesAuthorsTimesAndOrderAndRunsAgainWithoutHarm() async throws {
        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let node = await vault.identity(for: "Node", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: node)

        let limit = object(try await cell.set(keypath: "history.limit", value: .integer(1_000), requester: node))
        XCTAssertEqual(limit["messagesLimit"], .integer(1_000))
        let first = object(try await cell.set(keypath: "history.import", value: legacy(250), requester: node))
        XCTAssertEqual(first["imported"], .integer(250))

        guard case let .list(messages) = try await cell.get(keypath: "messages", requester: node) else { return XCTFail("no messages") }
        XCTAssertEqual(messages.count, 250)
        let firstMessage = object(messages.first)
        XCTAssertEqual(firstMessage["id"], .string("msg-0"))
        XCTAssertEqual(firstMessage["ownerUUID"], .string("uuid-sara"))
        XCTAssertEqual(firstMessage["ownerDisplayName"], .string("Sara"))
        XCTAssertEqual(firstMessage["createdAt"], .string("2026-11-01T10:00:00.000Z"))
        XCTAssertEqual(firstMessage["authorKind"], .string("person"))
        XCTAssertEqual(object(messages.last)["id"], .string("msg-249"))

        let again = object(try await cell.set(keypath: "history.import", value: legacy(250), requester: node))
        XCTAssertEqual(again["imported"], .integer(0))
        XCTAssertEqual(again["messageCount"], .integer(250))

        _ = try await cell.set(keypath: "sendMessage", value: .string("ny melding"), requester: node)
        let afterNew = object(try await cell.set(keypath: "history.import", value: legacy(250), requester: node))
        XCTAssertEqual(afterNew["code"], .string("history_not_empty"))
    }

    func testOnlyTheOwnerMovesHistoryAndBadInputIsRefused() async throws {
        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let node = await vault.identity(for: "Node", makeNewIfNotFound: true)!
        let sara = await vault.identity(for: "Sara", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: node)
        _ = try await cell.set(keypath: "audience.admissionConditions", value: .list([.string("member")]), requester: node)
        _ = try await cell.set(keypath: "audience.inviteIdentities", value: .list([.identity(sara.publicIdentitySnapshot())]), requester: node)
        _ = try await cell.set(keypath: "audience.acceptInvites", value: .list([.string(sara.uuid)]), requester: node)
        let advertised = try await cell.advertise(for: sara)
        let template = try JSONDecoder().decode(AnyCell.self, from: JSONEncoder().encode(advertised)).agreementTemplate
        let signed = await cell.addAgreement(template, for: sara)
        XCTAssertEqual(signed, .signed)

        let saraImports = await isDenied { try await cell.set(keypath: "history.import", value: self.legacy(2), requester: sara) }
        XCTAssertTrue(saraImports)
        let saraLimits = await isDenied { try await cell.set(keypath: "history.limit", value: .integer(5), requester: sara) }
        XCTAssertTrue(saraLimits)

        let overLimit = object(try await cell.set(keypath: "history.import", value: legacy(201), requester: node))
        XCTAssertEqual(overLimit["code"], .string("over_limit"))
        let badLimit = object(try await cell.set(keypath: "history.limit", value: .integer(0), requester: node))
        XCTAssertEqual(badLimit["code"], .string("invalid_payload"))
        let badTime = object(try await cell.set(keypath: "history.import", value: .object(["messages": .list([.object([
            "id": .string("x"), "authorUUID": .string("u"), "content": .string("c"), "createdAt": .string("i går")
        ])])]), requester: node))
        XCTAssertEqual(badTime["code"], .string("invalid_message"))
        let duplicate = object(try await cell.set(keypath: "history.import", value: .object(["messages": .list([
            .object(["id": .string("x"), "authorUUID": .string("u"), "content": .string("a"), "createdAt": .string("2026-11-01T10:00:00Z")]),
            .object(["id": .string("x"), "authorUUID": .string("u"), "content": .string("b"), "createdAt": .string("2026-11-01T10:01:00Z")])
        ])]), requester: node))
        XCTAssertEqual(duplicate["code"], .string("duplicate_id"))
    }
}
