// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  SkeletonNativeAudioQueue.swift
//  CellApple
//
//  H and I (Butterpop step 2), native: one queue player per rendered surface.
//  Mirrors the web renderer (`renderAudioQueue` / `bindAudioQueueButton` in
//  CellScaffold's skeleton-runtime.js). The player state lives in
//  `SkeletonNativeAudioQueueModel`, which knows nothing about SwiftUI or
//  AVFoundation; playback goes through `SkeletonAudioQueuePlaybackEngine`, so
//  the queue rules can be tested without real audio.
//
//  The model is put in the environment at the surface root (the outermost
//  `SkeletonView`). The `AudioQueue` element attaches itself to it and shows the
//  player bar; Buttons with `playQueueKeypath`, also in list rows, start it.
//  Without an `AudioQueue` element on the surface, queue buttons do nothing.
//

import SwiftUI
import AVFoundation
import CellBase

// MARK: - Playback engine

/// What the queue model needs from an audio player. `onEnded` and `onFailed`
/// are called on the main actor.
@MainActor
public protocol SkeletonAudioQueuePlaybackEngine: AnyObject {
    var onEnded: (() -> Void)? { get set }
    var onFailed: (() -> Void)? { get set }
    /// Load `url` and start playing it, replacing whatever was loaded.
    func play(_ url: URL)
    func resume()
    func pause()
    /// Pause and drop the loaded source.
    func stop()
}

/// The AVPlayer-backed engine used on device.
@MainActor
final class AVPlayerAudioQueueEngine: SkeletonAudioQueuePlaybackEngine {
    var onEnded: (() -> Void)?
    var onFailed: (() -> Void)?
    private let player = AVPlayer()
    private var itemObservers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?

    func play(_ url: URL) {
        clearItemObservation()
        let item = AVPlayerItem(url: url)
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onEnded?() }
        })
        itemObservers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onFailed?() }
        })
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.onFailed?() }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func resume() { player.play() }

    func pause() { player.pause() }

    func stop() {
        player.pause()
        clearItemObservation()
        player.replaceCurrentItem(with: nil)
    }

    private func clearItemObservation() {
        itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
        itemObservers.removeAll()
        statusObservation?.invalidate()
        statusObservation = nil
    }
}

// MARK: - Model

/// The queue player of one rendered surface, as in the web renderer.
@MainActor
public final class SkeletonNativeAudioQueueModel: ObservableObject {
    public enum Status: Equatable {
        case ready
        /// The track's `src` is not allowed under the link rules.
        case unavailable
        /// The engine reported that playback failed.
        case failed

        public var text: String? {
            switch self {
            case .ready: return nil
            case .unavailable: return "Lyden er ikke tilgjengelig"
            case .failed: return "Lyden kunne ikke spilles"
            }
        }
    }

    public static let defaultLabel = "Spiller"
    public static let noTrackTitle = "Ingen sang valgt"

    @Published public private(set) var tracks: [SkeletonAudioQueueTrack] = []
    @Published public private(set) var index = -1
    /// The id of the track that plays now, or nil when the queue is stopped.
    @Published public private(set) var playingID: String?
    /// The track shown in the bar. Kept after the queue ends, as on web.
    @Published public private(set) var shownTrack: SkeletonAudioQueueTrack?
    @Published public private(set) var positionText: String?
    @Published public private(set) var isPaused = true
    @Published public private(set) var loops = false
    /// The bar is hidden until something plays and after it is closed.
    @Published public private(set) var isVisible = false
    @Published public private(set) var status: Status = .ready
    /// The `AudioQueue` element on this surface, if one is rendered.
    @Published public private(set) var spec: SkeletonAudioQueue?

    private var attachment: UUID?
    private var sendAction: ((String, ValueType) -> Void)?
    private var completedID: String?
    private var hasObservedCurrent = false
    private var lastPlayID: String?
    private var otherAudio: [UUID: () -> Void] = [:]
    private let makeEngine: @MainActor () -> SkeletonAudioQueuePlaybackEngine
    private var engineStorage: SkeletonAudioQueuePlaybackEngine?
    private let resolveURL: (String) -> URL?

    /// - Parameters:
    ///   - engine: creates the playback engine the first time something plays.
    ///     Nil uses AVPlayer.
    ///   - resolveURL: turns a track's `src` or `coverURL` into a URL, or nil
    ///     when the link rules do not allow it.
    public init(
        engine: (@MainActor () -> SkeletonAudioQueuePlaybackEngine)? = nil,
        resolveURL: @escaping (String) -> URL? = SkeletonNativeAudioQueueModel.linkRuleURL
    ) {
        self.makeEngine = engine ?? { AVPlayerAudioQueueEngine() }
        self.resolveURL = resolveURL
    }

    /// `src` and `coverURL` open under the same rules as links: https, or
    /// relative to the configured base URL.
    public nonisolated static func linkRuleURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return SkeletonButtonNavigation.resolveURL(
            for: SkeletonButton(keypath: "", label: "", url: trimmed),
            relativeTo: SkeletonButtonNavigation.configuredBaseURL()
        )
    }

    private var engine: SkeletonAudioQueuePlaybackEngine {
        if let engineStorage { return engineStorage }
        let created = makeEngine()
        created.onEnded = { [weak self] in self?.trackEnded() }
        created.onFailed = { [weak self] in self?.playbackFailed() }
        engineStorage = created
        return created
    }

    // MARK: Element attachment

    public var isAttached: Bool { spec != nil }

    /// Called by the `AudioQueue` element when it appears. `sendAction` sends
    /// an action keypath with a payload through the surface's action path.
    /// Returns a token for `detach`.
    @discardableResult
    public func attach(_ spec: SkeletonAudioQueue, sendAction: @escaping (String, ValueType) -> Void) -> UUID {
        let token = UUID()
        attachment = token
        self.spec = spec
        self.sendAction = sendAction
        return token
    }

    /// Called when the element goes away. A stale token (a newer element has
    /// attached since) is ignored.
    public func detach(_ token: UUID?) {
        guard let token, token == attachment else { return }
        close()
        attachment = nil
        spec = nil
        sendAction = nil
    }

    // MARK: Queue

    public var queueIDs: [String] { tracks.map(\.id) }

    /// Start `tracks` at `startIndex` (clamped). Tracks without `id` or `src`
    /// are skipped. Does nothing without an `AudioQueue` element.
    public func start(_ tracks: [SkeletonAudioQueueTrack], at startIndex: Int = 0) {
        guard isAttached else { return }
        let playable = tracks.filter { Self.isPlayable($0) }
        guard playable.isEmpty == false else { return }
        self.tracks = playable
        index = max(0, min(playable.count - 1, startIndex))
        playEntry()
    }

    /// Start the tracks of a list value, as a queue button holds it.
    public func start(list value: ValueType?, at startIndex: Int = 0) {
        start(SkeletonAudioQueueTrack.queue(from: value), at: startIndex)
    }

    /// Play one track on its own (I: a new `playID` in `currentKeypath`).
    public func playOne(_ track: SkeletonAudioQueueTrack) {
        guard isAttached, Self.isPlayable(track) else { return }
        tracks = [track]
        index = 0
        playEntry()
    }

    public func togglePlayPause() {
        guard playingID != nil else {
            // After the list ended: play the shown track again.
            if let shownTrack, let shownIndex = tracks.firstIndex(of: shownTrack) {
                index = shownIndex
                playEntry()
            }
            return
        }
        guard status != .unavailable else { return }
        if isPaused {
            pauseOtherAudio()
            engine.resume()
            isPaused = false
        } else {
            engine.pause()
            isPaused = true
        }
    }

    public func toggleLoop() {
        loops.toggle()
    }

    /// «Lukk spiller»: stop and hide the bar.
    public func close() {
        stop()
        engineStorage?.stop()
        isVisible = false
        status = .ready
    }

    /// The engine finished the current track.
    public func trackEnded() {
        guard tracks.indices.contains(index) else { return }
        let finished = tracks[index]
        if completedID != finished.id,
           let keypath = Self.normalized(spec?.endedActionKeypath) {
            completedID = finished.id
            sendAction?(keypath, .object(["id": .string(finished.id)]))
        }
        var next = index + 1
        if next >= tracks.count {
            guard loops else {
                stop()
                return
            }
            next = 0
        }
        index = next
        playEntry()
    }

    public func playbackFailed() {
        guard playingID != nil else { return }
        status = .failed
        isPaused = true
    }

    /// I: feed the current value at `currentKeypath`. The first value seen is
    /// history (what the page already had), so it is recorded but not played.
    /// After that, a new non-empty `playID` plays that track if it is playable.
    public func observeCurrent(_ value: ValueType?) {
        guard Self.normalized(spec?.currentKeypath) != nil else { return }
        let playID = Self.playID(in: value)
        guard hasObservedCurrent else {
            hasObservedCurrent = true
            lastPlayID = playID
            return
        }
        guard let playID, playID != lastPlayID else { return }
        lastPlayID = playID
        if let track = SkeletonAudioQueueTrack(value) {
            playOne(track)
        }
    }

    // MARK: Buttons

    /// Whether a queue button shows its `playingLabel`.
    public func isPlaying(_ button: SkeletonButton, resolve: (String) -> ValueType?) -> Bool {
        button.isPlaying(resolve: resolve, playingTrackID: playingID, playingQueueIDs: queueIDs)
    }

    /// A queue button was tapped: start its list at its own track.
    public func start(from button: SkeletonButton, resolve: (String) -> ValueType?) {
        guard isAttached else { return }
        let list = button.audioQueue(resolve: resolve)
        guard list.isEmpty == false else { return }
        start(list, at: button.audioQueueStartIndex(resolve: resolve, queue: list))
    }

    // MARK: Other audio on the surface

    /// Single `Audio` elements register here so only one sound plays at a time.
    public func registerOtherAudio(pause: @escaping () -> Void) -> UUID {
        let id = UUID()
        otherAudio[id] = pause
        return id
    }

    public func unregisterOtherAudio(_ id: UUID?) {
        guard let id else { return }
        otherAudio[id] = nil
    }

    /// Another audio element on the surface starts: pause the queue.
    public func otherAudioWillPlay() {
        guard playingID != nil, isPaused == false else { return }
        engineStorage?.pause()
        isPaused = true
    }

    // MARK: Bar text

    public var title: String {
        Self.normalized(shownTrack?.title) ?? Self.noTrackTitle
    }

    public var modeText: String? { Self.normalized(shownTrack?.mode) }

    public var detailText: String? { Self.normalized(shownTrack?.detail) }

    public var coverURL: URL? {
        guard let raw = Self.normalized(shownTrack?.coverURL) else { return nil }
        return resolveURL(raw)
    }

    // MARK: Private

    private func playEntry() {
        guard tracks.indices.contains(index) else { return }
        let track = tracks[index]
        playingID = track.id
        completedID = nil
        shownTrack = track
        positionText = tracks.count > 1 ? "\(index + 1) av \(tracks.count)" : nil
        isVisible = true
        pauseOtherAudio()
        engine.pause()
        guard let url = resolveURL(track.src) else {
            status = .unavailable
            isPaused = true
            return
        }
        status = .ready
        engine.play(url)
        isPaused = false
    }

    private func stop() {
        engineStorage?.pause()
        playingID = nil
        index = -1
        isPaused = true
    }

    private func pauseOtherAudio() {
        otherAudio.values.forEach { $0() }
    }

    private static func isPlayable(_ track: SkeletonAudioQueueTrack) -> Bool {
        normalized(track.id) != nil && normalized(track.src) != nil
    }

    private static func playID(in value: ValueType?) -> String? {
        guard case let .object(object)? = value, let raw = object["playID"] else { return nil }
        switch raw {
        case .string(let string): return string
        case .integer(let number), .number(let number): return String(number)
        case .float(let number): return String(number)
        case .bool(let flag): return String(flag)
        default: return nil
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Environment

private struct SkeletonAudioQueuePlayerKey: EnvironmentKey {
    static let defaultValue: SkeletonNativeAudioQueueModel? = nil
}

extension EnvironmentValues {
    /// The queue player of the surface being rendered. Set by the outermost
    /// `SkeletonView`.
    var skeletonAudioQueuePlayer: SkeletonNativeAudioQueueModel? {
        get { self[SkeletonAudioQueuePlayerKey.self] }
        set { self[SkeletonAudioQueuePlayerKey.self] = newValue }
    }
}

/// Owns the surface's queue player and hands it down.
struct SkeletonAudioQueueSurfaceHost: ViewModifier {
    @StateObject private var player = SkeletonNativeAudioQueueModel()

    func body(content: Content) -> some View {
        content.environment(\.skeletonAudioQueuePlayer, player)
    }
}

// MARK: - Views

/// The `AudioQueue` element: the player bar, hidden until something plays.
struct SkeletonAudioQueueBarView: View {
    let spec: SkeletonAudioQueue
    let data: SkeletonRenderDataContext
    @ObservedObject var player: SkeletonNativeAudioQueueModel
    @Environment(\.skeletonNativeActionScope) private var actionScope
    @Environment(\.skeletonNativeActionHandler) private var actionHandler
    @EnvironmentObject var viewModel: PortholeViewModel
    @State private var attachment: UUID?

    private var currentValue: ValueType? {
        guard let keypath = spec.currentKeypath?.trimmingCharacters(in: .whitespacesAndNewlines),
              keypath.isEmpty == false else { return nil }
        return data.resolve(keypath)
    }

    private var currentSignature: String {
        (try? currentValue?.jsonString()) ?? "nil"
    }

    private var label: String {
        let trimmed = spec.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? SkeletonNativeAudioQueueModel.defaultLabel : trimmed
    }

    var body: some View {
        ZStack {
            Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            if player.isVisible {
                bar.applySkeletonModifiers(spec.modifiers, userInfoValue: data.item ?? data.root)
            }
        }
        .onAppear {
            let scope = actionScope
            let handler = actionHandler
            let viewModel = viewModel
            attachment = player.attach(spec) { keypath, payload in
                Task { @MainActor in
                    do {
                        _ = try await skeletonNativeSend(keypath: keypath, payload: payload,
                            scope: scope, handler: handler, viewModel: viewModel)
                    } catch {
                        print("Skeleton audio queue action failed: \(error)")
                    }
                }
            }
            player.observeCurrent(currentValue)
        }
        .onDisappear { player.detach(attachment) }
        .onChange(of: currentSignature) { _ in player.observeCurrent(currentValue) }
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let cover = player.coverURL {
                    AsyncImage(url: cover) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(Text("Cover til \(player.title)"))
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let mode = player.modeText {
                        Text(mode).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(player.title).font(.headline).lineLimit(1)
                    if let detail = player.detailText {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if let position = player.positionText {
                        Text(position).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.plain)
                .disabled(player.status == .unavailable)
                .accessibilityLabel(Text(player.isPaused ? "Spill av" : "Pause"))
                Button {
                    player.toggleLoop()
                } label: {
                    Image(systemName: "repeat")
                        .foregroundStyle(player.loops ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Spill listen om igjen")
                .accessibilityLabel(Text("Spill listen om igjen"))
                .accessibilityValue(Text(player.loops ? "På" : "Av"))
                .accessibilityAddTraits(player.loops ? .isSelected : [])
                Button {
                    player.close()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Lukk spiller"))
            }
            if let statusText = player.status.text {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }
}

/// A Button with `playQueueKeypath`: starts the surface's queue player and
/// never sends its `keypath`.
struct SkeletonAudioQueueButtonView: View {
    let button: SkeletonButton
    let data: SkeletonRenderDataContext
    let player: SkeletonNativeAudioQueueModel?

    var body: some View {
        if let player {
            AttachedButton(button: button, data: data, player: player)
        } else {
            QueueButtonBody(button: button, data: data, isPlaying: false) {}
        }
    }

    private struct AttachedButton: View {
        let button: SkeletonButton
        let data: SkeletonRenderDataContext
        @ObservedObject var player: SkeletonNativeAudioQueueModel

        var body: some View {
            let data = data
            QueueButtonBody(button: button, data: data,
                            isPlaying: player.isPlaying(button, resolve: { data.resolve($0) })) {
                player.start(from: button, resolve: { data.resolve($0) })
            }
        }
    }

    private struct QueueButtonBody: View {
        let button: SkeletonButton
        let data: SkeletonRenderDataContext
        let isPlaying: Bool
        let action: () -> Void
        @EnvironmentObject var viewModel: PortholeViewModel

        private var item: ValueType? { data.item ?? data.root }

        private var label: String {
            if isPlaying, let playing = button.playingLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               playing.isEmpty == false {
                return playing
            }
            return viewModel.localization.text(button.modifiers?.localization?["label"],
                fallback: button.label, item: item, contextValue: item)
        }

        var body: some View {
            let data = data
            let isEmpty = button.audioQueue(resolve: { data.resolve($0) }).isEmpty
            Button(action: action) {
                HStack(spacing: 8) {
                    if let iconName = button.icon, iconName.isEmpty == false {
                        Image(systemName: iconName)
                    }
                    SkeletonNativeButtonLabel(label: label, modifiers: button.modifiers)
                }
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .accessibilityLabel(Text(isPlaying ? label : (button.modifiers?.accessibilityLabel ?? label)))
            .accessibilityIdentifier("skeleton.button.\(button.id.uuidString)")
            .accessibilityAddTraits(isPlaying ? .isSelected : [])
            .applySkeletonModifiers(button.modifiers)
        }
    }
}
