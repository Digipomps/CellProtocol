// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

/// A language model as a participant in a chat (PDD_modell-i-felles-chat_2026-11-15).
/// Every test goes through the chat's keys and its Agreement, as a client would.
final class ChatModelParticipantTests: XCTestCase {
    private var previousDebugFlag = false

    override func setUp() {
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() {
        CellBase.debugValidateAccessForEverything = previousDebugFlag
    }

    private struct Room {
        let owner: Identity
        let sara: Identity
        let ola: Identity
        let model: Identity
        let stranger: Identity
        let cell: ChatCell
    }

    /// A chat with the `member` condition and two accepted guests, each holding a signed contract.
    private func makeRoom() async throws -> Room {
        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "Kjetil", makeNewIfNotFound: true)!
        let sara = await vault.identity(for: "Sara", makeNewIfNotFound: true)!
        let ola = await vault.identity(for: "Ola", makeNewIfNotFound: true)!
        let model = await vault.identity(for: "Språkmodell", makeNewIfNotFound: true)!
        let stranger = await vault.identity(for: "Fremmed", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)
        _ = try await cell.set(keypath: "audience.admissionConditions", value: .list([.string("member")]), requester: owner)
        _ = try await cell.set(keypath: "audience.inviteIdentities", value: .list([.identity(sara.publicIdentitySnapshot()), .identity(ola.publicIdentitySnapshot())]), requester: owner)
        _ = try await cell.set(keypath: "audience.acceptInvites", value: .list([.string(sara.uuid), .string(ola.uuid)]), requester: owner)
        for guest in [sara, ola] {
            let state = await cell.addAgreement(try await request(from: cell, requester: guest), for: guest)
            XCTAssertEqual(state, .signed, "\(guest.displayName) should be admitted")
        }
        return Room(owner: owner, sara: sara, ola: ola, model: model, stranger: stranger, cell: cell)
    }

    private func request(from cell: ChatCell, requester: Identity) async throws -> Agreement {
        let advertised = try await cell.advertise(for: requester)
        let data = try JSONEncoder().encode(advertised)
        return try JSONDecoder().decode(AnyCell.self, from: data).agreementTemplate
    }

    private func object(_ value: ValueType?, file: StaticString = #filePath, line: UInt = #line) throws -> Object {
        guard case let .object(object)? = value else {
            XCTFail("expected object, got \(String(describing: value))", file: file, line: line)
            throw XCTSkip("not an object")
        }
        return object
    }

    private func modelState(_ room: Room, as requester: Identity) async throws -> Object {
        try object(try await room.cell.get(keypath: "model.state", requester: requester))
    }

    private func propose(_ room: Room, by member: Identity, external: Bool = false) async throws -> Object {
        try object(try await room.cell.set(keypath: "model.propose", value: .object([
            "identity": .identity(room.model.publicIdentitySnapshot()),
            "displayName": .string("Språkmodell"),
            "external": .bool(external)
        ]), requester: member))
    }

    private func consent(_ room: Room, by member: Identity, external: Bool = false) async throws -> Object {
        try object(try await room.cell.set(keypath: "model.consent", value: .object(["external": .bool(external)]), requester: member))
    }

    private func admitModel(_ room: Room) async throws -> AgreementState {
        await room.cell.addAgreement(try await request(from: room.cell, requester: room.model), for: room.model)
    }

    private func activate(_ room: Room, external: Bool = false) async throws {
        _ = try await propose(room, by: room.ola, external: external)
        _ = try await consent(room, by: room.sara, external: external)
        _ = try await consent(room, by: room.owner, external: external)
        let state = try await admitModel(room)
        XCTAssertEqual(state, .signed)
    }

    private func send(_ room: Room, _ text: String, as member: Identity) async throws -> String {
        let sent = try object(try await room.cell.set(keypath: "sendMessage", value: .string(text), requester: member))
        let message = try object(sent["message"])
        guard case let .string(id)? = message["id"] else { throw XCTSkip("no id") }
        return id
    }

    private func messages(_ room: Room, as member: Identity) async throws -> [Object] {
        guard case let .list(list) = try await room.cell.get(keypath: "messages", requester: member) else { return [] }
        return list.compactMap { if case let .object(o) = $0 { return o } else { return nil } }
    }

    /// A denial comes back as the string "denied" from the handler, or as a
    /// thrown denial from the dispatch check when there is no contract at all.
    private func isDenied(_ operation: () async throws -> ValueType?) async -> Bool {
        do {
            return try await operation() == .string("denied")
        } catch {
            return "\(error)".contains("denied")
        }
    }

    // MARK: test.modellchat.alle-maa-si-ja

    func testModelComesInOnlyWhenEveryMemberHasSaidYes() async throws {
        let room = try await makeRoom()
        let proposed = try await propose(room, by: room.ola)
        XCTAssertEqual(proposed["status"], .string("ok"))
        var state = try await modelState(room, as: room.sara)
        XCTAssertEqual(state["hasProposal"], .bool(true))
        XCTAssertEqual(state["awaitingMe"], .bool(true))
        XCTAssertEqual(state["consentedCount"], .integer(1))
        XCTAssertEqual(state["memberCount"], .integer(3))

        _ = try await consent(room, by: room.sara)
        // Two of three: the model is not admitted and cannot read.
        let early = try await admitModel(room)
        XCTAssertEqual(early, .rejected)
        let holdsEarly = try await room.cell.get(keypath: "audience.admission.modelConsent", requester: room.model)
        XCTAssertEqual(holdsEarly, .bool(false))

        _ = try await consent(room, by: room.owner)
        state = try await modelState(room, as: room.sara)
        XCTAssertEqual(state["isActive"], .bool(true))
        XCTAssertEqual(state["status"], .string("active"))
        let admitted = try await admitModel(room)
        XCTAssertEqual(admitted, .signed)
        let holds = try await room.cell.get(keypath: "audience.admission.modelConsent", requester: room.model)
        XCTAssertEqual(holds, .bool(true))
        // The condition answers only for the requester.
        let forSara = try await room.cell.get(keypath: "audience.admission.modelConsent", requester: room.sara)
        XCTAssertEqual(forSara, .bool(false))
    }

    func testANewMemberAfterActivationKeepsTheModelButNotExternalRoutes() async throws {
        let room = try await makeRoom()
        try await activate(room, external: true)
        var state = try await modelState(room, as: room.sara)
        XCTAssertEqual(state["externalAllowed"], .bool(true))

        _ = try await room.cell.set(keypath: "audience.inviteIdentities", value: .list([.identity(room.stranger.publicIdentitySnapshot())]), requester: room.owner)
        _ = try await room.cell.set(keypath: "audience.acceptInvites", value: .list([.string(room.stranger.uuid)]), requester: room.owner)
        let joined = await room.cell.addAgreement(try await request(from: room.cell, requester: room.stranger), for: room.stranger)
        XCTAssertEqual(joined, .signed)
        state = try await modelState(room, as: room.stranger)
        XCTAssertEqual(state["isActive"], .bool(true))
        XCTAssertEqual(state["externalAllowed"], .bool(false))
        XCTAssertEqual(state["memberCount"], .integer(4))

        _ = try await consent(room, by: room.stranger, external: true)
        state = try await modelState(room, as: room.stranger)
        XCTAssertEqual(state["externalAllowed"], .bool(true))
    }

    // MARK: test.modellchat.fjern

    func testTakingBackAYesOrRemovingTheModelEndsItsAccessAtOnce() async throws {
        let room = try await makeRoom()
        try await activate(room)
        var canRead = await room.cell.validateAccess("-w--", at: "model.context", for: room.model)
        XCTAssertTrue(canRead)

        _ = try await room.cell.set(keypath: "model.decline", value: .null, requester: room.sara)
        canRead = await room.cell.validateAccess("-w--", at: "model.context", for: room.model)
        XCTAssertFalse(canRead, "a withdrawn yes must end access without a restart")
        var state = try await modelState(room, as: room.owner)
        XCTAssertEqual(state["isActive"], .bool(false))
        // Compare lists by description (lesson.valuetype-equality-false-for-objects).
        XCTAssertEqual(String(describing: state["declinedNames"] ?? .null), String(describing: ValueType.list([.string("Sara")])))

        _ = try await consent(room, by: room.sara)
        canRead = await room.cell.validateAccess("-w--", at: "model.context", for: room.model)
        XCTAssertTrue(canRead)

        _ = try await room.cell.set(keypath: "model.remove", value: .null, requester: room.ola)
        canRead = await room.cell.validateAccess("-w--", at: "model.context", for: room.model)
        XCTAssertFalse(canRead)
        state = try await modelState(room, as: room.owner)
        XCTAssertEqual(state["status"], .string("removed"))
        XCTAssertEqual(state["canPropose"], .bool(true))
    }

    // MARK: test.modellchat.deltaker-merket, bare-naar-spurt, kontekstgrense, rute-er-spørrerens

    func testAnAnsweredAskIsAMarkedModelMessageAndOnlyItsContextIsReadable() async throws {
        let room = try await makeRoom()
        _ = try await send(room, "Skrevet før modellen kom inn", as: room.sara)
        try await activate(room)
        // Without an open ask the model reads nothing.
        let noAsk = try object(try await room.cell.set(keypath: "model.context", value: .object(["askID": .string("ask-none")]), requester: room.model))
        XCTAssertEqual(noAsk["code"], .string("no_open_ask"))
        // The model cannot read the chat or write as a person.
        let messagesForModel = try await room.cell.get(keypath: "messages", requester: room.model)
        XCTAssertEqual(messagesForModel, .string("denied"))
        let sendAsModel = try await room.cell.set(keypath: "sendMessage", value: .string("hei"), requester: room.model)
        XCTAssertEqual(sendAsModel, .string("denied"))

        for index in 1 ... 24 {
            _ = try await send(room, "melding \(index)", as: index.isMultiple(of: 2) ? room.sara : room.ola)
        }
        let questionID = try await send(room, "@modell Hva bør vi velge?", as: room.ola)
        let opened = try object(try await room.cell.set(keypath: "model.ask", value: .object(["messageID": .string(questionID), "route": .string("local")]), requester: room.ola))
        XCTAssertEqual(opened["status"], .string("open"))
        let ask = try object(opened["ask"])
        XCTAssertEqual(ask["contextCount"], .integer(20))
        guard case let .string(askID)? = ask["askID"] else { return XCTFail("no ask id") }

        let context = try object(try await room.cell.set(keypath: "model.context", value: .object(["askID": .string(askID)]), requester: room.model))
        XCTAssertEqual(context["question"], .string("@modell Hva bør vi velge?"))
        guard case let .list(contextMessages)? = context["messages"] else { return XCTFail("no messages") }
        XCTAssertEqual(contextMessages.count, 20)
        let contents = contextMessages.compactMap { value -> String? in
            if case let .object(o) = value, case let .string(c)? = o["content"] { return c }
            return nil
        }
        XCTAssertFalse(contents.contains("Skrevet før modellen kom inn"))
        XCTAssertEqual(contents.last, "@modell Hva bør vi velge?")

        let answered = try object(try await room.cell.set(keypath: "model.answer", value: .object([
            "askID": .string(askID), "text": .string("Et kort skjema først."), "model": .string("qwen3-8b")
        ]), requester: room.model))
        XCTAssertEqual(answered["status"], .string("sent"))

        let all = try await messages(room, as: room.sara)
        let last = try XCTUnwrap(all.last)
        XCTAssertEqual(last["authorKind"], .string("model"))
        XCTAssertEqual(last["askedByUUID"], .string(room.ola.uuid))
        XCTAssertEqual(last["model"], .string("qwen3-8b"))
        XCTAssertEqual(last["routeClass"], .string("local"))
        XCTAssertEqual(last["contextCount"], .integer(20))
        XCTAssertEqual(last["ownerDisplayName"], .string("Språkmodell"))
        XCTAssertEqual(all.first?["authorKind"], .string("person"))

        guard case let .list(participants) = try await room.cell.get(keypath: "participants", requester: room.sara) else { return XCTFail() }
        let modelRow = participants.compactMap { value -> Object? in
            if case let .object(o) = value, o["id"] == .string(room.model.uuid) { return o }
            return nil
        }.first
        XCTAssertEqual(modelRow?["kind"], .string("model"))

        // The ask is used up.
        let again = try object(try await room.cell.set(keypath: "model.answer", value: .object(["askID": .string(askID), "text": .string("igjen")]), requester: room.model))
        XCTAssertEqual(again["code"], .string("no_open_ask"))
    }

    func testOnlyTheAskerCanAskAboutTheirOwnMessage() async throws {
        let room = try await makeRoom()
        try await activate(room)
        let questionID = try await send(room, "@modell hjelp", as: room.sara)
        let byOla = try object(try await room.cell.set(keypath: "model.ask", value: .object(["messageID": .string(questionID)]), requester: room.ola))
        XCTAssertEqual(byOla["code"], .string("not_your_message"))
        let strangerDenied = await isDenied { try await room.cell.set(keypath: "model.ask", value: .object(["messageID": .string(questionID)]), requester: room.stranger) }
        XCTAssertTrue(strangerDenied)
        let byModel = try await room.cell.set(keypath: "model.ask", value: .object(["messageID": .string(questionID)]), requester: room.model)
        XCTAssertEqual(byModel, .string("denied"))
    }

    // MARK: test.modellchat.ekstern-krever-ja

    func testExternalRouteNeedsEveryonesExternalYes() async throws {
        let room = try await makeRoom()
        try await activate(room, external: false)
        let questionID = try await send(room, "@modell hjelp", as: room.sara)
        let refused = try object(try await room.cell.set(keypath: "model.ask", value: .object(["messageID": .string(questionID), "route": .string("external")]), requester: room.sara))
        XCTAssertEqual(refused["code"], .string("external_not_allowed"))

        for member in [room.owner, room.sara, room.ola] {
            _ = try await consent(room, by: member, external: true)
        }
        let opened = try object(try await room.cell.set(keypath: "model.ask", value: .object(["messageID": .string(questionID), "route": .string("external")]), requester: room.sara))
        XCTAssertEqual(opened["status"], .string("open"))
        let ask = try object(opened["ask"])
        guard case let .string(askID)? = ask["askID"] else { return XCTFail() }

        // Someone takes back the external yes before the answer arrives: nothing is shown, the asker is told.
        _ = try await consent(room, by: room.ola, external: false)
        let late = try object(try await room.cell.set(keypath: "model.answer", value: .object(["askID": .string(askID), "text": .string("svar")]), requester: room.model))
        XCTAssertEqual(late["code"], .string("external_not_allowed"))
        let saraState = try await modelState(room, as: room.sara)
        let notice = try object(saraState["notice"])
        XCTAssertEqual(notice["code"], .string("external_not_allowed"))
    }

    // MARK: test.modellchat.feil-til-spørrer

    func testAFailedAskIsShownOnlyToTheAsker() async throws {
        let room = try await makeRoom()
        try await activate(room)
        let questionID = try await send(room, "@modell oppsummer", as: room.sara)
        let opened = try object(try await room.cell.set(keypath: "model.ask", value: .object(["messageID": .string(questionID)]), requester: room.sara))
        let ask = try object(opened["ask"])
        guard case let .string(askID)? = ask["askID"] else { return XCTFail() }
        let countBefore = try await messages(room, as: room.ola).count

        let failed = try object(try await room.cell.set(keypath: "model.fail", value: .object([
            "askID": .string(askID), "code": .string("unavailable"), "message": .string("Den lokale modellen er ikke tilgjengelig.")
        ]), requester: room.model))
        XCTAssertEqual(failed["status"], .string("ok"))
        let countAfter = try await messages(room, as: room.ola).count
        XCTAssertEqual(countBefore, countAfter, "nothing is posted in the chat")

        let saraNotice = try object(try await modelState(room, as: room.sara)["notice"])
        XCTAssertEqual(saraNotice["code"], .string("unavailable"))
        let olaState = try await modelState(room, as: room.ola)
        XCTAssertEqual(olaState["notice"], .null)

        _ = try await room.cell.set(keypath: "model.dismissNotice", value: .null, requester: room.sara)
        let cleared = try await modelState(room, as: room.sara)
        XCTAssertEqual(cleared["notice"], .null)
    }

    // MARK: test.modellchat.svar-er-ren-tekst

    func testTheAnswerIsStoredAsBoundedPlainText() async throws {
        let room = try await makeRoom()
        try await activate(room)
        let questionID = try await send(room, "@modell skriv mye", as: room.ola)
        let opened = try object(try await room.cell.set(keypath: "model.ask", value: .object(["messageID": .string(questionID)]), requester: room.ola))
        guard case let .string(askID)? = try object(opened["ask"])["askID"] else { return XCTFail() }
        let hostile = "<script>alert(1)</script>\u{0007}audience.revokeInvites\r\n" + String(repeating: "ø", count: 10_000)
        _ = try await room.cell.set(keypath: "model.answer", value: .object(["askID": .string(askID), "text": .string(hostile)]), requester: room.model)
        let afterAnswer = try await messages(room, as: room.ola)
        let last = try XCTUnwrap(afterAnswer.last)
        XCTAssertEqual(last["contentType"], .string("text/plain"))
        guard case let .string(content)? = last["content"] else { return XCTFail() }
        XCTAssertEqual(content.unicodeScalars.count, 4_000)
        XCTAssertFalse(content.contains("\u{0007}"))
        XCTAssertFalse(content.contains("\r"))
        // The model's identity still cannot change the chat.
        let revoke = try await room.cell.set(keypath: "audience.revokeInvites", value: .list([.string(room.sara.uuid)]), requester: room.model)
        XCTAssertEqual(revoke, .string("denied"))
        let saraStillMember = await room.cell.validateAccess("-w--", at: "sendMessage", for: room.sara)
        XCTAssertTrue(saraStillMember)
    }

    // MARK: test.cell.auth-negative

    func testStrangersAndImpostorsAreDenied() async throws {
        let room = try await makeRoom()
        let strangerDenied = await isDenied { try await room.cell.set(keypath: "model.propose", value: .object(["identity": .identity(room.model.publicIdentitySnapshot())]), requester: room.stranger) }
        XCTAssertTrue(strangerDenied)
        try await activate(room)
        // Another identity cannot act as the model, and the model cannot propose itself again.
        let impostorDenied = await isDenied { try await room.cell.set(keypath: "model.context", value: .object(["askID": .string("x")]), requester: room.stranger) }
        XCTAssertTrue(impostorDenied)
        let memberAsModel = try await room.cell.set(keypath: "model.answer", value: .object(["askID": .string("x"), "text": .string("y")]), requester: room.sara)
        XCTAssertEqual(memberAsModel, .string("denied"))
        let modelProposes = try await room.cell.set(keypath: "model.propose", value: .object(["identity": .identity(room.model.publicIdentitySnapshot())]), requester: room.model)
        XCTAssertEqual(modelProposes, .string("denied"))
    }

    func testTheModelStateSurvivesARestoredChat() async throws {
        let room = try await makeRoom()
        try await activate(room, external: true)
        let restored = try JSONDecoder().decode(ChatCell.self, from: JSONEncoder().encode(room.cell))
        let holds = try await restored.get(keypath: "audience.admission.modelConsent", requester: room.model)
        XCTAssertEqual(holds, .bool(true))
        let state = try object(try await restored.get(keypath: "model.state", requester: room.owner))
        XCTAssertEqual(state["externalAllowed"], .bool(true))
    }

    /// A node-hosted chat: the owner is the node, so only the invited people count and answer.
    func testANodeHostedChatCountsOnlyItsPeople() async throws {
        let room = try await makeRoom()
        let hosted = try object(try await room.cell.set(keypath: "model.ownerIsMember", value: .bool(false), requester: room.owner))
        XCTAssertEqual(hosted["ownerIsMember"], .bool(false))
        let saraDenied = await isDenied { try await room.cell.set(keypath: "model.ownerIsMember", value: .bool(true), requester: room.sara) }
        XCTAssertTrue(saraDenied)

        _ = try await propose(room, by: room.ola)
        let state = try await consent(room, by: room.sara)
        let model = try object(state["model"])
        XCTAssertEqual(model["isActive"], .bool(true), "two people said yes; the node does not count")
        XCTAssertEqual(model["memberCount"], .integer(2))
        let admitted = try await admitModel(room)
        XCTAssertEqual(admitted, .signed)
        // The node cannot answer for the people.
        let ownerDenied = await isDenied { try await room.cell.set(keypath: "model.decline", value: .null, requester: room.owner) }
        XCTAssertTrue(ownerDenied)
        let holds = try await room.cell.get(keypath: "audience.admission.modelConsent", requester: room.model)
        XCTAssertEqual(holds, .bool(true))
        // The node cannot be proposed as the model either.
        _ = try await room.cell.set(keypath: "model.remove", value: .null, requester: room.sara)
        let ownerAsModel = try object(try await room.cell.set(keypath: "model.propose", value: .object(["identity": .identity(room.owner.publicIdentitySnapshot())]), requester: room.sara))
        XCTAssertEqual(ownerAsModel["code"], .string("invalid_model"))
    }

    // MARK: Pure rules (same as the scenario fixtures)

    func testMentionDetection() {
        XCTAssertTrue(ChatModelRules.isAddressedToModel("@modell hva tenker du?"))
        XCTAssertTrue(ChatModelRules.isAddressedToModel("Hei @Modell, kan du"))
        XCTAssertTrue(ChatModelRules.isAddressedToModel("spør @model"))
        XCTAssertFalse(ChatModelRules.isAddressedToModel("@modellering er gøy"))
        XCTAssertFalse(ChatModelRules.isAddressedToModel("e-post@modell.no"))
        XCTAssertFalse(ChatModelRules.isAddressedToModel("ingen omtale"))
    }
}
