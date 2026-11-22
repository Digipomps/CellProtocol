// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// `skeleton-check` and Cell Configuration Studio report from this check. The
/// cases are the mistakes a student or a model makes first: a row template that
/// is not a VStack, an element the format does not have, a section hidden for
/// good, and a file that is not a CellConfiguration at all.
final class SkeletonConfigurationCheckTests: XCTestCase {

    private func check(_ json: String, required: Set<String> = []) -> SkeletonConfigurationCheckReport {
        SkeletonConfigurationCheck.check(json: Data(json.utf8), requiredActionKeypaths: required)
    }

    private func kinds(_ report: SkeletonConfigurationCheckReport) -> [SkeletonConfigurationCheckFinding.Kind] {
        report.findings.map(\.kind)
    }

    /// The example in the student guide «Lag din egen flate».
    private let todoPanel = """
    {
      "name": "Mitt gjøremålspanel",
      "cellReferences": [
        { "endpoint": "cell:///Todo", "label": "todo", "subscribeFeed": true, "subscriptions": [], "setKeysAndValues": [] }
      ],
      "skeleton": { "VStack": [
        { "Text": { "text": "Mine gjøremål" } },
        { "List": { "keypath": "todo.activeItems", "flowElementSkeleton": { "VStack": [
          { "HStack": { "spacing": 12, "elements": [
            { "VStack": { "spacing": 2, "elements": [ { "Text": { "keypath": "title" } }, { "Text": { "keypath": "dueText" } } ] } },
            { "Spacer": {} },
            { "Button": { "keypath": "todo.toggleTodo", "label": "Ferdig", "payloadKeypath": "id" } }
          ] } } ] } } },
        { "Section": { "header": { "Text": { "text": "Fullført" } }, "content": [
          { "List": { "keypath": "todo.completedItems", "flowElementSkeleton": { "VStack": [ { "Text": { "keypath": "title" } } ] } } }
        ] } }
      ] }
    }
    """

    func testTheGuideExamplePassesAndReachesItsAction() {
        let report = check(todoPanel, required: ["todo.toggleTodo"])
        XCTAssertTrue(report.passed, "\(report.findings)")
        XCTAssertEqual(report.configurationName, "Mitt gjøremålspanel")
        XCTAssertEqual(report.reachableActionKeypaths, ["todo.toggleTodo"])
    }

    func testARowTemplateThatIsNotAVStackIsReported() {
        let json = todoPanel.replacingOccurrences(
            of: #""flowElementSkeleton": { "VStack": [ { "Text": { "keypath": "title" } } ] }"#,
            with: #""flowElementSkeleton": { "Text": { "keypath": "title" } }"#)
        XCTAssertNotEqual(json, todoPanel)
        let report = check(json)
        XCTAssertEqual(kinds(report), [.flowElementNotVStack])
        XCTAssertTrue(report.findings[0].path.hasSuffix(".flowElementSkeleton"), report.findings[0].path)
        XCTAssertTrue(report.findings[0].message.contains("Text"))
    }

    func testAnElementTheFormatDoesNotHaveIsReported() {
        let report = check("""
        { "name": "Notat", "skeleton": { "VStack": [ { "Text": { "text": "Hei" } }, { "Markdown": { "text": "# Hei" } } ] } }
        """)
        XCTAssertEqual(kinds(report), [.unsupportedElement])
        XCTAssertTrue(report.findings[0].message.contains("Markdown"), report.findings[0].message)
    }

    func testASectionGatedOnCellStateAtRootIsReportedWithTheActionItLoses() {
        let report = check("""
        { "name": "Rydd", "skeleton": { "VStack": [
          { "Text": { "text": "Gjøremål" } },
          { "VStack": {
              "elements": [ { "Button": { "keypath": "todo.clearCompleted", "label": "Rydd" } } ],
              "modifiers": { "visibility": { "when": { "scope": "root", "keypath": "todo.completedItems.0", "exists": true } } }
          } }
        ] } }
        """, required: ["todo.clearCompleted"])
        XCTAssertTrue(kinds(report).allSatisfy { $0 == .unreachable }, "\(report.findings)")
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.findings.contains { $0.lostActionKeypaths.contains("todo.clearCompleted") })
        XCTAssertFalse(report.reachableActionKeypaths.contains("todo.clearCompleted"))
    }

    func testARequiredActionThatIsNotOnTheSurfaceIsReported() {
        let report = check(todoPanel, required: ["todo.toggleTodo", "todo.addTodo"])
        XCTAssertEqual(kinds(report), [.unreachable])
        XCTAssertEqual(report.findings[0].lostActionKeypaths, ["todo.addTodo"])
    }

    func testAKnownElementWithBrokenFieldsIsReported() {
        let report = check("""
        { "name": "Notat", "skeleton": { "VStack": [ { "Text": { "text": "Hei" } }, { "Text": "bare en streng" } ] } }
        """)
        XCTAssertTrue(kinds(report).contains(.unsupportedElement), "\(report.findings)")
    }

    func testCapitalisedKeysInsideAButtonPayloadAreDataNotElements() {
        let report = check("""
        { "name": "Start", "skeleton": { "VStack": [
          { "Button": { "keypath": "addConfiguration", "label": "Åpne Studio",
                        "payload": { "configurationLookup": { "name": "Cell Configuration Studio", "Kilde": "x" } } } }
        ] } }
        """, required: ["addConfiguration"])
        XCTAssertTrue(report.passed, "\(report.findings)")
    }

    func testAFileThatIsNotACellConfigurationIsReportedNotThrown() {
        XCTAssertEqual(kinds(check("ikke json")), [.undecodable])
        XCTAssertEqual(kinds(check("[1, 2]")), [.undecodable])
        let missingName = check(#"{ "skeleton": { "Text": { "text": "Hei" } } }"#)
        XCTAssertEqual(kinds(missingName), [.undecodable])
        XCTAssertTrue(missingName.findings[0].message.contains("name"), missingName.findings[0].message)
    }

    func testAConfigurationWithoutSkeletonHasNothingToShow() {
        XCTAssertEqual(kinds(check(#"{ "name": "Tom" }"#)), [.missingSkeleton])
    }

    func testTheDecodedEntryPointAgreesOnADecodableFile() throws {
        let configuration = try JSONDecoder().decode(CellConfiguration.self, from: Data(todoPanel.utf8))
        let report = SkeletonConfigurationCheck.check(configuration: configuration, requiredActionKeypaths: ["todo.toggleTodo"])
        XCTAssertTrue(report.passed, "\(report.findings)")
        XCTAssertEqual(report.reachableActionKeypaths, ["todo.toggleTodo"])
    }
}
