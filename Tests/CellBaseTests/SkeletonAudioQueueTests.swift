// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// H and I (PDD kunstnerside-som-flate, Butterpop step 2): the AudioQueue
/// element and the queue fields on Button.
final class SkeletonAudioQueueTests: XCTestCase {
    private func decodeElement(_ json: String) throws -> SkeletonElement {
        try JSONDecoder().decode(SkeletonElement.self, from: Data(json.utf8))
    }

    private func roundTrip(_ element: SkeletonElement) throws -> SkeletonElement {
        try JSONDecoder().decode(SkeletonElement.self, from: JSONEncoder().encode(element))
    }

    private func track(_ id: String, src: String? = nil, title: String? = nil) -> ValueType {
        var object: Object = ["id": .string(id), "title": .string(title ?? id)]
        if let src { object["src"] = .string(src) }
        return .object(object)
    }

    private var album: ValueType {
        .object([
            "id": .string("morgenlys"),
            "queue": .list([
                track("morgenlys", src: "/butterpop/api/tracks/morgenlys/listen", title: "Morgenlys"),
                track("kveldsrute", title: "Kveldsrute"),
                track("so-much-fun", src: "/butterpop/api/tracks/so-much-fun/listen", title: "So much fun")
            ])
        ])
    }

    func testAudioQueueRoundTrips() throws {
        let element = try decodeElement("""
        {"AudioQueue": {"currentKeypath": "player.current", "endedActionKeypath": "track.playedThrough", "label": "Spiller"}}
        """)
        guard case let .AudioQueue(queue) = try roundTrip(element) else { return XCTFail("Expected AudioQueue") }
        XCTAssertEqual(queue.currentKeypath, "player.current")
        XCTAssertEqual(queue.endedActionKeypath, "track.playedThrough")
        XCTAssertEqual(queue.label, "Spiller")
    }

    func testAudioQueueWithoutFieldsIsValid() throws {
        let element = try decodeElement(#"{"AudioQueue": {}}"#)
        guard case .AudioQueue = element else { return XCTFail("Expected AudioQueue") }
        XCTAssertTrue(SkeletonReachabilityAudit.audit(element).isEmpty)
    }

    func testAudioQueueWithEmptyKeypathDecodesAsUnsupported() throws {
        let element = try decodeElement(#"{"AudioQueue": {"endedActionKeypath": "  "}}"#)
        guard case let .Unsupported(unsupported) = element else { return XCTFail("Expected Unsupported") }
        XCTAssertEqual(unsupported.elementType, "AudioQueue")
        XCTAssertTrue(SkeletonReachabilityAudit.audit(element).contains { $0.kind == .unsupportedElement })
    }

    func testEndedActionIsReachable() throws {
        let element = try decodeElement(#"{"AudioQueue": {"endedActionKeypath": "track.playedThrough"}}"#)
        XCTAssertTrue(SkeletonReachabilityAudit.reachableActionKeypaths(element).contains("track.playedThrough"))
    }

    func testQueueButtonRoundTripsAndNeedsNoActionKeypath() throws {
        let element = try decodeElement("""
        {"Button": {"keypath": "", "label": "Spill sang", "playQueueKeypath": "queue", "playQueueStartKeypath": "id", "playingLabel": "Spiller"}}
        """)
        guard case let .Button(button) = try roundTrip(element) else { return XCTFail("Expected Button") }
        XCTAssertEqual(button.playQueueKeypath, "queue")
        XCTAssertEqual(button.playQueueStartKeypath, "id")
        XCTAssertEqual(button.playingLabel, "Spiller")
        XCTAssertTrue(button.startsAudioQueue)
        XCTAssertTrue(SkeletonReachabilityAudit.audit(element).isEmpty)
    }

    func testQueueFieldsWithoutQueueKeypathAreRejected() throws {
        let element = try decodeElement(#"{"Button": {"keypath": "", "label": "Spill", "playingLabel": "Spiller"}}"#)
        guard case let .Unsupported(unsupported) = element else { return XCTFail("Expected Unsupported") }
        XCTAssertEqual(unsupported.elementType, "Button")
    }

    func testQueueSkipsTracksWithoutSource() {
        let button = SkeletonButton(keypath: "", label: "Spill album", playQueueKeypath: "queue")
        let queue = button.audioQueue(item: album)
        XCTAssertEqual(queue.map(\.id), ["morgenlys", "so-much-fun"], "a paid track without src never enters the queue")
        XCTAssertEqual(queue.first?.src, "/butterpop/api/tracks/morgenlys/listen")
        XCTAssertEqual(queue.first?.title, "Morgenlys")
    }

    func testStartIndexAndPlayingState() {
        let row: ValueType = .object([
            "id": .string("so-much-fun"),
            "queue": SkeletonDataBinding.value(at: "queue", in: album) ?? .null
        ])
        let songButton = SkeletonButton(keypath: "", label: "Spill sang", playQueueKeypath: "queue",
                                        playQueueStartKeypath: "id", playingLabel: "Spiller")
        let queue = songButton.audioQueue(item: row)
        XCTAssertEqual(songButton.audioQueueStartIndex(item: row, queue: queue), 1)
        XCTAssertTrue(songButton.isPlaying(item: row, playingTrackID: "so-much-fun", playingQueueIDs: ["morgenlys", "so-much-fun"]))
        XCTAssertFalse(songButton.isPlaying(item: row, playingTrackID: "morgenlys", playingQueueIDs: ["morgenlys", "so-much-fun"]))

        let albumButton = SkeletonButton(keypath: "", label: "Spill album", playQueueKeypath: "queue", playingLabel: "Spiller")
        XCTAssertEqual(albumButton.audioQueueStartIndex(item: album, queue: queue), 0)
        XCTAssertTrue(albumButton.isPlaying(item: album, playingTrackID: "so-much-fun", playingQueueIDs: ["morgenlys", "so-much-fun"]))
        XCTAssertFalse(albumButton.isPlaying(item: album, playingTrackID: "so-much-fun", playingQueueIDs: ["so-much-fun"]),
                       "another list with the same track is not this album")
        XCTAssertFalse(albumButton.isPlaying(item: album, playingTrackID: nil, playingQueueIDs: []))
    }

    func testCurrentTrackNeedsIdAndSource() {
        XCTAssertNotNil(SkeletonAudioQueueTrack(track("a", src: "/a")))
        XCTAssertNil(SkeletonAudioQueueTrack(track("a")))
        XCTAssertNil(SkeletonAudioQueueTrack(.null))
    }

    func testQueueButtonDoesNotExecuteAnAction() async {
        let button = SkeletonButton(keypath: "track.buy", label: "Spill", playQueueKeypath: "queue")
        let result = await button.execute()
        XCTAssertNil(result)
    }
}
