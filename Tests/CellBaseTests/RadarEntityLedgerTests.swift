// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import CellBase
@testable import CellApple

/// The radar draws what the ledger says. These pin the ledger: events fold
/// into one picture, distance and bearing become a position on the disc,
/// silence fades a blip and then drops it, and a guessed bearing is marked
/// as guessed.
final class RadarEntityLedgerTests: XCTestCase {

    private func event(_ topic: String, _ payload: Object) -> FlowElement {
        var element = FlowElement(title: topic, content: .object(payload), properties: FlowElement.Properties(type: .content, contentType: .object))
        element.topic = topic
        return element
    }

    func testFoundThenProximityBecomesOneBlipWithAPosition() {
        var ledger = RadarEntityLedger()
        ledger.consume(event("scanner.found", ["remoteUUID": .string("peer-1"), "displayName": .string("Vegar")]))
        ledger.consume(event("scanner.proximity", [
            "remoteUUID": .string("peer-1"),
            "distanceMeters": .float(4.0),
            "direction": .object(["x": .float(0), "y": .float(0), "z": .float(-1)])
        ]))
        XCTAssertEqual(ledger.entities.count, 1)
        let spec = ledger.radarSpec()
        guard case let .list(blips)? = spec["blips"], case let .object(blip)? = blips.first else {
            return XCTFail("no blip")
        }
        XCTAssertEqual(blip["label"], .string("Vegar"))
        XCTAssertEqual(blip["distanceText"], .string("4.0 m"))
        XCTAssertEqual(blip["hasDirection"], .bool(true))
        guard case let .float(x)? = blip["x"], case let .float(y)? = blip["y"] else { return XCTFail("no position") }
        XCTAssertEqual(hypot(x, y), 0.5, accuracy: 0.01, "4 m of an 8 m range is halfway out")
        XCTAssertEqual(spec["nearestText"], .string("4.0"))
    }

    func testAnUnknownBearingIsSaidToBeUnknown() {
        var ledger = RadarEntityLedger()
        ledger.consume(event("scanner.found", ["remoteUUID": .string("peer-2"), "distanceMeters": .float(2)]))
        guard case let .list(blips)? = ledger.radarSpec()["blips"], case let .object(blip)? = blips.first else {
            return XCTFail("no blip")
        }
        XCTAssertEqual(blip["hasDirection"], .bool(false))
        // Same peer, same guessed angle every time — a blip must not wander.
        let first = blip["bearingDegrees"]
        XCTAssertEqual(ledger.radarSpec()["blips"].flatMap { if case let .list(l) = $0, case let .object(o)? = l.first { return o["bearingDegrees"] } else { return nil } }, first)
    }

    func testSilenceFadesThenDrops() {
        var ledger = RadarEntityLedger()
        ledger.staleAfter = 10
        let heard = Date(timeIntervalSince1970: 1_000)
        ledger.consume(.found(RadarEntityUpdate(remoteUUID: "peer-3", timestamp: heard)))

        func strength(at now: Date) -> Double {
            guard case let .list(blips)? = ledger.radarSpec(now: now)["blips"],
                  case let .object(blip)? = blips.first,
                  case let .float(value)? = blip["strength"] else { return -1 }
            return value
        }
        XCTAssertEqual(strength(at: heard), 1.0, accuracy: 0.01)
        XCTAssertEqual(strength(at: heard.addingTimeInterval(5)), 0.5, accuracy: 0.01)
        XCTAssertEqual(ledger.prune(now: heard.addingTimeInterval(11)), ["peer-3"])
        XCTAssertTrue(ledger.entities.isEmpty)
    }

    func testAConnectedPeerIsNotPrunedAndSortsFirst() {
        var ledger = RadarEntityLedger()
        ledger.staleAfter = 1
        let old = Date(timeIntervalSince1970: 0)
        ledger.consume(.connected(RadarEntityUpdate(remoteUUID: "far-connected", distanceMeters: 7, timestamp: old)))
        ledger.consume(.found(RadarEntityUpdate(remoteUUID: "near-loose", distanceMeters: 1)))
        XCTAssertEqual(ledger.prune(), [])
        XCTAssertEqual(ledger.entities.map(\.remoteUUID), ["far-connected", "near-loose"])
    }

    func testSelectionSurvivesInTheSpecAndClearsWhenThePeerGoes() {
        var ledger = RadarEntityLedger()
        ledger.staleAfter = 1
        ledger.consume(.found(RadarEntityUpdate(remoteUUID: "peer-5", timestamp: Date(timeIntervalSince1970: 0))))
        ledger.select("peer-5")
        XCTAssertEqual(ledger.radarSpec()["selectedID"], .string("peer-5"))
        ledger.prune()
        XCTAssertEqual(ledger.radarSpec()["selectedID"], .null)
    }

    func testTheSpecDecodesIntoWhatTheViewDraws() {
        var ledger = RadarEntityLedger()
        ledger.consume(.status(RadarEntityUpdate(status: "started")))
        ledger.consume(.found(RadarEntityUpdate(remoteUUID: "peer-6", displayName: "Victoria", distanceMeters: 1.5)))
        let decoded = RadarVisualizationSpec.decode(from: .object(ledger.radarSpec()))
        XCTAssertEqual(decoded?.blips.first?.label, "Victoria")
        XCTAssertEqual(decoded?.sweep, true)
        XCTAssertEqual(decoded?.ringLabels, ["2 m", "4 m", "6 m", "8 m"])
        XCTAssertNil(RadarVisualizationSpec.decode(from: .string("nonsense")))
    }
}
