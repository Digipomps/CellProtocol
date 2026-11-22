// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@_spi(HAVENRuntime) @testable import CellBase

/// Derived tests for PDD chat-grunnmur (FORMAALSSPEC §5). Each test name says
/// which testRef it covers. Captured FlowElements are written to
/// `$CHAT_GRUNNMUR_EVIDENCE_DIR/flow-events.json` when that variable is set, so
/// the contract validator can check real output.
final class ConversationCellTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousDebug = false
    private var roots: [URL] = []

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousDebug = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.debugValidateAccessForEverything = previousDebug
        for root in roots { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    // MARK: test.chat.storage-append-only

    func testStorageAppendOnlyHundredMessagesGiveHundredNewFilesAndNoneChanges() async throws {
        let f = try await fixture(members: 2)
        var before: [String: Data] = [:]
        var mtimes: [String: Date] = [:]
        for i in 1...100 {
            let result = try await send(f.cell, from: f.people[i % 2], "melding \(i)")
            XCTAssertEqual(result.status, .sent)
            if i == 50 {
                (before, mtimes) = try snapshot(f.root)
            }
        }
        let (after, afterMtimes) = try snapshot(f.root)
        let sent = after.keys.filter { $0.hasPrefix("sent/") }
        let inbox = after.keys.filter { $0.hasPrefix("inbox/") }
        XCTAssertEqual(sent.count, 100, "one sent/ object per message")
        XCTAssertEqual(inbox.count, 100, "one inbox copy per recipient (two members: one recipient each)")
        for (key, data) in before {
            XCTAssertEqual(after[key], data, "\(key) changed content")
            XCTAssertEqual(afterMtimes[key], mtimes[key], "\(key) changed mtime")
        }
        let existing = try XCTUnwrap(sent.sorted().first)
        do {
            try await f.store.create(Data("x".utf8), at: existing)
            XCTFail("create-only store overwrote \(existing)")
        } catch ConversationStoreError.alreadyExists {}
        XCTAssertEqual(try snapshot(f.root).0[existing], after[existing])
    }

    // MARK: test.chat.conversation-cell-isolation

    func testThreeConversationsHaveThreeSeparateStorageAreas() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "iso-owner", makeNewIfNotFound: true)!
        let base = temporaryRoot()
        let index = InMemoryConversationIndex()
        var cells = [ConversationCell]()
        for n in 0..<3 {
            let store = LocalFileConversationStore(root: base.appendingPathComponent("conv-\(n)"))
            cells.append(await ConversationCell(owner: owner, conversationID: "conv-\(n)", title: "Samtale \(n)",
                members: [member(owner)], store: store, index: index))
        }
        for (n, cell) in cells.enumerated() {
            let result = try await send(cell, from: owner, "hemmelig-\(n)")
            XCTAssertEqual(result.seq, 1)
        }
        let areas = try FileManager.default.contentsOfDirectory(atPath: base.path).sorted()
        XCTAssertEqual(areas, ["conv-0", "conv-1", "conv-2"])
        for n in 0..<3 {
            let files = try snapshot(base.appendingPathComponent("conv-\(n)")).0
            let text = files.values.map { String(decoding: $0, as: UTF8.self) }.joined()
            XCTAssertTrue(text.contains("hemmelig-\(n)"))
            for other in 0..<3 where other != n {
                XCTAssertFalse(text.contains("hemmelig-\(other)"), "conv-\(n) holds text from conv-\(other)")
            }
        }
    }

    // MARK: test.chat.idempotent-send

    func testSameClientMessageIDThreeTimesStoresOneMessageAndGivesThreeEqualAnswers() async throws {
        let f = try await fixture(members: 2)
        let clientID = UUID().uuidString
        var answers = [ConversationSendResult]()
        for _ in 0..<3 {
            answers.append(try await send(f.cell, from: f.people[0], "én gang", clientID: clientID))
        }
        XCTAssertEqual(answers.map(\.status), [.sent, .duplicate, .duplicate])
        XCTAssertEqual(Set(answers.compactMap(\.seq)), [1])
        XCTAssertEqual(Set(answers.compactMap(\.messageID)).count, 1)
        try assertSameJSON(answers[0].message, answers[2].message)
        XCTAssertEqual(try snapshot(f.root).0.keys.filter { $0.hasPrefix("sent/") }.count, 1)
        let page = try await since(f.cell, as: f.people[1], after: 0)
        XCTAssertEqual(page.messages.count, 1)
    }

    // MARK: test.chat.failed-save-reports-error

    func testFailedSaveReportsErrorPublishesNothingAndLeavesNoInboxCopy() async throws {
        let failing = FailingStore()
        let f = try await fixture(members: 3, store: failing)
        let events = Recorder()
        let subscription = try await f.cell.flow(requester: f.people[1]).sink(receiveCompletion: { _ in }, receiveValue: events.add)
        defer { subscription.cancel() }
        await failing.failNext(prefix: "sent/")
        let clientID = UUID().uuidString
        let failed = try await send(f.cell, from: f.people[0], "går ikke", clientID: clientID)
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.status, .error)
        XCTAssertEqual(failed.code, "storage_failed")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(events.titles.filter { $0 == "message.appended" }, [], "nothing may be published after a failed save")
        let keys = try await failing.inner.list(prefix: "", startAfter: nil)
        XCTAssertFalse(keys.contains { $0.hasPrefix("inbox/") || $0.hasPrefix("sent/") }, "rolled back: \(keys)")
        let retried = try await send(f.cell, from: f.people[0], "går ikke", clientID: clientID)
        XCTAssertEqual(retried.status, .sent)
        XCTAssertEqual(retried.seq, 1, "a failed attempt does not burn a sequence number")
        try await waitFor { events.titles.contains("message.appended") }
    }

    func testIndexFailureAfterCommitIsCompletedByRetryWithSameSeq() async throws {
        let index = FailingIndex()
        let f = try await fixture(members: 2, index: index)
        await index.failNextRecord()
        let clientID = UUID().uuidString
        let first = try await send(f.cell, from: f.people[0], "indeks nede", clientID: clientID)
        XCTAssertEqual(first.code, "storage_failed")
        let retry = try await send(f.cell, from: f.people[0], "indeks nede", clientID: clientID)
        XCTAssertEqual(retry.status, .sent)
        XCTAssertEqual(retry.seq, 1)
        let again = try await send(f.cell, from: f.people[0], "indeks nede", clientID: clientID)
        XCTAssertEqual(again.status, .duplicate)
        XCTAssertEqual(try snapshot(f.root).0.keys.filter { $0.hasPrefix("sent/") }.count, 1)
    }

    // MARK: test.chat.auth-outsider

    func testOutsiderCannotReadSendOrSubscribeAndPendingInviteeSeesOnlyPreview() async throws {
        let f = try await fixture(members: 2)
        let outsider = await f.vault.identity(for: "outsider", makeNewIfNotFound: true)!
        let pending = await f.vault.identity(for: "pending", makeNewIfNotFound: true)!
        try await f.cell.applyMembership(title: "Planlegging", members: f.people.map(member), pendingInviteeUUIDs: [pending.uuid])
        _ = try await send(f.cell, from: f.people[0], "bare for medlemmer")
        let impostor = Identity(f.people[1].uuid, displayName: "falsk", identityVault: f.vault)
        for (who, label) in [(outsider, "outsider"), (pending, "pending"), (impostor, "impostor")] {
            await assertDenied(label + " state") { _ = try await f.cell.get(keypath: "state", requester: who) }
            await assertDenied(label + " since") { _ = try await f.cell.get(keypath: "messages.since.0", requester: who) }
            await assertDenied(label + " since set") {
                _ = try await f.cell.set(keypath: "messages.since", value: .object(["afterSeq": .integer(0)]), requester: who)
            }
            await assertDenied(label + " send") {
                _ = try await f.cell.set(keypath: "messages.send", value: self.sendPayload("inn", UUID().uuidString), requester: who)
            }
            await assertDenied(label + " read.mark") {
                _ = try await f.cell.set(keypath: "read.mark", value: .object(["uptoSeq": .integer(1)]), requester: who)
            }
            await assertDenied(label + " feed") { _ = try await f.cell.flow(requester: who) }
        }
        let preview = try await f.cell.get(keypath: "preview", requester: pending)
        guard case .object(let fields) = preview else { return XCTFail("preview \(preview)") }
        XCTAssertEqual(Set(fields.keys), ["conversationID", "title", "inviterDisplayName"])
        await assertDenied("outsider preview") { _ = try await f.cell.get(keypath: "preview", requester: outsider) }
        let page = try await since(f.cell, as: f.people[1], after: 0)
        XCTAssertEqual(page.messages.map(\.content), ["bare for medlemmer"])
    }

    func testRemovedMemberStopsReceivingTheFeed() async throws {
        let f = try await fixture(members: 3)
        let events = Recorder()
        let subscription = try await f.cell.flow(requester: f.people[2]).sink(receiveCompletion: { _ in }, receiveValue: events.add)
        defer { subscription.cancel() }
        _ = try await send(f.cell, from: f.people[0], "før")
        try await waitFor { events.titles.contains("message.appended") }
        try await f.cell.applyMembership(title: "t", members: Array(f.people.prefix(2)).map(member), pendingInviteeUUIDs: [])
        _ = try await send(f.cell, from: f.people[0], "etter")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(events.messages.map(\.content), ["før"], "a removed member must not receive later messages")
        await assertDenied("removed state") { _ = try await f.cell.get(keypath: "state", requester: f.people[2]) }
    }

    // MARK: test.chat.catch-up and flow-events

    func testFeedCarriesWholeMessageAndCatchUpAfterDisconnectHasNoGapsOrDuplicates() async throws {
        let f = try await fixture(members: 2)
        let client = ContractClient()
        var subscription: AnyCancellable? = try await f.cell.flow(requester: f.people[1])
            .sink(receiveCompletion: { _ in }, receiveValue: client.receive)
        _ = try await send(f.cell, from: f.people[0], "1")
        try await waitFor { client.applied.count == 1 }
        XCTAssertEqual(client.resyncRequests, 0, "an in-order event is applied without asking for state")

        subscription?.cancel()
        subscription = nil
        for n in 2...6 { _ = try await send(f.cell, from: f.people[0], "\(n)") }

        subscription = try await f.cell.flow(requester: f.people[1]).sink(receiveCompletion: { _ in }, receiveValue: client.receive)
        // Reconnect: one messages.since from the last known seq.
        let page = try await since(f.cell, as: f.people[1], after: client.lastKnown)
        client.applyPage(page.messages)
        _ = try await send(f.cell, from: f.people[0], "7")
        try await waitFor { client.applied.count == 7 }
        XCTAssertEqual(client.applied.map(\.content), (1...7).map(String.init))
        XCTAssertEqual(client.applied.map(\.seq), Array(1...7))
        XCTAssertEqual(client.duplicatesIgnored, 0)
        subscription?.cancel()
        try writeEvidence(client.rawEvents)
    }

    func testDroppedEventIsDetectedByTheNextSeqAndRecoveredWithOneSince() async throws {
        let f = try await fixture(members: 2)
        let client = ContractClient()
        client.dropSeqs = [2]
        let subscription = try await f.cell.flow(requester: f.people[1]).sink(receiveCompletion: { _ in }, receiveValue: client.receive)
        defer { subscription.cancel() }
        for n in 1...3 { _ = try await send(f.cell, from: f.people[0], "\(n)") }
        try await waitFor { client.pendingResync != nil }
        XCTAssertEqual(client.resyncRequests, 1)
        let page = try await since(f.cell, as: f.people[1], after: try XCTUnwrap(client.pendingResync))
        client.applyPage(page.messages)
        XCTAssertEqual(client.applied.map(\.seq), [1, 2, 3])
    }

    func testEveryEventCarriesItsSequence() async throws {
        let f = try await fixture(members: 2)
        let events = Recorder()
        let subscription = try await f.cell.flow(requester: f.people[0]).sink(receiveCompletion: { _ in }, receiveValue: events.add)
        defer { subscription.cancel() }
        _ = try await send(f.cell, from: f.people[1], "a")
        _ = try await f.cell.set(keypath: "read.mark", value: .object(["uptoSeq": .integer(1)]), requester: f.people[0])
        try await f.cell.applyMembership(title: "Nytt navn", members: f.people.map(member), pendingInviteeUUIDs: [])
        try await waitFor { events.titles.count == 3 }
        XCTAssertEqual(events.titles, ["message.appended", "read.updated", "member.changed"])
        for element in events.elements {
            XCTAssertEqual(element.topic, ConversationCell.flowTopic)
            guard case .object(let content) = element.content else { return XCTFail("content") }
            XCTAssertEqual(content["lastSeq"], .integer(1), element.title)
            XCTAssertEqual(content["conversationID"], .string("conv"), element.title)
        }
        try writeEvidence(events.elements.map(Self.json))
    }

    // MARK: test.chat.unread-across-devices (cell part)

    func testThreeUnreadAndMarkingReadOnOneDeviceReachesTheOther() async throws {
        let f = try await fixture(members: 2)
        let otherDevice = Recorder()
        let subscription = try await f.cell.flow(requester: f.people[0]).sink(receiveCompletion: { _ in }, receiveValue: otherDevice.add)
        defer { subscription.cancel() }
        for n in 1...3 { _ = try await send(f.cell, from: f.people[1], "fra B \(n)") }
        let observed266 = try await stateField("unread", f.cell, f.people[0])
        XCTAssertEqual(observed266, .integer(3))
        let marked = try await f.cell.set(keypath: "read.mark", value: .object(["uptoSeq": .integer(3)]), requester: f.people[0])
        try assertSameJSON(marked ?? .null, ValueType.object(["ok": .bool(true), "readUptoSeq": .integer(3), "unread": .integer(0)]))
        let observed269 = try await stateField("unread", f.cell, f.people[0])
        XCTAssertEqual(observed269, .integer(0))
        try await waitFor { otherDevice.titles.contains("read.updated") }
        let backwards = try await f.cell.set(keypath: "read.mark", value: .object(["uptoSeq": .integer(1)]), requester: f.people[0])
        try assertSameJSON(backwards ?? .null, ValueType.object(["ok": .bool(true), "readUptoSeq": .integer(3), "unread": .integer(0)]))
        let observed273 = try await stateField("unread", f.cell, f.people[1])
        XCTAssertEqual(observed273, .integer(0), "own messages are never unread")
    }

    // MARK: test.chat.index-rebuild

    func testDeletingTheIndexAndRebuildingGivesTheSameListAndUnread() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let a = await vault.identity(for: "rebuild-a", makeNewIfNotFound: true)!
        let b = await vault.identity(for: "rebuild-b", makeNewIfNotFound: true)!
        let base = temporaryRoot()
        let index = InMemoryConversationIndex()
        var stores = [String: LocalFileConversationStore]()
        for n in 0..<3 {
            let id = "conv-\(n)"
            let store = LocalFileConversationStore(root: base.appendingPathComponent(id))
            stores[id] = store
            let cell = await ConversationCell(owner: a, conversationID: id, title: "T\(n)", members: [member(a), member(b)],
                store: store, index: index, now: Self.clock(start: Double(n) * 100))
            for m in 0...n { _ = try await send(cell, from: m % 2 == 0 ? b : a, "c\(n) m\(m)") }
            _ = try await cell.set(keypath: "read.mark", value: .object(["uptoSeq": .integer(1)]), requester: a)
        }
        let beforeA = try await index.conversations(forMember: a.uuid)
        let beforeB = try await index.conversations(forMember: b.uuid)
        XCTAssertEqual(beforeA.map(\.conversationID), ["conv-2", "conv-1", "conv-0"])
        let rebuilt = InMemoryConversationIndex()
        for (id, store) in stores { try await ConversationIndexRebuilder.rebuild(conversationID: id, store: store, index: rebuilt) }
        try assertSameJSON(beforeA, try await rebuilt.conversations(forMember: a.uuid))
        try assertSameJSON(beforeB, try await rebuilt.conversations(forMember: b.uuid))
    }

    func testRestartedCellContinuesTheSequenceFromItsObjects() async throws {
        let f = try await fixture(members: 2)
        for n in 1...4 { _ = try await send(f.cell, from: f.people[0], "\(n)") }
        let fresh = InMemoryConversationIndex()
        let restarted = await ConversationCell(owner: f.people[0], conversationID: "conv", title: "ignored", members: [],
            store: f.store, index: fresh)
        XCTAssertEqual(restarted.membership.members.map(\.uuid).sorted(), f.people.map(\.uuid).sorted(), "stored meta wins")
        let next = try await send(restarted, from: f.people[1], "5")
        XCTAssertEqual(next.seq, 5)
        let observed313 = try await fresh.lastSeq(conversationID: "conv")
        XCTAssertEqual(observed313, 5)
    }

    // MARK: test.chat.list-order-ignores-drafts (cell part)

    func testListOrderChangesOnlyWithSentMessages() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let a = await vault.identity(for: "order-a", makeNewIfNotFound: true)!
        let b = await vault.identity(for: "order-b", makeNewIfNotFound: true)!
        let base = temporaryRoot()
        let index = InMemoryConversationIndex()
        let clock = Self.clock(start: 0)
        var cells = [ConversationCell]()
        for n in 1...2 {
            cells.append(await ConversationCell(owner: a, conversationID: "c\(n)", title: "T\(n)", members: [member(a), member(b)],
                store: LocalFileConversationStore(root: base.appendingPathComponent("c\(n)")), index: index, now: clock))
            _ = try await send(cells[n - 1], from: a, "første i c\(n)")
        }
        let observed332 = try await index.conversations(forMember: a.uuid).map(\.conversationID)
        XCTAssertEqual(observed332, ["c2", "c1"])
        _ = try await cells[0].set(keypath: "read.mark", value: .object(["uptoSeq": .integer(1)]), requester: b)
        try await cells[0].applyMembership(title: "Omdøpt", members: [member(a), member(b)], pendingInviteeUUIDs: [])
        let observed335 = try await index.conversations(forMember: a.uuid).map(\.conversationID)
        XCTAssertEqual(observed335, ["c2", "c1"],
            "read marks and renames do not reorder")
        _ = try await send(cells[0], from: b, "nytt i c1")
        let observed338 = try await index.conversations(forMember: a.uuid).map(\.conversationID)
        XCTAssertEqual(observed338, ["c1", "c2"])
    }

    func testConcurrentSendsGetDistinctConsecutiveSequenceNumbers() async throws {
        let f = try await fixture(members: 3)
        let results = try await withThrowingTaskGroup(of: ConversationSendResult.self) { group in
            for n in 0..<24 {
                group.addTask { try await self.send(f.cell, from: f.people[n % 3], "p\(n)") }
            }
            var all = [ConversationSendResult]()
            for try await r in group { all.append(r) }
            return all
        }
        XCTAssertEqual(results.compactMap(\.seq).sorted(), Array(1...24))
        XCTAssertEqual(try snapshot(f.root).0.keys.filter { $0.hasPrefix("sent/") }.count, 24)
    }

    // MARK: Fixtures and helpers

    private struct Fixture {
        var vault: MockIdentityVault
        var people: [Identity]
        var cell: ConversationCell
        var store: ConversationStore
        var root: URL
    }

    private func fixture(members count: Int, store custom: FailingStore? = nil, index: ConversationIndex = InMemoryConversationIndex()) async throws -> Fixture {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        var people = [Identity]()
        for n in 0..<count { people.append(await vault.identity(for: "member-\(n)", makeNewIfNotFound: true)!) }
        let root = temporaryRoot()
        let local = LocalFileConversationStore(root: root)
        if let custom { await custom.setInner(local) }
        let store: ConversationStore = custom ?? local
        let cell = await ConversationCell(owner: people[0], conversationID: "conv", title: "Planlegging",
            members: people.map(member), store: store, index: index)
        return Fixture(vault: vault, people: people, cell: cell, store: local, root: root)
    }

    private func member(_ identity: Identity) -> ConversationMember {
        ConversationMember(uuid: identity.uuid, displayName: identity.displayName,
            signingPublicKeyFingerprint: identity.signingPublicKeyFingerprint)
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-tests-\(UUID().uuidString)")
        roots.append(root)
        return root
    }

    private static func clock(start: Double) -> @Sendable () -> Date {
        let tick = Counter()
        return { Date(timeIntervalSince1970: 1_795_000_000 + start + Double(tick.next())) }
    }

    private func sendPayload(_ text: String, _ clientID: String) -> ValueType {
        .object(["clientMessageID": .string(clientID), "contentType": .string("text/plain"), "content": .string(text)])
    }

    private func send(_ cell: ConversationCell, from who: Identity, _ text: String, clientID: String = UUID().uuidString) async throws -> ConversationSendResult {
        let value = try await cell.set(keypath: "messages.send", value: sendPayload(text, clientID), requester: who) ?? .null
        return try ConversationCodec.decode(value, as: ConversationSendResult.self)
    }

    private func since(_ cell: ConversationCell, as who: Identity, after: Int) async throws -> ConversationMessagePage {
        try ConversationCodec.decode(try await cell.get(keypath: "messages.since.\(after)", requester: who), as: ConversationMessagePage.self)
    }

    private func stateField(_ key: String, _ cell: ConversationCell, _ who: Identity) async throws -> ValueType? {
        guard case .object(let fields) = try await cell.get(keypath: "state", requester: who) else { return nil }
        return fields[key]
    }

    private func snapshot(_ root: URL) throws -> ([String: Data], [String: Date]) {
        var data = [String: Data](), times = [String: Date]()
        let base = root.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(atPath: base) else { return ([:], [:]) }
        while let rel = e.nextObject() as? String {
            var dir: ObjCBool = false
            let path = base + "/" + rel
            guard FileManager.default.fileExists(atPath: path, isDirectory: &dir), !dir.boolValue else { continue }
            data[rel] = try Data(contentsOf: URL(fileURLWithPath: path))
            times[rel] = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        }
        return (data, times)
    }

    private func assertSameJSON<T: Encodable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(lhs), as: UTF8.self),
                       String(decoding: try encoder.encode(rhs), as: UTF8.self), file: file, line: line)
    }

    private func assertDenied(_ label: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("\(label) was allowed")
        } catch {}
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met in \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func json(_ element: FlowElement) -> [String: Any] {
        let content = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(element.content))) ?? [:]
        return ["title": element.title, "topic": element.topic ?? "", "content": content]
    }

    private func writeEvidence(_ events: [[String: Any]]) throws {
        guard let dir = ProcessInfo.processInfo.environment["CHAT_GRUNNMUR_EVIDENCE_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("flow-events-\(name.split(separator: " ").last?.dropLast() ?? "test").json")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}

// MARK: - Test doubles

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [FlowElement]()
    func add(_ element: FlowElement) { lock.withLock { values.append(element) } }
    var elements: [FlowElement] { lock.withLock { values } }
    var titles: [String] { elements.map(\.title) }
    var messages: [ConversationMessage] {
        elements.compactMap { element in
            guard element.title == "message.appended", case .object(let c) = element.content, let m = c["message"] else { return nil }
            return try? ConversationCodec.decode(m, as: ConversationMessage.self)
        }
    }
}

/// The client rule from the contract: apply seq == lastKnown + 1, ignore
/// seq <= lastKnown, ask for messages.since only on a gap.
private final class ContractClient: @unchecked Sendable {
    private let lock = NSLock()
    private var appliedValues = [ConversationMessage]()
    private var raw = [[String: Any]]()
    private var resyncs = 0
    private var duplicates = 0
    private var resyncAfter: Int?
    var dropSeqs: Set<Int> = []

    var applied: [ConversationMessage] { lock.withLock { appliedValues } }
    var lastKnown: Int { lock.withLock { appliedValues.last?.seq ?? 0 } }
    var resyncRequests: Int { lock.withLock { resyncs } }
    var duplicatesIgnored: Int { lock.withLock { duplicates } }
    var pendingResync: Int? { lock.withLock { resyncAfter } }
    var rawEvents: [[String: Any]] { lock.withLock { raw } }

    func receive(_ element: FlowElement) {
        guard element.title == "message.appended", case .object(let content) = element.content,
              let value = content["message"], let message = try? ConversationCodec.decode(value, as: ConversationMessage.self) else { return }
        lock.withLock {
            raw.append(ConversationCellTests.json(element))
            if dropSeqs.contains(message.seq) { return }
            let last = appliedValues.last?.seq ?? 0
            if message.seq <= last { duplicates += 1 }
            else if message.seq == last + 1 { appliedValues.append(message) }
            else if resyncAfter == nil { resyncs += 1; resyncAfter = last }
        }
    }

    func applyPage(_ messages: [ConversationMessage]) {
        lock.withLock {
            for message in messages {
                let last = appliedValues.last?.seq ?? 0
                if message.seq == last + 1 { appliedValues.append(message) } else if message.seq <= last { duplicates += 1 }
            }
            resyncAfter = nil
        }
    }
}

private actor FailingStore: ConversationStore {
    private(set) var inner: ConversationStore = LocalFileConversationStore(root: URL(fileURLWithPath: "/nonexistent"))
    private var failPrefix: String?

    func setInner(_ store: ConversationStore) { inner = store }
    func failNext(prefix: String) { failPrefix = prefix }

    func create(_ data: Data, at key: String) async throws {
        if let prefix = failPrefix, key.hasPrefix(prefix) {
            failPrefix = nil
            throw ConversationStoreError.backend("injected failure at \(key)")
        }
        try await inner.create(data, at: key)
    }
    func read(_ key: String) async throws -> Data? { try await inner.read(key) }
    func list(prefix: String, startAfter: String?) async throws -> [String] { try await inner.list(prefix: prefix, startAfter: startAfter) }
    func delete(_ key: String) async throws { try await inner.delete(key) }
}

private actor FailingIndex: ConversationIndex {
    private let inner = InMemoryConversationIndex()
    private var failRecord = false
    func failNextRecord() { failRecord = true }
    func recordMeta(_ meta: ConversationMeta) async throws { try await inner.recordMeta(meta) }
    func record(_ message: ConversationMessage) async throws {
        if failRecord { failRecord = false; throw ConversationStoreError.backend("injected index failure") }
        try await inner.record(message)
    }
    func setReadUpto(conversationID: String, memberUUID: String, seq: Int) async throws {
        try await inner.setReadUpto(conversationID: conversationID, memberUUID: memberUUID, seq: seq)
    }
    func readUpto(conversationID: String, memberUUID: String) async throws -> Int {
        try await inner.readUpto(conversationID: conversationID, memberUUID: memberUUID)
    }
    func lastSeq(conversationID: String) async throws -> Int { try await inner.lastSeq(conversationID: conversationID) }
    func message(conversationID: String, clientMessageID: String) async throws -> ConversationIndexedMessage? {
        try await inner.message(conversationID: conversationID, clientMessageID: clientMessageID)
    }
    func unread(conversationID: String, memberUUID: String) async throws -> Int {
        try await inner.unread(conversationID: conversationID, memberUUID: memberUUID)
    }
    func conversations(forMember memberUUID: String) async throws -> [ConversationIndexRow] {
        try await inner.conversations(forMember: memberUUID)
    }
    func reset(conversationID: String) async throws { try await inner.reset(conversationID: conversationID) }
}
