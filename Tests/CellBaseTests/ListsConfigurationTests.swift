// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// WP3 — purpose://candidate.lister.component.single-source, component.plain-surface, component.mount,
/// gui.ways-in-are-reachable, gui.capability-not-client og antiformålet not.silent-section.
///
/// Fasiten er bildet Kjetil godkjente (G1-GUI 2026-10-02): `Fixtures/ListsMineListerApproved.json` er den
/// skjelett-JSON-en bildene ble rendret fra. Fabrikken må gi nøyaktig den.
final class ListsConfigurationTests: XCTestCase {
    private func canonical<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func approvedSkeleton() throws -> SkeletonElement {
        let data = TestFixtures.loadJSON(named: "ListsMineListerApproved.json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let skeletonJSON = try XCTUnwrap(json["skeleton"])
        let skeletonData = try JSONSerialization.data(withJSONObject: skeletonJSON)
        return try JSONDecoder().decode(SkeletonElement.self, from: skeletonData)
    }

    // MARK: factory == godkjent bilde

    func testFactoryProducesTheApprovedSkeletonByteForByte() throws {
        let approved = try canonical(try approvedSkeleton())
        let factory = try canonical(ListsSkeletonFactory.mineListerSkeleton())
        XCTAssertEqual(factory, approved, "fabrikken avviker fra skjelettet bildene ble godkjent på (images/*-v1.png)")
    }

    func testConfigurationMetadataMatchesTheApprovedFile() throws {
        let data = TestFixtures.loadJSON(named: "ListsMineListerApproved.json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let configuration = ListsSkeletonFactory.mineListerConfiguration()
        XCTAssertEqual(configuration.name, json["name"] as? String)
        XCTAssertEqual(configuration.description, json["description"] as? String)
        let discovery = try XCTUnwrap(json["discovery"] as? [String: Any])
        XCTAssertEqual(configuration.discovery?.sourceCellEndpoint, discovery["sourceCellEndpoint"] as? String)
        XCTAssertEqual(configuration.discovery?.sourceCellName, discovery["sourceCellName"] as? String)
        XCTAssertEqual(configuration.discovery?.interests, discovery["interests"] as? [String])
        XCTAssertEqual(configuration.discovery?.menuSlots, discovery["menuSlots"] as? [String])
        let references = try XCTUnwrap(json["cellReferences"] as? [[String: Any]])
        XCTAssertEqual(configuration.cellReferences?.map(\.endpoint), references.compactMap { $0["endpoint"] as? String })
        XCTAssertEqual(configuration.cellReferences?.map(\.label), references.compactMap { $0["label"] as? String })
    }

    // MARK: ett skjelett, to innganger

    func testSurfaceAndMountChecklistsDifferOnlyInKeypathPrefix() throws {
        let surface = try canonical(ListsSkeletonFactory.checklistSkeleton(keypathPrefix: ListsSkeletonFactory.surfacePrefix))
        let mount = try canonical(ListsSkeletonFactory.checklistSkeleton(keypathPrefix: ListsSkeletonFactory.mountPrefix))
        XCTAssertNotEqual(surface, mount)
        let normalized = surface.replacingOccurrences(of: "\"" + ListsSkeletonFactory.surfacePrefix, with: "\"" + ListsSkeletonFactory.mountPrefix)
        XCTAssertEqual(normalized, mount)
        XCTAssertFalse(mount.contains(ListsSkeletonFactory.surfacePrefix), "monteringen skal ikke kjenne Porthole-referansen")
    }

    func testMountDecodesAsComponentMountWithTheListAsItem() throws {
        let list = ListsListRecord(id: "l-1", title: "Handleliste", kind: .shopping, createdAtEpochMs: 1, updatedAtEpochMs: 1,
                                   items: [ListsItemRecord(id: "i-1", title: "Melk", createdAtEpochMs: 1, updatedAtEpochMs: 1)])
        let mount = ListsPayloads.mount(for: list, isActive: true)
        let data = try JSONEncoder().encode(mount)
        let decoded = try JSONDecoder().decode(SkeletonComponentMount.self, from: data)
        XCTAssertEqual(decoded.componentID, "haven.lists.checklist")
        XCTAssertEqual(decoded.revision, "1")
        XCTAssertEqual(decoded.sourceCellEndpoint, "cell:///Lists")
        XCTAssertEqual(decoded.item?["id"], .string("l-1"))
        XCTAssertEqual(try canonical(decoded.skeleton), try canonical(SkeletonElement.VStack(ListsSkeletonFactory.checklistSkeleton(keypathPrefix: "lists."))))
        // Samme vei som rendereren (SkeletonComponentInstance.decode): ValueType → JSON → mount
        let asValue = try JSONDecoder().decode(ValueType.self, from: data)
        let viaValue = try JSONDecoder().decode(SkeletonComponentMount.self, from: try JSONEncoder().encode(asValue))
        XCTAssertEqual(viaValue.componentID, decoded.componentID)
    }

    // MARK: gui.ways-in-are-reachable + not.silent-section

    func testEverySurfaceActionIsReachableAndNothingIsSilent() throws {
        let skeleton = ListsSkeletonFactory.mineListerSkeleton()
        let required = ListsSkeletonFactory.surfaceActionKeypaths
        let findings = SkeletonReachabilityAudit.audit(skeleton, requiredActionKeypaths: required)
        XCTAssertTrue(findings.isEmpty, findings.map { "\($0.kind.rawValue) @ \($0.path): \($0.detail)" }.joined(separator: "\n"))
        let reachable = SkeletonReachabilityAudit.reachableActionKeypaths(skeleton)
        XCTAssertTrue(required.isSubset(of: reachable), "mangler: \(required.subtracting(reachable).sorted())")
    }

    func testMountedChecklistActionsAreReachableInsideARow() throws {
        let element = SkeletonElement.VStack(ListsSkeletonFactory.checklistSkeleton(keypathPrefix: "lists."))
        let required: Set<String> = ["lists.list.rename", "lists.list.remove", "lists.list.clearDone", "lists.item.add", "lists.item.toggle", "lists.item.move", "lists.item.remove"]
        let findings = SkeletonReachabilityAudit.audit(element, context: .row, requiredActionKeypaths: required)
        XCTAssertTrue(findings.isEmpty, findings.map { "\($0.kind.rawValue) @ \($0.path): \($0.detail)" }.joined(separator: "\n"))
    }

    // MARK: gui.capability-not-client — layoutvalg på kapabilitet og plass, ikke klientnavn

    func testArrowsHideWhereTheHostHasDragAndColumnsStackWhenNarrow() throws {
        guard case let .VStack(row) = SkeletonElement.VStack(ListsSkeletonFactory.checklistItemRow(keypathPrefix: "lists.")),
              case let .HStack(line)? = row.elements.first else { return XCTFail("radens form") }
        let buttons = line.elements.compactMap { element -> SkeletonButton? in
            if case let .Button(button) = element { return button }
            return nil
        }
        let arrows = buttons.filter { $0.icon == "chevron.up" || $0.icon == "chevron.down" }
        XCTAssertEqual(arrows.count, 2)
        let web = try SkeletonLayoutContext(availableWidth: 1148, availableHeight: 820, capabilities: [.pointer, .hover, .keyboard, .drag])
        let app = try SkeletonLayoutContext(availableWidth: 358, availableHeight: 844, capabilities: [.touch])
        for arrow in arrows {
            XCTAssertEqual(arrow.modifiers?.layoutVariant(in: web)?.hidden, true, "piler skjules der verten har drag")
            XCTAssertNil(arrow.modifiers?.layoutVariant(in: app), "piler vises uten drag")
        }
        let trash = try XCTUnwrap(buttons.first { $0.icon == "trash" })
        XCTAssertNil(trash.modifiers?.layoutVariant(in: web))

        guard case let .VStack(root) = ListsSkeletonFactory.mineListerSkeleton(),
              case let .HStack(columns)? = root.elements.first else { return XCTFail("flatens form") }
        XCTAssertEqual(columns.modifiers?.layoutVariant(in: app)?.axis, .vertical, "under 700 px stables kolonnene")
        XCTAssertNil(columns.modifiers?.layoutVariant(in: web))
        guard case let .VStack(left)? = columns.elements.first else { return XCTFail("venstre kolonne") }
        XCTAssertEqual(left.modifiers?.layoutVariant(in: web)?.width, 300)
        XCTAssertNil(left.modifiers?.layoutVariant(in: app))
    }

    func testCheckmarkIconsExistInBothRenderersAndUncheckedIsAGlyph() throws {
        let row = ListsSkeletonFactory.checklistItemRow(keypathPrefix: "lists.")
        let json = try canonical(row)
        XCTAssertTrue(json.contains("\"icon\":\"checkmark.circle.fill\""))
        XCTAssertTrue(json.contains("\"label\":\"○\""), "uavkrysset er tekstglyfen ○ fordi webens ikonkart mangler circle (FORMAALSSPEC §0 B11)")
        XCTAssertFalse(json.contains("\"icon\":\"circle\""))
    }
}
