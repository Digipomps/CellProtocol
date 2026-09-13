import Foundation
import XCTest
@testable import CellBase

final class CellStoragePathPolicyTests: XCTestCase {
    func testMissingChildrenUnderAnExistingPrivateTmpRootRemainConfined() throws {
        #if os(macOS)
        let root = URL(fileURLWithPath: "/private/tmp/path-alias-\(UUID().uuidString)")
        #else
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #endif
        defer { try? FileManager.default.removeItem(at: root) }
        // The result must not change when an ancestor is created.
        for createRoot in [false, true] {
            if createRoot { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
            let child = try CellStoragePathPolicy.component("new-cell", under: root)
            let nested = try CellStoragePathPolicy.relativePath("new-cell/nested", under: root)
            let file = try CellStoragePathPolicy.filename("typedCell.json", under: nested)
            XCTAssertTrue(child.path.hasSuffix("/new-cell"))
            XCTAssertTrue(file.path.hasSuffix("/new-cell/nested/typedCell.json"))
            XCTAssertNoThrow(try CellStoragePathPolicy.existingURL(nested, under: root))
        }
    }

    func testMissingChildrenCannotHideSymlinkEscapeOrDanglingLinks() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("storage")
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let escape = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        XCTAssertThrowsError(try CellStoragePathPolicy.relativePath("escape/missing/file", under: root))
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: outside.appendingPathComponent("missing"))
        XCTAssertThrowsError(try CellStoragePathPolicy.relativePath("dangling/new", under: root))
        let inside = root.appendingPathComponent("inside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: inside)
        XCTAssertNoThrow(try CellStoragePathPolicy.relativePath("alias/new", under: root))
        // Physical containment alone must not admit a lexically external path.
        let externalAlias = outside.appendingPathComponent("inside-alias")
        try FileManager.default.createSymbolicLink(at: externalAlias, withDestinationURL: inside)
        XCTAssertThrowsError(try CellStoragePathPolicy.existingURL(externalAlias.appendingPathComponent("new"), under: root))
        XCTAssertThrowsError(try CellStoragePathPolicy.relativePath("../outside", under: root))
        XCTAssertThrowsError(try CellStoragePathPolicy.existingURL(parent.appendingPathComponent("storage-other/new"), under: root))
    }
}
