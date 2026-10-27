// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// PDD kunstnerside-som-flate, capabilities C (image from data), D (whole
/// element as link), E (theme colours from data) and F (audio element).
final class SkeletonDataBindingTests: XCTestCase {
    private func decodeElement(_ json: String) throws -> SkeletonElement {
        try JSONDecoder().decode(SkeletonElement.self, from: Data(json.utf8))
    }

    private func roundTrip(_ element: SkeletonElement) throws -> SkeletonElement {
        try JSONDecoder().decode(SkeletonElement.self, from: JSONEncoder().encode(element))
    }

    private let work: ValueType = .object([
        "id": .string("work-ss-02"),
        "title": .string("Slumbering Stones II"),
        "link": .string("/pub/sindre-hustveit/verk/work-ss-02"),
        "media": .object(["preview": .string("/pub/sindre-hustveit/verk/work-ss-02/preview")]),
        "theme": .object(["accent": .string("#4a4a46"), "ink": .string("not-a-colour"), "script": .string("#ffffff")]),
        "track": .object(["src": .string("https://example.org/a.mp3"), "title": .string("Spill sang")])
    ])

    // MARK: C

    func testImageURLKeypathRoundTripsAndResolvesDottedPath() throws {
        let element = try decodeElement("""
        {"Image": {"urlKeypath": "media.preview", "altKeypath": "title", "alt": "Verk"}}
        """)
        guard case let .Image(image) = try roundTrip(element) else { return XCTFail("Expected Image") }
        XCTAssertEqual(image.urlKeypath, "media.preview")
        XCTAssertEqual(image.altKeypath, "title")
        XCTAssertEqual(image.resolvedURLString(item: work), "/pub/sindre-hustveit/verk/work-ss-02/preview")
        XCTAssertEqual(image.resolvedAlt(item: work), "Slumbering Stones II")
    }

    func testImageWithKeypathAndNoRowValueHasNoURL() throws {
        guard case let .Image(image) = try decodeElement("""
        {"Image": {"url": "https://example.org/fallback.png", "urlKeypath": "media.preview", "alt": "Bilde mangler"}}
        """) else { return XCTFail("Expected Image") }
        let withoutImage: ValueType = .object(["id": .string("work-ss-04")])
        XCTAssertNil(image.resolvedURLString(item: withoutImage), "A row without an image must show the missing state, not the template image")
        XCTAssertEqual(image.resolvedAlt(item: withoutImage), "Bilde mangler")
    }

    func testStaticImageIsUnchangedAndEncodesNoNewKeys() throws {
        guard case let .Image(image) = try decodeElement("""
        {"Image": {"url": "https://example.org/logo.png"}}
        """) else { return XCTFail("Expected Image") }
        XCTAssertEqual(image.resolvedURLString(item: nil), "https://example.org/logo.png")
        let json = String(decoding: try JSONEncoder().encode(SkeletonElement.Image(image)), as: UTF8.self)
        XCTAssertFalse(json.contains("urlKeypath"))
        XCTAssertFalse(json.contains("altKeypath"))
    }

    // MARK: D

    func testLinkModifiersRoundTripAndRowValueWins() throws {
        let element = try decodeElement("""
        {"VStack": {"elements": [{"Text": {"text": "Kort"}}],
                    "modifiers": {"linkURL": "/pub/sindre-hustveit/verk", "linkURLKeypath": "link"}}}
        """)
        guard case let .VStack(stack) = try roundTrip(element) else { return XCTFail("Expected VStack") }
        XCTAssertEqual(stack.modifiers?.linkURLKeypath, "link")
        XCTAssertEqual(SkeletonDataBinding.linkURL(stack.modifiers, item: work), "/pub/sindre-hustveit/verk/work-ss-02")
        XCTAssertEqual(SkeletonDataBinding.linkURL(stack.modifiers, item: nil), "/pub/sindre-hustveit/verk")
    }

    func testBlankLinkIsAFormatError() {
        XCTAssertThrowsError(try JSONDecoder().decode(SkeletonModifiers.self, from: Data(#"{"linkURL": "  "}"#.utf8)))
    }

    func testAuditReportsLinkInsideElementLink() throws {
        let element = try decodeElement("""
        {"VStack": {"elements": [
            {"Text": {"text": "Tittel"}},
            {"Button": {"keypath": "", "label": "Les mer", "url": "https://example.org/x"}},
            {"HStack": {"elements": [{"Text": {"text": "Indre"}}], "modifiers": {"linkURLKeypath": "link"}}}
        ], "modifiers": {"linkURLKeypath": "link"}}}
        """)
        let nested = SkeletonReachabilityAudit.audit(element).filter { $0.kind == .nestedLink }
        XCTAssertEqual(nested.count, 2, "Both the link button and the inner linked stack sit inside the card link")
    }

    func testAuditAcceptsSingleElementLink() throws {
        let element = try decodeElement("""
        {"VStack": {"elements": [{"Text": {"text": "Tittel"}}], "modifiers": {"linkURLKeypath": "link"}}}
        """)
        XCTAssertTrue(SkeletonReachabilityAudit.audit(element).filter { $0.kind == .nestedLink }.isEmpty)
    }

    // MARK: E

    func testStyleVariablesRoundTrip() throws {
        let modifiers = try JSONDecoder().decode(SkeletonModifiers.self, from: Data("""
        {"styleVariables": {"accent": "#4a4a46", "paper": "#ffffffff"}, "styleVariablesKeypath": "theme"}
        """.utf8))
        let decoded = try JSONDecoder().decode(SkeletonModifiers.self, from: JSONEncoder().encode(modifiers))
        XCTAssertEqual(decoded.styleVariables, ["accent": "#4a4a46", "paper": "#ffffffff"])
        XCTAssertEqual(decoded.styleVariablesKeypath, "theme")
    }

    func testUnknownStyleVariableNameIsAFormatError() {
        XCTAssertThrowsError(try JSONDecoder().decode(SkeletonModifiers.self,
            from: Data(##"{"styleVariables": {"font": "#000000"}}"##.utf8))) { error in
            XCTAssertEqual((error as? SkeletonFormatError)?.field, "styleVariables.font")
        }
    }

    func testNonColourStyleVariableIsAFormatError() {
        XCTAssertThrowsError(try JSONDecoder().decode(SkeletonModifiers.self,
            from: Data(#"{"styleVariables": {"accent": "red; background: url(x)"}}"#.utf8)))
    }

    func testDataStyleVariablesOverrideTemplateAndDropInvalidEntries() {
        var modifiers = SkeletonModifiers()
        modifiers.styleVariables = ["accent": "#111111", "line": "#222222"]
        modifiers.styleVariablesKeypath = "theme"
        let resolved = SkeletonStyleVariables.resolve(modifiers, item: work)
        XCTAssertEqual(resolved, ["accent": "#4a4a46", "line": "#222222"])
    }

    func testColourFormat() {
        XCTAssertTrue(SkeletonStyleVariables.isColor("#4a4a46"))
        XCTAssertTrue(SkeletonStyleVariables.isColor("#4A4A46FF"))
        XCTAssertFalse(SkeletonStyleVariables.isColor("#fff"))
        XCTAssertFalse(SkeletonStyleVariables.isColor("4a4a46"))
        XCTAssertFalse(SkeletonStyleVariables.isColor("#4a4a4g"))
    }

    // MARK: F

    func testAudioRoundTripsAndResolvesFromRow() throws {
        let element = try decodeElement("""
        {"Audio": {"srcKeypath": "track.src", "titleKeypath": "track.title", "mimeType": "audio/mpeg"}}
        """)
        guard case let .Audio(audio) = try roundTrip(element) else { return XCTFail("Expected Audio") }
        XCTAssertEqual(audio.mimeType, "audio/mpeg")
        XCTAssertEqual(audio.resolvedSource(item: work), "https://example.org/a.mp3")
        XCTAssertEqual(audio.resolvedTitle(item: work), "Spill sang")
        XCTAssertNil(audio.resolvedSource(item: .object([:])))
    }

    func testAudioWithoutSourceDecodesAsUnsupportedAndIsAudited() throws {
        let element = try decodeElement(#"{"Audio": {"title": "Uten kilde"}}"#)
        guard case let .Unsupported(unsupported) = element else { return XCTFail("Expected Unsupported") }
        XCTAssertEqual(unsupported.elementType, "Audio")
        XCTAssertTrue(SkeletonReachabilityAudit.audit(element).contains { $0.kind == .unsupportedElement })
    }

    func testAudioWithSourceHasNoAuditFindings() throws {
        let element = try decodeElement(#"{"Audio": {"src": "https://example.org/a.mp3"}}"#)
        XCTAssertTrue(SkeletonReachabilityAudit.audit(element).isEmpty)
    }
}
