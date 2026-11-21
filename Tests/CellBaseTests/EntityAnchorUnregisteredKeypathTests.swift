// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

#if os(macOS)
import XCTest
@testable import CellBase

// PDD konferanse-mal-eierskap, WP1 (CellProtocolDocuments
// Deliverables/PDD_konferanse-mal-eierskap_2026-11-21).
//
//   test.kme.lagring-rundtur   testWriteEitherReadsBackOrFailsLoudly,
//                              testTemplateRootsAreStoredAndSurviveRestart,
//                              testTemplateRootsRefuseAnotherEntity,
//                              testTemplateRootsDoNotReopenAnchorRoots
//
// WP4 (Kjetil 2026-11-21, «Malen åpner røtter i EntityAnchor»): the roots in
// EntityTemplateRoots are opened in both anchors.
//
// Purpose: a keypath that is not registered is either stored and read back, or
// refused with an error. Never accepted and then gone. The lesson
// lesson.entityanchor-keypaths-are-registered (2026-09-09) says the second case
// happened. This test measures which of the three outcomes each kind of keypath
// gets today, on both anchors, and fails only on a silent loss.
//
// The printed MÅLING lines are the measurement; copy them to TESTRESULT.md#lagring.
final class EntityAnchorUnregisteredKeypathTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousDocumentRoot: String?
    private var previousResolver: CellResolverProtocol?
    private var previousKey: Data?
    private var previousDebug = false
    private var root: URL!

    override func setUp() async throws {
        previousVault = CellBase.defaultIdentityVault
        previousDocumentRoot = CellBase.documentRootPath
        previousResolver = CellBase.defaultCellResolver
        previousKey = CellBase.persistedCellMasterKey
        previousDebug = CellBase.debugValidateAccessForEverything
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("entity-unregistered-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
        CellBase.persistedCellMasterKey = Data(repeating: 0x5a, count: 32)
        CellBase.defaultCellResolver = MockCellResolver()
        CellBase.defaultIdentityVault = MockIdentityVault()
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() async throws {
        CellBase.defaultIdentityVault = previousVault
        CellBase.documentRootPath = previousDocumentRoot
        CellBase.defaultCellResolver = previousResolver
        CellBase.persistedCellMasterKey = previousKey
        CellBase.debugValidateAccessForEverything = previousDebug
        try? FileManager.default.removeItem(at: root)
    }

    private enum Scaffold: String, CaseIterable {
        case local = "CellApple"
        case cloud = "CellVapor"

        func anchor(owner: Identity) async -> GeneralCell {
            switch self {
            case .local: return await AppleEntityAnchorCell(owner: owner)
            case .cloud: return await VaporEntityAnchorCell(owner: owner)
            }
        }

        func restart(_ anchor: GeneralCell) throws -> GeneralCell {
            let snapshot = try JSONEncoder().encode(anchor)
            switch self {
            case .local: return try JSONDecoder().decode(AppleEntityAnchorCell.self, from: snapshot)
            case .cloud: return try JSONDecoder().decode(VaporEntityAnchorCell.self, from: snapshot)
            }
        }
    }

    private enum Outcome: String {
        case stored = "lagret"
        case refused = "avvist"
        case silentLoss = "STILLE TAP"
    }

    /// Keypaths the conference template (mal v0) and Vegar's proposal 1 would write,
    /// plus one dynamic path under an existing root as the control.
    private static let cases: [(keypath: String, why: String)] = [
        ("person.attributes.konferanseKontroll", "kontroll: ny sti under en eksisterende rot"),
        ("event.ownedBy", "mal v0: arrangementets eier (ny rot)"),
        ("project.milestones", "mal v0: prosjektsiden (ny rot)"),
        ("conference.6f1c2d3e-0000-4000-8000-000000000001.role", "Vegars forslag 1: deltakerpost per konferanse (rot i v2, ikke i cellen)"),
        ("groups.6f1c2d3e-0000-4000-8000-000000000002.name", "v2-roten groups: arrangøren som gruppe"),
        ("template.ref", "mal v0: hvilken mal konferansen bygger på (ny rot)"),
    ]

    func testWriteEitherReadsBackOrFailsLoudly() async throws {
        var silentLosses: [String] = []
        for scaffold in Scaffold.allCases {
            let entity = await SimulatedEntity.make("kme-\(scaffold.rawValue)")
            let owner = entity.owner
            let anchor = await scaffold.anchor(owner: owner)
            _ = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: owner)

            for (index, item) in Self.cases.enumerated() {
                let written = ValueType.string("kme-\(scaffold.rawValue)-\(index)")
                var outcome: Outcome
                var detail = ""
                do {
                    let result = try await anchor.set(keypath: item.keypath, value: written, requester: owner)
                    if case let .object(object)? = result, object["status"] == .string("error") {
                        outcome = .refused
                        detail = "svar: \(object)"
                    } else {
                        let readBack = try? await anchor.get(keypath: item.keypath, requester: owner)
                        if readBack == written {
                            outcome = .stored
                        } else {
                            outcome = .silentLoss
                            detail = "set ga \(String(describing: result)), get ga \(String(describing: readBack))"
                        }
                    }
                } catch {
                    outcome = .refused
                    detail = "feil: \(error)"
                }
                print("MÅLING \(scaffold.rawValue) | \(item.keypath) | \(outcome.rawValue) | \(item.why) | \(detail)")
                if outcome == .silentLoss {
                    silentLosses.append("\(scaffold.rawValue) \(item.keypath): \(detail)")
                }
            }
        }
        XCTAssertTrue(silentLosses.isEmpty, "Stille tap: \(silentLosses.joined(separator: "; "))")
    }
    func testTemplateRootsAreStoredAndSurviveRestart() async throws {
        for scaffold in Scaffold.allCases {
            let entity = await SimulatedEntity.make("kme-root-\(scaffold.rawValue)")
            let owner = entity.owner
            let anchor = await scaffold.anchor(owner: owner)
            _ = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: owner)

            let organizer = ValueType.string("11111111-1111-4111-8111-000000000001")
            _ = try await anchor.set(keypath: "event.ownedBy", value: organizer, requester: owner)
            _ = try await anchor.set(keypath: "template.version", value: .string(EntityTemplateRoots.conferenceV0.version), requester: owner)
            let got = try await anchor.get(keypath: "event.ownedBy", requester: owner)
            XCTAssertEqual(got, organizer, scaffold.rawValue)

            let restarted = try scaffold.restart(anchor)
            let afterRestart = try await restarted.get(keypath: "event.ownedBy", requester: owner)
            XCTAssertEqual(afterRestart, organizer, "\(scaffold.rawValue) after restart")
            let version = try await restarted.get(keypath: "template.version", requester: owner)
            XCTAssertEqual(version, .string("0.1.0"), scaffold.rawValue)
        }
    }

    func testTemplateRootsRefuseAnotherEntity() async throws {
        for scaffold in Scaffold.allCases {
            let a = await SimulatedEntity.make("kme-a-\(scaffold.rawValue)")
            let b = await SimulatedEntity.make("kme-b-\(scaffold.rawValue)")
            let anchor = await scaffold.anchor(owner: a.owner)
            _ = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: a.owner)

            var refused = false
            do {
                let result = try await anchor.set(keypath: "event.ownedBy", value: .string("mallory"), requester: b.owner)
                if case let .object(object)? = result, object["status"] == .string("error") { refused = true }
            } catch {
                refused = true
            }
            XCTAssertTrue(refused, "\(scaffold.rawValue): B wrote event.ownedBy")
            do {
                _ = try await anchor.get(keypath: "event", requester: b.owner)
                XCTFail("\(scaffold.rawValue): B read event")
            } catch {
                // refused
            }
            let ownerView = try? await anchor.get(keypath: "event.ownedBy", requester: a.owner)
            XCTAssertNotEqual(ownerView, .string("mallory"), scaffold.rawValue)
        }
    }

    func testTemplateRootsDoNotReopenAnchorRoots() {
        let opened = Set(EntityTemplateRoots.openedRoots)
        XCTAssertEqual(opened.count, EntityTemplateRoots.openedRoots.count, "duplicate roots")
        XCTAssertTrue(opened.isDisjoint(with: EntityTemplateRoots.anchorOwnedRoots),
                      "a template reopens an anchor root: \(opened.intersection(EntityTemplateRoots.anchorOwnedRoots))")
    }
}
#endif
