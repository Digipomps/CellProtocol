// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import HavenCoreSchemas
import KeyPathResolver

final class KeyPathResolverTests: XCTestCase {
    private var commonsRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("commons", isDirectory: true)
    }

    private func makeResolver() throws -> KeyPathResolver {
        let registry = try KeyPathRegistry.load(from: CommonsPaths.keypathsURL(root: commonsRoot))
        return KeyPathResolver(registry: registry)
    }

    func testChroniclePathRoutesToChronicleCell() throws {
        let resolver = try makeResolver()
        let binding = EntityAnchorBinding.seeded(entityId: "entity-1")

        let result = try resolver.resolve(
            entityId: "entity-1",
            path: "#/chronicle/events",
            context: RequesterContext(role: .member),
            binding: binding
        )

        XCTAssertEqual(result.resolvedCellType, "ChronicleCell")
        XCTAssertEqual(result.resolvedCellId, "chronicle:entity-1")
        XCTAssertEqual(result.resolvedLocalPath, "#/events")
        XCTAssertEqual(result.storageDomain, "chronicle-store")
    }

    func testDeprecatedPurposesAliasResolvesToPerspective() throws {
        let resolver = try makeResolver()
        let binding = EntityAnchorBinding.seeded(entityId: "entity-2")

        let result = try resolver.resolve(
            entityId: "entity-2",
            path: "#/purposes",
            context: RequesterContext(role: .owner),
            binding: binding
        )

        XCTAssertEqual(result.canonicalPath, "#/perspective")
        XCTAssertEqual(result.resolvedCellType, "PerspectiveCell")
        XCTAssertEqual(result.resolvedCellId, "perspective:entity-2")
        XCTAssertEqual(result.auditInfo.aliasApplied, "#/purposes")
        XCTAssertTrue(result.auditInfo.deprecatedPath)
    }

    func testSponsorCanOnlyAccessAggregatedPaths() throws {
        let resolver = try makeResolver()
        let binding = EntityAnchorBinding.seeded(entityId: "entity-3")

        let aggregated = try resolver.resolve(
            entityId: "entity-3",
            path: "#/representations/entities",
            context: RequesterContext(role: .sponsor),
            binding: binding
        )

        let consent = try resolver.resolve(
            entityId: "entity-3",
            path: "#/credentials/verifiable",
            context: RequesterContext(role: .sponsor),
            binding: binding
        )

        XCTAssertTrue(aggregated.permission.isAllowed)
        XCTAssertFalse(consent.permission.isAllowed)
    }

    func testConsentPathRequiresTokenForMember() throws {
        let resolver = try makeResolver()
        let binding = EntityAnchorBinding.seeded(entityId: "entity-4")

        let denied = try resolver.resolve(
            entityId: "entity-4",
            path: "#/credentials/verifiable",
            context: RequesterContext(role: .member),
            binding: binding
        )

        let allowed = try resolver.resolve(
            entityId: "entity-4",
            path: "#/credentials/verifiable",
            context: RequesterContext(role: .member, consentTokens: ["#/credentials/*"]),
            binding: binding
        )

        XCTAssertFalse(denied.permission.isAllowed)
        XCTAssertTrue(allowed.permission.isAllowed)
    }

    func testUnknownPathIsResolvedAsOpenReference() throws {
        let resolver = try makeResolver()
        let binding = EntityAnchorBinding.seeded(entityId: "entity-5")

        let result = try resolver.resolve(
            entityId: "entity-5",
            path: "#/custom/football-club/initiative",
            context: RequesterContext(role: .member),
            binding: binding
        )

        XCTAssertEqual(result.canonicalPath, "#/custom/football-club/initiative")
        XCTAssertEqual(result.typeRef, "haven.core#/OpenValue")
        XCTAssertEqual(result.resolvedCellType, "EntityAnchorCell")
        XCTAssertEqual(result.resolvedCellId, "anchor:entity-5")
        XCTAssertFalse(result.auditInfo.registryMatched)
    }

    func testUnknownPerspectiveChildPathStillRoutesToPerspectiveCell() throws {
        let resolver = try makeResolver()
        let binding = EntityAnchorBinding.seeded(entityId: "entity-6")

        let result = try resolver.resolve(
            entityId: "entity-6",
            path: "#/perspective/community/goals",
            context: RequesterContext(role: .member),
            binding: binding
        )

        XCTAssertEqual(result.resolvedCellType, "PerspectiveCell")
        XCTAssertEqual(result.resolvedCellId, "perspective:entity-6")
        XCTAssertEqual(result.typeRef, "haven.perspective#/PerspectiveField")
        XCTAssertTrue(result.auditInfo.registryMatched)
    }
}
