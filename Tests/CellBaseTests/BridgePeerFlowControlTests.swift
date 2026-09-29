import Foundation
import XCTest
@testable import CellBase

final class BridgePeerFlowControlTests: XCTestCase {
    func testMissingReceiverRetainsEveryByteAndBoundsSequentialFeed() throws {
        let flow = BridgePeerFlowControl(); var charged = 0
        for i in 0..<32 {
            _ = try flow.prepare(Data(repeating: 7, count: 1024), counter: UInt64(i), now: 12) { charged += $0 }
        }
        XCTAssertEqual(flow.outstanding.count, 32)
        XCTAssertEqual(charged, 32 * (1024 + 34 + 65))
        XCTAssertEqual(flow.bytes, charged); XCTAssertEqual(flow.oldest, 12)
        for _ in 0..<10000 {
            XCTAssertThrowsError(try flow.prepare(Data([8]), counter: 32, now: 13) { charged += $0 })
        }
        XCTAssertEqual(flow.outstanding.count, 32)
        flow.retire { charged -= $0 }; flow.retire { charged -= $0 }
        XCTAssertEqual(charged, 0)
    }

    func testReceiptProvesUnpredictableTokenAndCannotReleaseOtherGenerationOrDuplicate() throws {
        for variant in ["guess", "future", "duplicate", "generation"] {
            let sender = BridgePeerFlowControl(), receiver = BridgePeerFlowControl(), fresh = BridgePeerFlowControl()
            var charged = 0
            let data = try sender.prepare(Data([9]), counter: 0, now: 1) { charged += $0 }
            _ = try fresh.prepare(Data([9]), counter: 0, now: 1) { _ in }
            XCTAssertEqual(try receiver.receive(data, counter: 0) { _ in XCTFail() }, Data([9]))
            var ack = try receiver.prepare(nil, counter: 0, now: 2) { _ in }
            if variant == "guess" { ack[10] ^= 1 }
            if variant == "future" { ack[9] = 1 }
            let original = charged
            if variant == "generation" { XCTAssertThrowsError(try fresh.receive(ack, counter: 0) { _ in XCTFail() }) }
            else if variant == "duplicate" {
                XCTAssertEqual(try sender.receive(ack, counter: 0) { charged -= $0 }, Data())
                XCTAssertEqual(charged, 0)
                XCTAssertThrowsError(try sender.receive(ack, counter: 1) { _ in XCTFail() })
            } else {
                XCTAssertThrowsError(try sender.receive(ack, counter: 0) { charged -= $0 })
                XCTAssertEqual(charged, original)
            }
        }
    }

    func testFullDataWindowStillReceiptsAndNoAckLoopWithSustainedTraffic() throws {
        let a = BridgePeerFlowControl(), b = BridgePeerFlowControl()
        var ac: UInt64 = 0, bc: UInt64 = 0, chargedA = 0, chargedB = 0
        for _ in 0..<300 {
            var records: [(UInt64, Data)] = []
            for _ in 0..<32 {
                records.append((ac, try a.prepare(Data(repeating: 3, count: 8192), counter: ac, now: 1) { chargedA += $0 })); ac += 1
            }
            for (counter, data) in records { _ = try b.receive(data, counter: counter) { chargedB -= $0 } }
            let ack = try b.prepare(nil, counter: bc, now: 1) { chargedB += $0 }; bc += 1
            XCTAssertEqual(try a.receive(ack, counter: bc - 1) { chargedA -= $0 }, Data())
            XCTAssertFalse(a.shouldSendReceipt, "No receipt triggered by a receipt")
            XCTAssertEqual(chargedA, 0)
            XCTAssertEqual(b.outstanding.count, 1, "Next data piggybacks the receipt token")
            XCTAssertLessThan(chargedB, 4096)
        }
        a.retire { chargedA -= $0 }; b.retire { chargedB -= $0 }
        XCTAssertEqual(chargedA, 0); XCTAssertEqual(chargedB, 0)
    }

    func testLargeFramesAndControlFloodAreBoundedWithoutQuotaReleaseAtEnqueue() throws {
        let a = BridgePeerFlowControl()
        var charged = 0
        let largest = BridgePeerRecordLayer.maximumPlaintext - 34
        _ = try a.prepare(Data(repeating: 4, count: largest), counter: 0, now: 1) { charged += $0 }
        XCTAssertThrowsError(try a.prepare(Data(repeating: 4, count: largest), counter: 1, now: 2) { charged += $0 })
        XCTAssertEqual(a.bytes, charged)
        let receiver = BridgePeerFlowControl()
        for i in 0..<64 {
            // Malicious sender never acknowledges our controls, using locally
            // generated fresh data frames to bypass its own normal send window.
            let attacker = BridgePeerFlowControl()
            let frame = try attacker.prepare(Data([1]), counter: UInt64(i), now: 1) { _ in }
            _ = try receiver.receive(frame, counter: UInt64(i)) { _ in XCTFail() }
            _ = try receiver.prepare(nil, counter: UInt64(i), now: 1) { _ in }
        }
        let frame = try BridgePeerFlowControl().prepare(Data([1]), counter: 64, now: 1) { _ in }
        _ = try receiver.receive(frame, counter: 64) { _ in XCTFail() }
        XCTAssertThrowsError(try receiver.prepare(nil, counter: 64, now: 1) { _ in XCTFail() })
        XCTAssertEqual(receiver.outstanding.count, 64)
        XCTAssertLessThan(receiver.bytes, 16 * 1024)
    }
}
