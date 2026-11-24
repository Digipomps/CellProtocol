// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  ChatModelFixturesV1Tests.swift
//  PDD_modell-i-felles-chat_2026-11-15, WP4.
//
//  Scenario fixtures for the model-in-chat rules, so Python and Go check the
//  same consent ledger, mention detection, context window and answer
//  sanitising as Swift. The inputs are written here; the expectations are what
//  Swift answers.
//
//  Regenerate:
//    HAVEN_WRITE_CHAT_MODEL_FIXTURES=1 swift test --filter ChatModelFixturesV1Tests
//  Verify (always runs):
//    swift test --filter ChatModelFixturesV1Tests
//

import Foundation
import XCTest
@testable import CellBase

final class ChatModelFixturesV1Tests: XCTestCase {

    static let alice = "6F1C2B0A-0000-4000-8000-00000000A11C"
    static let bob = "6F1C2B0A-0000-4000-8000-000000000B0B"
    static let carol = "6F1C2B0A-0000-4000-8000-000000000CA1"
    static let mallory = "6F1C2B0A-0000-4000-8000-0000000BAD00"
    static let model = "6F1C2B0A-0000-4000-8000-0000000A0DE1"

    // MARK: - Inputs

    struct Step {
        var event: String
        var member: String? = nil
        var external: Bool = false
        var at: String
        var members: [String]
    }

    static func t(_ minute: Int) -> String { String(format: "2026-11-20T12:%02d:00Z", minute) }

    static var ledgerScenarios: [(String, [Step])] {
        let ab = [alice, bob]
        let abc = [alice, bob, carol]
        return [
            ("all_members_must_say_yes", [
                Step(event: "propose", member: alice, at: t(0), members: ab),
                Step(event: "consent", member: bob, at: t(1), members: ab)
            ]),
            ("one_no_blocks_activation", [
                Step(event: "propose", member: alice, at: t(0), members: abc),
                Step(event: "consent", member: bob, at: t(1), members: abc),
                Step(event: "decline", member: carol, at: t(2), members: abc),
                Step(event: "consent", member: carol, at: t(3), members: abc)
            ]),
            ("withdraw_after_activation_stops_model", [
                Step(event: "propose", member: alice, at: t(0), members: ab),
                Step(event: "consent", member: bob, at: t(1), members: ab),
                Step(event: "decline", member: bob, at: t(2), members: ab),
                Step(event: "consent", member: bob, at: t(3), members: ab)
            ]),
            ("newcomer_after_activation_keeps_model_but_blocks_external", [
                Step(event: "propose", member: alice, external: true, at: t(0), members: ab),
                Step(event: "consent", member: bob, external: true, at: t(1), members: ab),
                Step(event: "membersChanged", at: t(2), members: abc),
                Step(event: "consent", member: carol, external: true, at: t(3), members: abc),
                Step(event: "decline", member: carol, at: t(4), members: abc)
            ]),
            ("newcomer_before_activation_must_answer", [
                Step(event: "propose", member: alice, at: t(0), members: ab),
                Step(event: "membersChanged", at: t(1), members: abc),
                Step(event: "consent", member: bob, at: t(2), members: abc),
                Step(event: "consent", member: carol, at: t(3), members: abc)
            ]),
            ("leaver_who_said_no_unblocks", [
                Step(event: "propose", member: alice, at: t(0), members: abc),
                Step(event: "consent", member: bob, at: t(1), members: abc),
                Step(event: "decline", member: carol, at: t(2), members: abc),
                Step(event: "membersChanged", at: t(3), members: ab)
            ]),
            ("external_needs_everyones_explicit_yes", [
                Step(event: "propose", member: alice, external: true, at: t(0), members: ab),
                Step(event: "consent", member: bob, external: false, at: t(1), members: ab),
                Step(event: "consent", member: bob, external: true, at: t(2), members: ab)
            ]),
            ("remove_then_propose_again", [
                Step(event: "propose", member: alice, at: t(0), members: ab),
                Step(event: "consent", member: bob, at: t(1), members: ab),
                Step(event: "remove", member: bob, at: t(2), members: ab),
                Step(event: "consent", member: alice, at: t(3), members: ab),
                Step(event: "propose", member: bob, at: t(4), members: ab),
                Step(event: "consent", member: alice, at: t(5), members: ab)
            ]),
            ("refusals", [
                Step(event: "consent", member: alice, at: t(0), members: ab),
                Step(event: "propose", member: mallory, at: t(1), members: ab),
                Step(event: "propose", member: alice, at: t(2), members: ab),
                Step(event: "propose", member: bob, at: t(3), members: ab),
                Step(event: "decline", member: mallory, at: t(4), members: ab),
                Step(event: "remove", member: mallory, at: t(5), members: ab)
            ]),
            ("everyone_leaves", [
                Step(event: "propose", member: alice, at: t(0), members: [alice]),
                Step(event: "membersChanged", at: t(1), members: [])
            ])
        ]
    }

    static let mentionTexts: [String] = [
        "@modell hva mener du?",
        "Hei @Modell, kan du oppsummere?",
        "spør @MODEL om dette",
        "@modellen er ikke nevnt",
        "e-post: ola@modell.no",
        "ola@modell",
        "(@modell)",
        "@modell_x",
        "@modell2",
        "ingen omtale her",
        "@modelløs",
        "første @mod, så @model."
    ]

    static var contextCases: [(name: String, messages: [ChatModelRules.MessageStamp], activatedAt: String, questionID: String, limit: Int)] {
        func stamps(_ count: Int, startMinute: Int = 0) -> [ChatModelRules.MessageStamp] {
            (0 ..< count).map { ChatModelRules.MessageStamp(id: "m\($0 + 1)", createdAt: String(format: "2026-11-20T13:%02d:00Z", startMinute + $0)) }
        }
        let thirty = stamps(30)
        return [
            ("before_activation_is_hidden", stamps(6), "2026-11-20T13:03:00Z", "m6", 20),
            ("newest_twenty_kept", thirty, "2026-11-20T13:00:00Z", "m30", 20),
            ("nothing_after_the_question", thirty, "2026-11-20T13:00:00Z", "m10", 20),
            ("unknown_question", stamps(3), "2026-11-20T13:00:00Z", "m99", 20),
            ("question_before_activation", stamps(5), "2026-11-20T13:04:00Z", "m2", 20),
            ("smaller_limit", thirty, "2026-11-20T13:00:00Z", "m30", 3),
            ("zero_limit", stamps(3), "2026-11-20T13:00:00Z", "m3", 0)
        ]
    }

    static let sanitizeInputs: [(String, String)] = [
        ("plain", "Hei, dette er et svar."),
        ("crlf_and_cr", "linje1\r\nlinje2\rlinje3"),
        ("controls_dropped", "a\u{0000}b\u{0007}c\u{001B}[31md\u{007F}e\u{0085}f\u{009B}g"),
        ("tab_and_lf_kept", "kol1\tkol2\nrad2"),
        ("trim_whitespace", "  \n\t svar \u{00A0}\n "),
        ("norwegian_and_emoji", "Ærlig talt: blåbær 🫐 og 👩🏽‍💻"),
        ("markup_is_just_text", "<script>alert(1)</script> **fet**"),
        ("cut_to_limit", String(repeating: "å", count: 4_100)),
        ("cut_counts_scalars", String(repeating: "👩🏽‍💻", count: 1_100))
    ]

    // MARK: - Expectations from Swift

    static func snapshot(_ ledger: ChatModelConsentLedger, members: [String], refusal: String?) -> [String: Any] {
        var awaiting: [String: Bool] = [:]
        for member in members { awaiting[member] = ledger.awaitingAnswer(from: member, members: members) }
        return [
            "refusal": refusal ?? NSNull(),
            "status": ledger.status.rawValue,
            "activatedAt": ledger.activatedAt ?? NSNull(),
            "modelConsentHolds": ledger.modelConsentHolds(members: members),
            "externalAllowed": ledger.externalAllowed(members: members),
            "consentedMembers": ledger.consentedMembers(members),
            "awaitingAnswer": awaiting
        ]
    }

    static func apply(_ step: [String: Any], to ledger: inout ChatModelConsentLedger) -> String? {
        let event = step["event"] as! String
        let member = step["member"] as? String ?? ""
        let external = step["external"] as? Bool ?? false
        let at = step["at"] as! String
        let members = step["members"] as! [String]
        do {
            switch event {
            case "propose":
                try ledger.propose(modelUUID: model, displayName: "Modell", by: member, external: external, at: at, members: members)
            case "consent":
                try ledger.consent(by: member, external: external, at: at, members: members)
            case "decline":
                try ledger.decline(by: member, at: at, members: members)
            case "remove":
                try ledger.remove(by: member, at: at, members: members)
            case "membersChanged":
                ledger.membersChanged(members: members, at: at)
            default:
                return "unknown_event"
            }
            return nil
        } catch let refusal as ChatModelConsentLedger.Refusal {
            return refusal.rawValue
        } catch {
            return "unexpected"
        }
    }

    static func stepObject(_ step: Step) -> [String: Any] {
        var object: [String: Any] = ["event": step.event, "at": step.at, "members": step.members]
        if let member = step.member {
            object["member"] = member
            if step.event == "propose" || step.event == "consent" { object["external"] = step.external }
        }
        return object
    }

    static func buildFixture() -> [String: Any] {
        var scenarios: [[String: Any]] = []
        for (name, steps) in ledgerScenarios {
            var ledger = ChatModelConsentLedger()
            var stepObjects: [[String: Any]] = []
            for step in steps {
                var object = stepObject(step)
                let refusal = apply(object, to: &ledger)
                object["expect"] = snapshot(ledger, members: step.members, refusal: refusal)
                stepObjects.append(object)
            }
            scenarios.append(["name": name, "steps": stepObjects])
        }
        let mentions: [[String: Any]] = mentionTexts.map { ["text": $0, "expect": ChatModelRules.isAddressedToModel($0)] }
        let contexts: [[String: Any]] = contextCases.map { item in
            [
                "name": item.name,
                "messages": item.messages.map { ["id": $0.id, "createdAt": $0.createdAt] },
                "activatedAt": item.activatedAt,
                "questionID": item.questionID,
                "limit": item.limit,
                "expect": ChatModelRules.contextMessageIDs(messages: item.messages, activatedAt: item.activatedAt, questionID: item.questionID, limit: item.limit)
            ]
        }
        let sanitize: [[String: Any]] = sanitizeInputs.map { name, text in
            let output = ChatModelRules.sanitizeAnswer(text)
            return ["name": name, "text": text, "expect": output, "expectScalarCount": output.unicodeScalars.count]
        }
        return [
            "version": "chat-model-v1",
            "constants": [
                "contextLimit": ChatModelRules.contextLimit,
                "answerLimitScalars": ChatModelRules.answerLimitScalars,
                "askLifetimeSeconds": Int(ChatModelRules.askLifetimeSeconds),
                "mentionTokens": ChatModelRules.mentionTokens
            ],
            "ledgerScenarios": scenarios,
            "mentionCases": mentions,
            "contextCases": contexts,
            "sanitizeCases": sanitize
        ]
    }

    // MARK: - Files

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/interop/chat-model-v1/scenarios.json")
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    func testWriteFixtures() throws {
        guard ProcessInfo.processInfo.environment["HAVEN_WRITE_CHAT_MODEL_FIXTURES"] == "1" else {
            throw XCTSkip("Set HAVEN_WRITE_CHAT_MODEL_FIXTURES=1 to regenerate fixtures/interop/chat-model-v1.")
        }
        let url = Self.fixtureURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(Self.buildFixture()).write(to: url)
    }

    /// The checked-in file still matches what Swift answers today.
    func testFixtureMatchesSwift() throws {
        let url = Self.fixtureURL
        guard let data = try? Data(contentsOf: url) else {
            return XCTFail("Missing \(url.path). Generate with HAVEN_WRITE_CHAT_MODEL_FIXTURES=1.")
        }
        let onDisk = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let fresh = try JSONSerialization.jsonObject(with: Self.encode(Self.buildFixture())) as! [String: Any]
        XCTAssertEqual(onDisk as NSDictionary, fresh as NSDictionary, "Fixture is stale; regenerate it.")
    }

    /// Replays the file the way Python and Go do: read the inputs, run them, compare.
    func testReplayFixtureLikeAnotherRuntime() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        for scenario in root["ledgerScenarios"] as! [[String: Any]] {
            var ledger = ChatModelConsentLedger()
            for (index, step) in (scenario["steps"] as! [[String: Any]]).enumerated() {
                let refusal = Self.apply(step, to: &ledger)
                let got = Self.snapshot(ledger, members: step["members"] as! [String], refusal: refusal)
                let want = step["expect"] as! [String: Any]
                XCTAssertEqual(got as NSDictionary, want as NSDictionary, "\(scenario["name"]!) step \(index)")
            }
        }
        for item in root["mentionCases"] as! [[String: Any]] {
            XCTAssertEqual(ChatModelRules.isAddressedToModel(item["text"] as! String), item["expect"] as! Bool, "\(item["text"]!)")
        }
        for item in root["contextCases"] as! [[String: Any]] {
            let messages = (item["messages"] as! [[String: String]]).map { ChatModelRules.MessageStamp(id: $0["id"]!, createdAt: $0["createdAt"]!) }
            let got = ChatModelRules.contextMessageIDs(messages: messages, activatedAt: item["activatedAt"] as! String, questionID: item["questionID"] as! String, limit: item["limit"] as! Int)
            XCTAssertEqual(got, item["expect"] as! [String], "\(item["name"]!)")
        }
        for item in root["sanitizeCases"] as! [[String: Any]] {
            let got = ChatModelRules.sanitizeAnswer(item["text"] as! String)
            XCTAssertEqual(got, item["expect"] as! String, "\(item["name"]!)")
            XCTAssertEqual(got.unicodeScalars.count, item["expectScalarCount"] as! Int, "\(item["name"]!)")
        }
    }

    /// Guards the meaning of a few cases, so a regenerated file cannot quietly flip them.
    func testKeyExpectationsHold() throws {
        let fixture = Self.buildFixture()
        let scenarios = Dictionary(uniqueKeysWithValues: (fixture["ledgerScenarios"] as! [[String: Any]]).map { ($0["name"] as! String, $0["steps"] as! [[String: Any]]) })
        func last(_ name: String, _ index: Int) -> [String: Any] { scenarios[name]![index]["expect"] as! [String: Any] }

        XCTAssertEqual(last("all_members_must_say_yes", 0)["status"] as? String, "proposed")
        XCTAssertEqual(last("all_members_must_say_yes", 1)["status"] as? String, "active")
        XCTAssertEqual(last("one_no_blocks_activation", 2)["status"] as? String, "proposed")
        XCTAssertEqual(last("withdraw_after_activation_stops_model", 2)["modelConsentHolds"] as? Bool, false)
        XCTAssertEqual(last("newcomer_after_activation_keeps_model_but_blocks_external", 2)["modelConsentHolds"] as? Bool, true)
        XCTAssertEqual(last("newcomer_after_activation_keeps_model_but_blocks_external", 2)["externalAllowed"] as? Bool, false)
        XCTAssertEqual(last("newcomer_after_activation_keeps_model_but_blocks_external", 3)["externalAllowed"] as? Bool, true)
        XCTAssertEqual(last("external_needs_everyones_explicit_yes", 1)["externalAllowed"] as? Bool, false)
        XCTAssertEqual(last("remove_then_propose_again", 3)["refusal"] as? String, "no_proposal")
        XCTAssertEqual(last("refusals", 1)["refusal"] as? String, "not_member")
        XCTAssertEqual(last("refusals", 3)["refusal"] as? String, "already_present")
        XCTAssertEqual(last("everyone_leaves", 1)["modelConsentHolds"] as? Bool, false)
    }
}
