// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import CellBase
#if canImport(JavaScriptCore)
import CellApple
#endif
#if canImport(AppKit)
import AppKit
import SwiftUI
#endif

final class SkeletonLocalizationTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("fixtures/localization/\(name).json"))
    }

    func testLocalizedConfigurationRoundTripPreservesMetadataActionsAndLiteralFallbacks() throws {
        let config = try JSONDecoder().decode(CellConfiguration.self, from: fixture("skeleton"))
        let encoded = try JSONEncoder().encode(config)
        let copy = try JSONDecoder().decode(CellConfiguration.self, from: encoded)
        XCTAssertEqual(config.localization, copy.localization)
        XCTAssertEqual(copy.localization?.catalogs.first?.revision, "1")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let elements = try XCTUnwrap((json["skeleton"] as? [String: Any])?["VStack"] as? [[String: Any]])
        let button = try XCTUnwrap(elements[3]["Button"] as? [String: Any])
        XCTAssertEqual(button["label"] as? String, "Lagre")
        XCTAssertEqual(button["keypath"] as? String, "demo.save")
        XCTAssertEqual((button["payload"] as? [String: Any])?["kind"] as? String, "track")
        XCTAssertNotNil((button["modifiers"] as? [String: Any])?["localization"])
    }

    func testOldConfigurationNeedsNoLocalizationFields() throws {
        let data = Data(#"{"name":"Old","skeleton":{"Text":{"text":"Literal user content"}}}"#.utf8)
        let config = try JSONDecoder().decode(CellConfiguration.self, from: data)
        XCTAssertNil(config.localization)
        guard case .Text(let text)? = config.skeleton else { return XCTFail("Expected Text") }
        XCTAssertNil(text.modifiers?.localization)
        XCTAssertEqual(text.text, "Literal user content")
    }

    func testRootProjectionDeduplicatesArgumentsAndExcludesItemLabels() throws {
        let config = try JSONDecoder().decode(CellConfiguration.self, from: fixture("skeleton"))
        XCTAssertEqual(config.skeleton?.localizationRootKeypaths, ["demo.trackCount"])
        let payload = try JSONDecoder().decode(SkeletonElement.self, from: Data(#"{"Button":{"label":"Save","keypath":"demo.save","payload":{"modifiers":{"localization":{"text":{"valueKeypath":"demo.unrelatedData"}}}}}}"#.utf8))
        XCTAssertEqual(payload.localizationRootKeypaths, [], "Action data must not become a localization read")
    }

    func testAmbiguousAndUnsafeBindingsAreRejected() {
        let invalid = [
            #"{"namespace":"demo","key":"title","valueKeypath":"label"}"#,
            #"{"valueKeypath":"constructor.name","scope":"item"}"#,
            #"{"namespace":"demo","key":"count","arguments":{"count":{"value":1,"keypath":"count"}}}"#,
            #"{"valueKeypath":"label","scope":"unknown"}"#
        ]
        for json in invalid {
            XCTAssertThrowsError(try JSONDecoder().decode(SkeletonLocalizedText.self, from: Data(json.utf8)), json)
        }
    }

    #if canImport(JavaScriptCore)
    func testAppleAdmissionRejectsUnsupportedLocalizationSlots() throws {
        let skeleton = try JSONDecoder().decode(SkeletonElement.self, from: Data(#"{"TextField":{"modifiers":{"localization":{"text":{"namespace":"demo","key":"title"}}}}}"#.utf8))
        XCTAssertThrowsError(try SkeletonLocalizationRuntime().configure(nil, skeleton: skeleton))
    }

    func testAppleAdapterUsesSharedMessageCorpus() throws {
        struct Corpus: Decodable {
            struct Sample: Decodable {
                let id: String; let locale: String; let key: String
                let arguments: [String: LocalizationArgumentValue]
                let expected: String; let fallbackReason: String?
            }
            let configuration: SkeletonLocalizationConfiguration
            let cases: [Sample]
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: fixture("messages"))
        let runtime = SkeletonLocalizationRuntime()
        XCTAssertNil(runtime.initializationError)
        try runtime.configure(corpus.configuration)
        for sample in corpus.cases {
            try runtime.setLocale(sample.locale)
            let descriptor = SkeletonLocalizedText(namespace: "demo", key: sample.key,
                arguments: sample.arguments.mapValues { LocalizationArgumentBinding(value: $0) })
            let result = try runtime.resolve(descriptor, fallback: "Legacy")
            XCTAssertEqual(result.text, sample.expected, sample.id)
            XCTAssertEqual(result.fallbackReason, sample.fallbackReason, sample.id)
        }
    }

    func testLanguageAndArgumentUpdatesDoNotMutateSourceConfiguration() throws {
        let config = try JSONDecoder().decode(CellConfiguration.self, from: fixture("skeleton"))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(config)
        let runtime = SkeletonLocalizationRuntime()
        try runtime.configure(config.localization)
        let descriptor = SkeletonLocalizedText(namespace: "demo", key: "count",
            arguments: ["count": .init(keypath: "demo.trackCount")])
        try runtime.setRootData(.object(["demo": .object(["trackCount": .integer(1)])]))
        try runtime.setLocale("en-US")
        XCTAssertEqual(try runtime.resolve(descriptor, fallback: "Spor").text, "1 track")
        try runtime.setRootData(.object(["demo": .object(["trackCount": .integer(3)])]))
        XCTAssertEqual(try runtime.resolve(descriptor, fallback: "Spor").text, "3 tracks")
        try runtime.setLocale("nb-NO")
        XCTAssertEqual(try runtime.resolve(descriptor, fallback: "Spor").text, "3 spor")
        XCTAssertEqual(try encoder.encode(config), before)
        XCTAssertEqual(runtime.metrics()["compilations"], 2)
    }
    #endif

    #if canImport(AppKit)
    @MainActor
    func testRequesterChangeClearsAcceptedCatalogsAndPrivateArgumentSnapshot() async throws {
        let config = try JSONDecoder().decode(CellConfiguration.self, from: fixture("skeleton"))
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "localization-a", makeNewIfNotFound: true)!
        let nextOwner = await vault.identity(for: "localization-b", makeNewIfNotFound: true)!
        let model = PortholeViewModel()
        model.rememberRequesterIdentity(owner)
        model.configureLocalization(for: config)
        try model.setLocalizationLocale("en-US")
        let title = SkeletonLocalizedText(namespace: "demo", key: "title")
        XCTAssertEqual(model.localization.text(title, fallback: "Reserve"), "Music studio")
        model.rememberRequesterIdentity(nextOwner)
        XCTAssertEqual(model.localization.text(title, fallback: "Reserve"), "Reserve")
        XCTAssertEqual(model.localization.metrics()["cachedMessages"], 0)
    }

    @MainActor
    func testHostedAppleSkeletonChangesLanguageWithoutReplacingItsInputOrSource() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let previousResolver = CellBase.defaultCellResolver
        defer { CellBase.defaultIdentityVault = previousVault; CellBase.defaultCellResolver = previousResolver }
        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault; CellBase.defaultCellResolver = resolver
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let config = try JSONDecoder().decode(CellConfiguration.self, from: fixture("skeleton"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("skeleton")) as? [String: Any])
        let rootData = try JSONDecoder().decode(ValueType.self, from: JSONSerialization.data(withJSONObject: json["testData"]!))
        await cell.addInterceptForGet(requester: owner, key: "demo.trackCount") { _, _ in .integer(2) }
        await cell.addInterceptForGet(requester: owner, key: "demo.draft") { _, _ in .string("My unfinished song") }
        try await resolver.registerNamedEmitCell(name: "Porthole", emitCell: cell, scope: .scaffoldUnique, identity: owner)
        if let interests = rootData["demo"]?["interests"] {
            _ = try await resolver.set(value: interests, into: URL(string: "cell:///Porthole/demo.interests")!, requester: owner)
        }
        let model = PortholeViewModel()
        model.rememberRequesterIdentity(owner)
        model.configureLocalization(for: config)
        try model.setLocalizationLocale("nb-NO", timeZone: "UTC")
        try model.setLocalizationData(rootData)
        let element = try XCTUnwrap(config.skeleton)
        // Materialize SwiftUI's otherwise lazy accessibility tree in this
        // standalone XCTest host (the setting is scoped to this process).
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApplication.shared.accessibilityAttributeValue(accessibilityMode)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: accessibilityMode)
        defer { NSApplication.shared.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode) }
        let host = NSHostingView(rootView: SkeletonView(element: element).environmentObject(model))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let input = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        input.stringValue = "My unsaved native draft"
        window.makeFirstResponder(input)
        let fieldEditor = try XCTUnwrap(window.fieldEditor(false, for: input) as? NSTextView)
        fieldEditor.setSelectedRange(NSRange(location: 3, length: 6))
        let artifactDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HAVEN_LOCALIZATION_ARTIFACT_DIR"] ?? "/private/tmp/haven-localization-native")
        try FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        func snapshot(_ name: String) throws {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: artifactDir.appendingPathComponent(name + ".png"))
        }
        try snapshot("nb")
        let initialMutationVersion = model.localMutationVersion
        try model.setLocalizationLocale("en-US", timeZone: "UTC")
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(descendants(host).contains { $0 === input })
        XCTAssertEqual(fieldEditor.string, "My unsaved native draft")
        XCTAssertEqual(fieldEditor.selectedRange(), NSRange(location: 3, length: 6))
        XCTAssertEqual(model.localMutationVersion, initialMutationVersion)
        XCTAssertEqual(input.placeholderString, "Track title")
        var texts: [String] = []
        var visited = Set<ObjectIdentifier>()
        func readAccessibility(_ object: Any) {
            guard let node = object as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return }
            // SwiftUI accessibility objects implement the Objective-C accessors
            // without necessarily declaring NSAccessibilityProtocol conformance.
            func attribute(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                guard node.responds(to: selector) else { return nil }
                return node.perform(selector)?.takeUnretainedValue()
            }
            if let label = attribute("accessibilityLabel") as? String { texts.append(label) }
            if let value = attribute("accessibilityValue") as? String { texts.append(value) }
            for child in attribute("accessibilityChildren") as? [Any] ?? [] { readAccessibility(child) }
        }
        descendants(host).forEach(readAccessibility)
        XCTAssertTrue(texts.contains("Music studio"), texts.joined(separator: " | "))
        XCTAssertTrue(texts.contains("2 tracks"), texts.joined(separator: " | "))
        XCTAssertTrue(texts.contains("Save"), texts.joined(separator: " | "))
        try snapshot("en")
        try texts.joined(separator: "\n").write(to: artifactDir.appendingPathComponent("accessibility-en.txt"), atomically: true, encoding: .utf8)
    }
    #endif
}
