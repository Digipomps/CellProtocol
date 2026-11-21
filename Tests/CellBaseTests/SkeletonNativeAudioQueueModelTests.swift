// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import CellBase
@testable import CellApple

/// H and I, native: the queue rules of the CellApple player, with a fake
/// playback engine instead of AVPlayer. Mirrors the web renderer's
/// `renderAudioQueue` / `bindAudioQueueButton`.
@MainActor
final class SkeletonNativeAudioQueueModelTests: XCTestCase {
    private final class FakeEngine: SkeletonAudioQueuePlaybackEngine {
        var onEnded: (() -> Void)?
        var onFailed: (() -> Void)?
        var played: [URL] = []
        var pauses = 0
        var resumes = 0
        var stops = 0
        func play(_ url: URL) { played.append(url) }
        func resume() { resumes += 1 }
        func pause() { pauses += 1 }
        func stop() { stops += 1 }
    }

    private var engine: FakeEngine!
    private var sent: [(String, ValueType)] = []

    /// Only https sources are allowed in these tests; "blocked:" stands for a
    /// source the link rules refuse.
    private func makeModel(attach spec: SkeletonAudioQueue? = SkeletonAudioQueue(endedActionKeypath: "track.playedThrough")) -> SkeletonNativeAudioQueueModel {
        let engine = FakeEngine()
        self.engine = engine
        sent = []
        let model = SkeletonNativeAudioQueueModel(engine: { engine }, resolveURL: { raw in
            raw.hasPrefix("https://") ? URL(string: raw) : nil
        })
        if let spec {
            model.attach(spec) { [unowned self] keypath, payload in self.sent.append((keypath, payload)) }
        }
        return model
    }

    private func track(_ id: String, src: String? = nil, title: String? = nil) -> ValueType {
        var object: Object = ["id": .string(id), "title": .string(title ?? id)]
        if let src { object["src"] = .string(src) }
        return .object(object)
    }

    private var albumList: ValueType {
        .list([
            track("a", src: "https://example.org/a.mp3"),
            track("paid", title: "Paid"),
            track("b", src: "https://example.org/b.mp3"),
            track("c", src: "https://example.org/c.mp3")
        ])
    }

    func testStartPlaysOnlyPlayableTracksAndClampsIndex() {
        let model = makeModel()
        XCTAssertFalse(model.isVisible, "the bar is hidden until something plays")
        model.start(list: albumList, at: 99)
        XCTAssertEqual(model.queueIDs, ["a", "b", "c"], "a track without src never enters the queue")
        XCTAssertEqual(model.index, 2)
        XCTAssertEqual(model.playingID, "c")
        XCTAssertEqual(engine.played.last, URL(string: "https://example.org/c.mp3"))
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.positionText, "3 av 3")

        model.start(list: albumList, at: -4)
        XCTAssertEqual(model.index, 0)
        XCTAssertEqual(model.playingID, "a")

        model.start(list: .list([track("paid")]), at: 0)
        XCTAssertEqual(model.playingID, "a", "a list without playable tracks changes nothing")
    }

    func testQueueDoesNothingWithoutAudioQueueElement() {
        let model = makeModel(attach: nil)
        model.start(list: albumList)
        XCTAssertNil(model.playingID)
        XCTAssertFalse(model.isVisible)
        XCTAssertTrue(engine.played.isEmpty)
    }

    func testEndedSendsActionOnceAdvancesAndStopsAtEnd() throws {
        let model = makeModel()
        model.start(list: albumList, at: 1)
        XCTAssertEqual(model.playingID, "b")

        engine.onEnded?()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, "track.playedThrough")
        XCTAssertEqual(try sent.first?.1.jsonString(), try ValueType.object(["id": .string("b")]).jsonString())
        XCTAssertEqual(model.playingID, "c", "the queue advances")
        XCTAssertEqual(model.positionText, "3 av 3")

        engine.onEnded?()
        XCTAssertEqual(sent.map(\.0), ["track.playedThrough", "track.playedThrough"])
        XCTAssertEqual(try sent.last?.1.jsonString(), try ValueType.object(["id": .string("c")]).jsonString())
        XCTAssertNil(model.playingID, "without loop the queue stops at the end")
        XCTAssertEqual(model.index, -1)
        XCTAssertTrue(model.isVisible, "the bar stays until it is closed")
        XCTAssertEqual(model.shownTrack?.id, "c")

        engine.onEnded?()
        XCTAssertEqual(sent.count, 2, "a stopped queue sends nothing more")
    }

    func testEndedWithoutActionKeypathSendsNothing() {
        let model = makeModel(attach: SkeletonAudioQueue())
        model.start(list: albumList)
        engine.onEnded?()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(model.playingID, "b")
    }

    func testLoopWrapsToTheTop() {
        let model = makeModel()
        model.toggleLoop()
        XCTAssertTrue(model.loops)
        model.start(list: albumList, at: 2)
        engine.onEnded?()
        XCTAssertEqual(model.playingID, "a", "loop wraps to the first track")
        XCTAssertEqual(model.index, 0)
        XCTAssertEqual(sent.count, 1)
    }

    func testCurrentKeypathFirstValueIsHistoryThenNewPlayIDPlays() {
        let model = makeModel(attach: SkeletonAudioQueue(currentKeypath: "player.current"))
        let bought: ValueType = .object(["playID": .string("p1"), "id": .string("x"), "src": .string("https://example.org/x.mp3"), "title": .string("X")])
        model.observeCurrent(bought)
        XCTAssertNil(model.playingID, "the first value the page has is history, not a new purchase")
        XCTAssertFalse(model.isVisible)

        model.observeCurrent(bought)
        XCTAssertNil(model.playingID, "the same playID does not play again")

        let next: ValueType = .object(["playID": .integer(2), "id": .string("y"), "src": .string("https://example.org/y.mp3")])
        model.observeCurrent(next)
        XCTAssertEqual(model.playingID, "y")
        XCTAssertEqual(model.queueIDs, ["y"])
        XCTAssertNil(model.positionText)
        XCTAssertEqual(model.title, SkeletonNativeAudioQueueModel.noTrackTitle, "a track without title shows the fallback")

        model.observeCurrent(.object(["playID": .string("3"), "id": .string("z")]))
        XCTAssertEqual(model.playingID, "y", "a new playID without src is not playable")
        model.observeCurrent(.null)
        XCTAssertEqual(model.playingID, "y")
    }

    func testCurrentKeypathWithoutHistoryValueStillRecordsNil() {
        let model = makeModel(attach: SkeletonAudioQueue(currentKeypath: "player.current"))
        model.observeCurrent(nil)
        model.observeCurrent(.object(["playID": .string("p1"), "id": .string("x"), "src": .string("https://example.org/x.mp3")]))
        XCTAssertEqual(model.playingID, "x")
    }

    func testButtonPlayingStateForStartTrackAndWholeList() {
        let model = makeModel()
        let root: ValueType = .object(["queue": albumList])
        let rowB: ValueType = .object(["id": .string("b")])
        let resolveRowB: (String) -> ValueType? = { SkeletonRenderDataContext(root: root, item: rowB).resolve($0) }
        let resolveRoot: (String) -> ValueType? = { SkeletonRenderDataContext(root: root).resolve($0) }

        let songButton = SkeletonButton(keypath: "", label: "Spill sang", playQueueKeypath: "queue",
                                        playQueueStartKeypath: "id", playingLabel: "Spiller")
        let albumButton = SkeletonButton(keypath: "", label: "Spill album", playQueueKeypath: "queue", playingLabel: "Spiller")
        let playAll = SkeletonButton(keypath: "", label: "Spill alle", playQueueKeypath: "queue")

        XCTAssertFalse(model.isPlaying(songButton, resolve: resolveRowB))
        model.start(from: songButton, resolve: resolveRowB)
        XCTAssertEqual(model.playingID, "b", "the row button starts at its own track, read from the row, queue from root")
        XCTAssertEqual(model.queueIDs, ["a", "b", "c"])
        XCTAssertTrue(model.isPlaying(songButton, resolve: resolveRowB))
        XCTAssertTrue(model.isPlaying(albumButton, resolve: resolveRoot), "the whole list plays")
        XCTAssertFalse(model.isPlaying(playAll, resolve: resolveRoot), "without playingLabel a button is never marked")

        engine.onEnded?()
        XCTAssertFalse(model.isPlaying(songButton, resolve: resolveRowB), "another track plays now")
        XCTAssertTrue(model.isPlaying(albumButton, resolve: resolveRoot))

        model.playOne(SkeletonAudioQueueTrack(id: "c", src: "https://example.org/c.mp3"))
        XCTAssertFalse(model.isPlaying(albumButton, resolve: resolveRoot), "a different list with the same track is not this album")

        model.close()
        XCTAssertFalse(model.isPlaying(albumButton, resolve: resolveRoot))
    }

    func testButtonWithEmptyListDoesNothing() {
        let model = makeModel()
        let button = SkeletonButton(keypath: "track.buy", label: "Spill", playQueueKeypath: "missing")
        XCTAssertTrue(button.audioQueue(resolve: { _ in nil }).isEmpty)
        model.start(from: button, resolve: { _ in nil })
        XCTAssertNil(model.playingID)
        XCTAssertTrue(sent.isEmpty, "a queue button never sends its keypath")
    }

    func testDisallowedSourceShowsUnavailable() {
        let model = makeModel()
        model.start(list: .list([track("x", src: "blocked:/x.mp3", title: "X")]))
        XCTAssertEqual(model.status, .unavailable)
        XCTAssertEqual(model.status.text, "Lyden er ikke tilgjengelig")
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.title, "X")
        XCTAssertTrue(engine.played.isEmpty, "a refused source is never opened")
        model.togglePlayPause()
        XCTAssertTrue(engine.played.isEmpty)
        XCTAssertEqual(engine.resumes, 0)
    }

    func testPlaybackErrorShowsFailedStatus() {
        let model = makeModel()
        model.start(list: albumList)
        engine.onFailed?()
        XCTAssertEqual(model.status.text, "Lyden kunne ikke spilles")
        engine.onEnded?()
        XCTAssertEqual(model.status, .ready, "the next track clears the status")
    }

    func testCloseStopsAndHides() {
        let model = makeModel()
        model.start(list: albumList)
        model.close()
        XCTAssertNil(model.playingID)
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(engine.stops, 1)
        engine.onEnded?()
        XCTAssertTrue(sent.isEmpty, "a closed player reports no finished track")
    }

    func testPlayPauseAndOtherAudio() {
        let model = makeModel()
        var otherPaused = 0
        let registration = model.registerOtherAudio { otherPaused += 1 }
        model.start(list: albumList)
        XCTAssertEqual(otherPaused, 1, "starting the queue pauses other audio on the surface")
        XCTAssertFalse(model.isPaused)

        model.otherAudioWillPlay()
        XCTAssertTrue(model.isPaused, "other audio pauses the queue")
        model.togglePlayPause()
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(engine.resumes, 1)
        XCTAssertEqual(otherPaused, 2)

        model.unregisterOtherAudio(registration)
        model.start(list: albumList)
        XCTAssertEqual(otherPaused, 2)
    }

    func testStaleDetachIsIgnored() {
        let model = makeModel(attach: nil)
        let first = model.attach(SkeletonAudioQueue()) { _, _ in }
        let second = model.attach(SkeletonAudioQueue()) { _, _ in }
        model.detach(first)
        XCTAssertTrue(model.isAttached)
        model.start(list: albumList)
        model.detach(second)
        XCTAssertFalse(model.isAttached)
        XCTAssertFalse(model.isVisible)
        XCTAssertNil(model.playingID)
    }
}
