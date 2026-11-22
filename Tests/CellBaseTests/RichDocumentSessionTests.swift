// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// A document cell with the rules of CellScaffold `RichDocumentState.apply`:
/// one revision authority, conflict on a stale base, duplicate on a repeated
/// operation id from the same author.
private actor FakeDocumentCell {
    var revision = 0
    var sequence = 0
    var document = RichTextDelta([.insert("\n")])
    var events: [RichDocumentSnapshot.Event] = []
    var sends = 0
    var failAfterApplyOnce = false
    var offline = false
    var denied = false
    let documentId = UUID().uuidString

    func snapshot() -> RichDocumentSnapshot {
        RichDocumentSnapshot(documentId: documentId, revision: revision, sequence: sequence, ops: document.ops, events: events)
    }

    func setOffline(_ value: Bool) { offline = value }
    func setFailAfterApplyOnce() { failAfterApplyOnce = true }
    func setDenied() { denied = true }

    /// Another client's change, applied directly.
    func applyFromOtherClient(_ delta: RichTextDelta) {
        let command = RichDocumentCommand(clientId: UUID().uuidString, baseRevision: revision, kind: "delta", ops: delta.ops)
        _ = apply(command, author: "other")
    }

    func apply(_ command: RichDocumentCommand, author: String) -> String {
        if let previous = events.first(where: { $0.command.operationId == command.operationId }) {
            return previous.author == author && previous.command == command ? "duplicate" : "operationCollision"
        }
        guard command.baseRevision == revision else { return "conflict" }
        sequence += 1
        if command.kind == "delta" {
            document = document.compose(RichTextDelta(command.ops ?? []))
            revision += 1
            events.append(.init(sequence: sequence, revision: revision, author: author, command: command))
        }
        return "accepted"
    }

    func current() throws -> ValueType {
        if offline { throw URLError(.notConnectedToInternet) }
        if denied { return .string("denied") }
        return RichTextValue(encoding: snapshot())!.valueType
    }

    func send(_ value: ValueType) throws -> ValueType {
        if offline { throw URLError(.notConnectedToInternet) }
        if denied { return .string("denied") }
        sends += 1
        let data = try JSONEncoder().encode(RichTextValue(valueType: value)!)
        let command = try JSONDecoder().decode(RichDocumentCommand.self, from: data)
        let status = apply(command, author: "me")
        if failAfterApplyOnce { failAfterApplyOnce = false; throw URLError(.networkConnectionLost) }
        return .object(["status": .string(status), "current": RichTextValue(encoding: snapshot())!.valueType])
    }
}

private struct FakeTransport: RichDocumentTransport {
    let cell: FakeDocumentCell
    func current() async throws -> ValueType? { try await cell.current() }
    func send(_ command: ValueType) async throws -> ValueType? { try await cell.send(command) }
}

private final class MemoryDrafts: RichDocumentDraftStore, @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [String: RichDocumentDraft] = [:]
    func load(documentId: String) -> RichDocumentDraft? { lock.lock(); defer { lock.unlock() }; return drafts[documentId] }
    func save(_ draft: RichDocumentDraft) { lock.lock(); drafts[draft.documentId] = draft; lock.unlock() }
    func remove(documentId: String) { lock.lock(); drafts[documentId] = nil; lock.unlock() }
}

/// What an editor would show: resets and remote changes applied in order.
private final class EditorMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var shown = RichTextDelta()
    private(set) var statuses: [RichDocumentStatus] = []
    func handle(_ update: RichDocumentSessionUpdate) {
        lock.lock(); defer { lock.unlock() }
        switch update {
        case .reset(let document, _): shown = document
        case .remote(let change, _): shown = shown.compose(change)
        case .status(let status): statuses.append(status)
        case .snapshot: break
        }
    }
    func type(_ change: RichTextDelta) { lock.lock(); shown = shown.compose(change); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return shown.plainText }
}

final class RichDocumentSessionTests: XCTestCase {
    private func settle(_ session: RichDocumentSession, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await session.pendingCount == 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("session did not settle; pending \(await session.pendingCount)")
    }

    private func open(_ cell: FakeDocumentCell, drafts: RichDocumentDraftStore? = nil) async -> (RichDocumentSession, EditorMirror) {
        let session = RichDocumentSession(transport: FakeTransport(cell: cell), drafts: drafts, retryDelay: 0.01)
        let mirror = EditorMirror()
        await session.setListener { mirror.handle($0) }
        await session.refresh()
        return (session, mirror)
    }

    func testTypingReachesTheCell() async throws {
        let cell = FakeDocumentCell()
        let (session, mirror) = await open(cell)
        let change = RichTextDelta([.insert("Hei")])
        mirror.type(change)
        await session.localEdit(change)
        try await settle(session)
        let server = await cell.document.plainText
        XCTAssertEqual(server, "Hei\n")
        XCTAssertEqual(mirror.text, server)
        let status = await session.status
        XCTAssertEqual(status, .saved)
    }

    func testConflictRebasesOnTheNewerDocument() async throws {
        let cell = FakeDocumentCell()
        let (session, mirror) = await open(cell)
        // Someone else writes first; this client has not seen it.
        await cell.applyFromOtherClient(RichTextDelta([.insert("Andres. ")]))
        let mine = RichTextDelta([.insert("Mitt.")])
        mirror.type(mine)
        await session.localEdit(mine)
        try await settle(session)
        let server = await cell.document.plainText
        XCTAssertTrue(server.contains("Andres. ") && server.contains("Mitt."), server)
        XCTAssertEqual(mirror.text, server, "the editor shows exactly what the cell holds")
        let revision = await cell.revision
        XCTAssertEqual(revision, 2)
    }

    func testRetryAfterLostAnswerUsesTheSameOperation() async throws {
        let cell = FakeDocumentCell()
        let (session, mirror) = await open(cell)
        await cell.setFailAfterApplyOnce()
        let change = RichTextDelta([.insert("Én gang")])
        mirror.type(change)
        await session.localEdit(change)
        try await settle(session)
        let server = await cell.document.plainText
        XCTAssertEqual(server, "Én gang\n", "applied once, not twice")
        let sends = await cell.sends
        XCTAssertEqual(sends, 2, "the retry is the same envelope, answered duplicate")
    }

    func testRemoteChangesAreRebasedOverUnsentText() async throws {
        let cell = FakeDocumentCell()
        let (session, mirror) = await open(cell)
        await cell.setOffline(true)
        let mine = RichTextDelta([.insert("B")])
        mirror.type(mine)
        await session.localEdit(mine)
        await cell.setOffline(false)
        await cell.applyFromOtherClient(RichTextDelta([.insert("A")]))
        await session.refresh()
        try await settle(session)
        let server = await cell.document.plainText
        XCTAssertEqual(server, "AB\n")
        XCTAssertEqual(mirror.text, server)
    }

    func testUnsentTextSurvivesARestart() async throws {
        let cell = FakeDocumentCell()
        let drafts = MemoryDrafts()
        let (first, mirror) = await open(cell, drafts: drafts)
        await cell.setOffline(true)
        let change = RichTextDelta([.insert("Skrevet uten nett")])
        mirror.type(change)
        await first.localEdit(change)
        try await Task.sleep(nanoseconds: 50_000_000)
        let pending = await first.pendingCount
        XCTAssertEqual(pending, 1)
        let documentId = await cell.documentId
        XCTAssertNotNil(drafts.load(documentId: documentId), "kept on the device")

        // The app is closed; later the network is back and the document opens again.
        await first.close()
        await cell.setOffline(false)
        let (second, reopened) = await open(cell, drafts: drafts)
        XCTAssertEqual(reopened.text, "Skrevet uten nett\n", "the editor shows the draft at once")
        try await settle(second)
        let server = await cell.document.plainText
        XCTAssertEqual(server, "Skrevet uten nett\n")
        XCTAssertNil(drafts.load(documentId: documentId), "removed once confirmed")
    }

    func testDeniedMakesTheSessionReadOnly() async throws {
        let cell = FakeDocumentCell()
        await cell.setDenied()
        let (session, _) = await open(cell)
        await session.localEdit(RichTextDelta([.insert("x")]))
        let status = await session.status
        XCTAssertEqual(status, .denied)
        let sends = await cell.sends
        XCTAssertEqual(sends, 0)
    }

    func testCommentsWaitForTextAndThenSend() async throws {
        let cell = FakeDocumentCell()
        let (session, _) = await open(cell)
        await session.localEdit(RichTextDelta([.insert("Tekst")]))
        let early = await session.sendMeta(kind: "comment.add", range: .init(index: 0, length: 5), text: "Ok?")
        XCTAssertTrue(early == .waitForText || early == .accepted)
        try await settle(session)
        let later = await session.sendMeta(kind: "comment.add", range: .init(index: 0, length: 5), text: "Ok?")
        XCTAssertEqual(later, .accepted)
    }

    func testSnapshotReadsTheCellsValueShape() throws {
        let json = #"{"schema":"haven.document.v1","documentId":"d1","revision":2,"sequence":5,"ops":[{"insert":"Hei","attributes":{"bold":true}},{"insert":"\n"}],"comments":[{"id":"c","author":"a","range":{"index":0,"length":3},"text":"?","resolved":false,"detached":false}],"presence":[{"author":"a","clientId":"k","updatedAt":1.5}],"messages":[],"help":[],"onboarding":"Velkommen","events":[]}"#
        let plain = try JSONDecoder().decode(RichTextValue.self, from: Data(json.utf8))
        let snapshot = try XCTUnwrap(RichDocumentSnapshot(value: plain.valueType))
        XCTAssertEqual(snapshot.document.plainText, "Hei\n")
        XCTAssertEqual(snapshot.comments?.first?.range, .init(index: 0, length: 3))
        XCTAssertNil(snapshot.presence?.first?.range)
        XCTAssertNil(RichDocumentSnapshot(value: .string("denied")))
    }
}
