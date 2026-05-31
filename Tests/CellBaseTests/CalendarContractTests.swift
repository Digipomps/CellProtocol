// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class CalendarContractTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    func testCalendarItemObjectRoundTripsCanonicalFields() throws {
        let item = CalendarItem(
            id: "item-1",
            uid: "uid-1@example.test",
            title: "Planning",
            description: "Discuss V1 calendar",
            time: CalendarTime(startAt: "2026-06-04T09:00:00Z", endAt: "2026-06-04T10:00:00Z", timezone: "UTC"),
            location: CalendarLocation(name: "Room A"),
            recurrence: CalendarRecurrence(rrule: "FREQ=DAILY;COUNT=2"),
            tags: ["calendar", "v1"]
        )

        let object = item.asObject()
        let parsed = try XCTUnwrap(CalendarItem.fromObject(object))

        XCTAssertEqual(parsed.schema, CalendarContract.itemSchema)
        XCTAssertEqual(parsed.id, "item-1")
        XCTAssertEqual(parsed.uid, "uid-1@example.test")
        XCTAssertEqual(parsed.time.startAt, "2026-06-04T09:00:00Z")
        XCTAssertEqual(parsed.recurrence?.rrule, "FREQ=DAILY;COUNT=2")
        XCTAssertEqual(parsed.tags, ["calendar", "v1"])
    }

    func testOccurrenceExpansionHandlesRRuleExDateAndRDate() throws {
        let item = CalendarItem(
            id: "daily",
            uid: "daily@example.test",
            title: "Daily standup",
            time: CalendarTime(startAt: "2026-06-04T09:00:00Z", endAt: "2026-06-04T09:30:00Z"),
            recurrence: CalendarRecurrence(
                rrule: "FREQ=DAILY;COUNT=3",
                rdate: ["2026-06-08T09:00:00Z"],
                exdate: ["2026-06-05T09:00:00Z"]
            )
        )

        let occurrences = CalendarOccurrenceExpander.occurrences(
            for: item,
            rangeStart: try XCTUnwrap(CalendarDateCodec.date(from: "2026-06-04T00:00:00Z")),
            rangeEnd: try XCTUnwrap(CalendarDateCodec.date(from: "2026-06-09T00:00:00Z"))
        )

        XCTAssertEqual(occurrences.map(\.startAt), [
            "2026-06-04T09:00:00Z",
            "2026-06-06T09:00:00Z",
            "2026-06-08T09:00:00Z"
        ])
    }

    func testICSRoundTripPreservesUIDAndRecurrence() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:meeting-1@example.test
        DTSTART:20260604T090000Z
        DTEND:20260604T100000Z
        SUMMARY:Calendar Review
        DESCRIPTION:Review canonical calendar schema
        LOCATION:Room B
        RRULE:FREQ=WEEKLY;COUNT=2
        EXDATE:20260611T090000Z
        STATUS:CONFIRMED
        END:VEVENT
        END:VCALENDAR
        """

        let imported = CalendarICSCodec.importItems(text: ics)
        let item = try XCTUnwrap(imported.items.first)
        XCTAssertEqual(item.uid, "meeting-1@example.test")
        XCTAssertEqual(item.title, "Calendar Review")
        XCTAssertEqual(item.recurrence?.rrule, "FREQ=WEEKLY;COUNT=2")
        XCTAssertEqual(item.recurrence?.exdate, ["2026-06-11T09:00:00Z"])

        let exported = CalendarICSCodec.exportItems([item])
        XCTAssertTrue(exported.text.contains("UID:meeting-1@example.test"))
        XCTAssertTrue(exported.text.contains("RRULE:FREQ=WEEKLY;COUNT=2"))

        let reimported = CalendarICSCodec.importItems(text: exported.text)
        XCTAssertEqual(reimported.items.first?.uid, item.uid)
        XCTAssertEqual(reimported.items.first?.time.startAt, item.time.startAt)
    }

    func testCalendarStoreAdvertisesCompleteContractsAndCreatesItem() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "calendar-tests", makeNewIfNotFound: true)!
        let cell = await CalendarStoreCell(owner: owner)

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: CalendarContract.Keys.state,
            requester: owner,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "object"
        )
        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: CalendarContract.Keys.createItem,
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "object"
        )

        let item = CalendarItem(
            id: "created",
            uid: "created@example.test",
            title: "Created from test",
            time: CalendarTime(startAt: "2026-06-04T11:00:00Z", endAt: "2026-06-04T12:00:00Z")
        )
        let createResult = try await cell.set(keypath: CalendarContract.Keys.createItem, value: .object(item.asObject()), requester: owner)
        let createObject = try XCTUnwrap(CalendarValueCodec.object(createResult))
        XCTAssertEqual(CalendarValueCodec.string(createObject["status"]), "created")

        let state = try await cell.get(keypath: CalendarContract.Keys.state, requester: owner)
        let stateObject = try XCTUnwrap(CalendarValueCodec.object(state))
        XCTAssertEqual(CalendarValueCodec.string(stateObject["schema"]), CalendarContract.stateSchema)
        XCTAssertEqual(CalendarValueCodec.list(stateObject["items"]).count, 1)
        let visualization = try XCTUnwrap(CalendarValueCodec.object(stateObject["visualization"]))
        XCTAssertEqual(CalendarValueCodec.string(visualization["schema"]), CalendarContract.visualizationSchema)
    }

    func testVisualizationCalendarSkeletonEncodesAndDecodes() throws {
        let spec = CalendarVisualizationSpec(
            view: "week",
            range: CalendarVisualizationRange(startAt: "2026-06-04T00:00:00Z", endAt: "2026-06-11T00:00:00Z"),
            occurrences: [
                CalendarOccurrence(
                    id: "occ-1",
                    itemId: "item-1",
                    uid: "uid-1",
                    title: "Calendar Review",
                    startAt: "2026-06-04T09:00:00Z",
                    endAt: "2026-06-04T10:00:00Z",
                    status: "confirmed",
                    availability: "busy",
                    item: CalendarItem(
                        id: "item-1",
                        uid: "uid-1",
                        title: "Calendar Review",
                        time: CalendarTime(startAt: "2026-06-04T09:00:00Z", endAt: "2026-06-04T10:00:00Z")
                    )
                )
            ]
        )
        let element = SkeletonElement.Visualization(SkeletonVisualization(kind: "calendar", spec: .object(spec.asObject())))
        let data = try JSONEncoder().encode(element)
        let decoded = try JSONDecoder().decode(SkeletonElement.self, from: data)

        guard case let .Visualization(visualization) = decoded else {
            return XCTFail("Expected Visualization")
        }
        XCTAssertEqual(visualization.kind, "calendar")
        let object = try XCTUnwrap(CalendarValueCodec.object(visualization.spec))
        XCTAssertEqual(CalendarValueCodec.string(object["schema"]), CalendarContract.visualizationSchema)
        XCTAssertEqual(CalendarValueCodec.string(object["view"]), "week")
    }
}
