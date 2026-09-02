import XCTest
@testable import CellApple
@testable import CellBase

final class PerspectiveCellMatchPayloadTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    func testDirectPurposeMatchUsesMinimumPurposeWeight() async throws {
        let (cell, owner) = await makeCell(sources: [sourcePurpose("Climate Action", weight: 0.8)])
        let result = try await match(
            cell,
            owner: owner,
            targets: [targetPurpose("Climate Action", weight: 0.6)],
            extras: ["allowViaInterests": .bool(false)]
        )

        XCTAssertEqual(integer(result["count"]), 1)
        let hit = try XCTUnwrap(firstObject(result["directPurposeHits"]))
        XCTAssertEqual(string(hit["route"]), "directPurpose")
        XCTAssertEqual(double(hit["matchScore"]), 0.6, accuracy: 0.000_001)
    }

    func testViaInterestScoreIsMinPurposeTimesMinInterest() async throws {
        let source = sourcePurpose("Offer Mentoring", weight: 0.9, interests: [("Swift", 0.7)])
        let (cell, owner) = await makeCell(sources: [source])
        let target = targetPurpose("Find Collaborators", weight: 0.8, interests: [("Swift", 0.5)])
        let result = try await match(cell, owner: owner, targets: [target])

        let hit = try XCTUnwrap(firstObject(result["viaInterestHits"]))
        XCTAssertEqual(string(hit["route"]), "viaInterest")
        XCTAssertEqual(double(hit["matchScore"]), 0.4, accuracy: 0.000_001)
    }

    func testMinimumMatchScoreFiltersBothRoutes() async throws {
        let source = sourcePurpose("Shared", weight: 0.5, interests: [("Topic", 0.5)])
        let (cell, owner) = await makeCell(sources: [source])
        let target = targetPurpose("Shared", weight: 0.5, interests: [("Topic", 0.5)])
        let result = try await match(
            cell,
            owner: owner,
            targets: [target],
            extras: ["minMatchScore": .float(0.51)]
        )

        XCTAssertEqual(integer(result["count"]), 0)
        XCTAssertTrue(list(result["directPurposeHits"]).isEmpty)
        XCTAssertTrue(list(result["viaInterestHits"]).isEmpty)
    }

    func testLimitTruncatesCombinedResultsByScore() async throws {
        let sources = [
            sourcePurpose("One", weight: 0.9),
            sourcePurpose("Two", weight: 0.8),
            sourcePurpose("Three", weight: 0.7)
        ]
        let (cell, owner) = await makeCell(sources: sources)
        let targets = [
            targetPurpose("One", weight: 1),
            targetPurpose("Two", weight: 1),
            targetPurpose("Three", weight: 1)
        ]
        let result = try await match(
            cell,
            owner: owner,
            targets: targets,
            extras: ["limit": .integer(2), "allowViaInterests": .bool(false)]
        )

        XCTAssertEqual(integer(result["count"]), 2)
        let hits = list(result["allHits"]).compactMap(object)
        XCTAssertEqual(hits.compactMap { string($0["sourcePurposeName"]) }, ["One", "Two"])
    }

    func testDuplicateTargetKeysProduceOneDirectHit() async throws {
        let (cell, owner) = await makeCell(sources: [sourcePurpose("Same", weight: 1)])
        let duplicate = targetPurpose("Same", weight: 1)
        let result = try await match(
            cell,
            owner: owner,
            targets: [duplicate, duplicate],
            extras: ["allowViaInterests": .bool(false)]
        )

        XCTAssertEqual(integer(result["count"]), 1)
        XCTAssertEqual(list(result["directPurposeHits"]).count, 1)
    }

    func testSlugifyCollisionUsesPortableDedupKey() async throws {
        let sources = [sourcePurpose("C++", weight: 1), sourcePurpose("C#", weight: 0.8)]
        let (cell, owner) = await makeCell(sources: sources)
        let target: ValueType = .object([
            "purposeName": .string("C"),
            "portablePurposeRef": .string("purpose://c"),
            "purposeWeight": .float(1)
        ])
        let result = try await match(
            cell,
            owner: owner,
            targets: [target],
            extras: ["allowViaInterests": .bool(false)]
        )

        XCTAssertEqual(PortableReference.slugify("C++"), PortableReference.slugify("C#"))
        XCTAssertEqual(integer(result["count"]), 1)
        XCTAssertEqual(list(result["directPurposeHits"]).count, 1)
    }

    private func makeCell(sources: [Weight<Purpose>]) async -> (PerspectiveCell, Identity) {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await PerspectiveCell(owner: owner)
        cell.context = Perspective()
        for source in sources {
            await cell.context.upsertActivePurpose(weighedPurpose: source)
        }
        return (cell, owner)
    }

    private func sourcePurpose(
        _ name: String,
        weight: Double,
        interests: [(String, Double)] = []
    ) -> Weight<Purpose> {
        let weightedInterests = interests.map { name, weight in
            Weight<Interest>(
                weight: weight,
                value: Interest(name: name, types: [], parts: [], partOf: [], purposes: [])
            )
        }
        return Weight<Purpose>(
            weight: weight,
            value: Purpose(name: name, description: "test", interests: weightedInterests)
        )
    }

    private func targetPurpose(
        _ name: String,
        weight: Double,
        interests: [(String, Double)] = []
    ) -> ValueType {
        let interestValues = interests.map { name, weight in
            ValueType.object([
                "interestName": .string(name),
                "portableInterestRef": .string("interest://\(PortableReference.slugify(name))"),
                "interestWeight": .float(weight)
            ])
        }
        return .object([
            "purposeName": .string(name),
            "portablePurposeRef": .string("purpose://\(PortableReference.slugify(name))"),
            "purposeWeight": .float(weight),
            "interests": .list(interestValues)
        ])
    }

    private func match(
        _ cell: PerspectiveCell,
        owner: Identity,
        targets: [ValueType],
        extras: Object = [:]
    ) async throws -> Object {
        var payload = extras
        payload["targetPurposes"] = .list(targets)
        payload["referenceMode"] = .string("portable")
        let value = try await cell.set(
            keypath: "perspective.query.match",
            value: .object(payload),
            requester: owner
        )
        return try XCTUnwrap(value.flatMap(object))
    }

    private func object(_ value: ValueType) -> Object? {
        guard case let .object(object) = value else { return nil }
        return object
    }

    private func firstObject(_ value: ValueType?) -> Object? {
        list(value).first.flatMap(object)
    }

    private func list(_ value: ValueType?) -> [ValueType] {
        guard case let .list(list) = value else { return [] }
        return list
    }

    private func string(_ value: ValueType?) -> String? {
        guard case let .string(string) = value else { return nil }
        return string
    }

    private func integer(_ value: ValueType?) -> Int? {
        guard case let .integer(integer) = value else { return nil }
        return integer
    }

    private func double(_ value: ValueType?) -> Double {
        guard case let .float(double) = value else { return .nan }
        return double
    }
}
