// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class BridgeDescriptionConcurrencyTests: XCTestCase {
    private actor StartGate {
        private var remaining: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(participants: Int) { remaining = participants }

        func arrive() async {
            remaining -= 1
            if remaining == 0 {
                let waiting = waiters
                waiters.removeAll()
                waiting.forEach { $0.resume() }
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private static func description() -> AnyCell {
        let identifier = UUID().uuidString
        let peer = Identity(UUID().uuidString, displayName: identifier, identityVault: nil)
        let agreement = Agreement(owner: peer)
        agreement.uuid = identifier
        return AnyCell(
            uuid: identifier,
            name: identifier,
            contractTemplate: agreement,
            feedProperties: FeedProperties(endpoint: nil, type: .continous, mimetype: identifier),
            identityDomain: identifier
        )
    }

    private static func deliver(_ payload: ValueType, to bridge: BridgeBase) async throws {
        let commandID = await bridge.auditor.getNewCommandId()
        await bridge.auditor.storeBridgeCommand(
            BridgeCommand(cmd: Command.description.rawValue, payload: nil, cid: commandID),
            for: commandID
        )
        // Each response has its own decoded Agreement/Identity graph, as in a
        // real transport callback; no fixture keeps the retired graph alive.
        let response = BridgeCommand(cmd: Command.response.rawValue, payload: payload, cid: commandID)
        let data = try JSONEncoder().encode(response)
        try await bridge.consumeResponse(command: JSONDecoder().decode(BridgeCommand.self, from: data))
    }

    private static func assertCoherent(_ snapshot: AnyCell, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(snapshot.name, snapshot.uuid, file: file, line: line)
        XCTAssertEqual(snapshot.identityDomain, snapshot.uuid, file: file, line: line)
        XCTAssertEqual(snapshot.agreementTemplate.uuid, snapshot.uuid, file: file, line: line)
        XCTAssertEqual(snapshot.agreementTemplate.signatories.first?.displayName, snapshot.uuid, file: file, line: line)
        XCTAssertEqual(snapshot.feedProperties?.mimetype, snapshot.uuid, file: file, line: line)
        XCTAssertNil(snapshot.agreementTemplate.signatories.first?.identityVault, file: file, line: line)
    }

    func testOverlappingDescriptionResponsesAndAdvertisementsRetainCoherentSnapshots() async throws {
        let owner = Identity(UUID().uuidString, displayName: "local owner", identityVault: nil)
        let bridge = BridgeBase(owner: owner)
        try await Self.deliver(.description(Self.description()), to: bridge)
        let workers = 8
        let iterations = 128
        let gate = StartGate(participants: workers * 2)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    await gate.arrive()
                    for _ in 0..<iterations {
                        try await Self.deliver(.description(Self.description()), to: bridge)
                    }
                }
                group.addTask {
                    await gate.arrive()
                    for _ in 0..<iterations {
                        let snapshot = try await bridge.advertise(for: owner)
                        Self.assertCoherent(snapshot)
                        // Exercise individual getters too: retaining a reference
                        // must be safe while another callback replaces it.
                        let retainedAgreement = bridge.agreementTemplate
                        let retainedName = bridge.name
                        let retainedDomain = bridge.identityDomain
                        let retainedUUID = bridge.uuid
                        let retainedFeed = bridge.feedProperties
                        await Task.yield()
                        Self.assertCoherent(snapshot)
                        XCTAssertEqual(retainedAgreement.signatories.first?.displayName, retainedAgreement.uuid)
                        XCTAssertFalse(retainedName?.isEmpty ?? true)
                        XCTAssertFalse(retainedDomain.isEmpty)
                        XCTAssertFalse(retainedUUID.isEmpty)
                        XCTAssertNotNil(retainedFeed)
                    }
                }
            }
            try await group.waitForAll()
        }
        let pending = await bridge.auditor.pendingCommandCount()
        XCTAssertEqual(pending, 0)
        Self.assertCoherent(try await bridge.advertise(for: owner))
    }

    func testUnexpectedDescriptionPayloadDoesNotReplaceTheLastAcceptedSnapshot() async throws {
        let owner = Identity(UUID().uuidString, displayName: "local owner", identityVault: nil)
        let bridge = BridgeBase(owner: owner)
        let first = Self.description()
        try await Self.deliver(.description(first), to: bridge)
        let retained = try await bridge.advertise(for: owner)
        try await Self.deliver(.string("not a description"), to: bridge)
        let afterInvalid = try await bridge.advertise(for: owner)
        XCTAssertEqual(afterInvalid.uuid, first.uuid)
        Self.assertCoherent(afterInvalid)

        let replacement = Self.description()
        try await Self.deliver(.description(replacement), to: bridge)
        let afterReplacement = try await bridge.advertise(for: owner)
        XCTAssertEqual(afterReplacement.uuid, replacement.uuid)
        XCTAssertEqual(retained.uuid, first.uuid)
        Self.assertCoherent(retained)
        Self.assertCoherent(afterReplacement)
    }
}
