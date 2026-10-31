// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  SkeletonAudioQueue.swift
//  CellBase
//
//  H and I (PDD kunstnerside-som-flate, Butterpop step 2): one player per
//  surface that plays a queue of tracks in order, with a player bar.
//
//  The element is the player. Buttons fill it: a Button with
//  `playQueueKeypath` hands the player a list of tracks, and the player starts
//  at the button's own track (`playQueueStartKeypath`) or at the top. While a
//  button's track or list plays, the button shows `playingLabel` instead of its
//  label. This gives «Spill alle», «Spill album», «Spill liste» and the
//  «Spiller» marker without any action leaving the surface.
//
//  `currentKeypath` (I) lets the server start one track: when the object there
//  gets a new `playID`, the player plays its `src`. A purchase that the payment
//  gate approves answers with such an object. When a track has played to the
//  end, the player sends `endedActionKeypath` with `{"id": <track id>}`.
//
//  A track in a queue or in `currentKeypath` is an object with `id` and `src`,
//  and optionally `title`, `mode` (the small label above the title, for
//  example «Gratis»), `detail` and `coverURL`. The element only says what to
//  play. Delivery, access and payment stay in the cells that serve `src`, and
//  renderers open `src` under the same rules as links (SkeletonButtonNavigation).
//

import Foundation

public struct SkeletonAudioQueue: Codable, Identifiable {
    public var id = UUID()
    /// Object `{playID, id, src, title?, mode?, detail?, coverURL?}`. A new
    /// `playID` starts that track. Optional.
    public var currentKeypath: String?
    /// Action sent with `{"id": <track id>}` when a track has played to the end.
    /// Optional; without it nothing is sent.
    public var endedActionKeypath: String?
    /// Accessible name of the player bar. Defaults to "Player" in renderers.
    public var label: String?
    public var modifiers: SkeletonModifiers?

    public init(
        id: UUID = UUID(),
        currentKeypath: String? = nil,
        endedActionKeypath: String? = nil,
        label: String? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.id = id
        self.currentKeypath = currentKeypath
        self.endedActionKeypath = endedActionKeypath
        self.label = label
        self.modifiers = modifiers
    }

    enum ElementKey: CodingKey { case AudioQueue }
    enum CodingKeys: String, CodingKey {
        case id
        case currentKeypath
        case endedActionKeypath
        case label
        case modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = decodedID
        }
        self.currentKeypath = try container.decodeIfPresent(String.self, forKey: .currentKeypath)
        self.endedActionKeypath = try container.decodeIfPresent(String.self, forKey: .endedActionKeypath)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        for (field, value) in [("currentKeypath", currentKeypath), ("endedActionKeypath", endedActionKeypath)] {
            if let value, SkeletonDataBinding.normalized(value) == nil {
                throw SkeletonFormatError(field: field, reason: "AudioQueue \(field) must not be empty")
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .AudioQueue)
        try elementContainer.encode(id, forKey: .id)
        try elementContainer.encodeIfPresent(currentKeypath, forKey: .currentKeypath)
        try elementContainer.encodeIfPresent(endedActionKeypath, forKey: .endedActionKeypath)
        try elementContainer.encodeIfPresent(label, forKey: .label)
        try elementContainer.encodeIfPresent(modifiers, forKey: .modifiers)
    }
}

/// One playable track, as a queue list or `currentKeypath` holds it.
public struct SkeletonAudioQueueTrack: Equatable {
    public var id: String
    public var src: String
    public var title: String?
    public var mode: String?
    public var detail: String?
    public var coverURL: String?

    public init(id: String, src: String, title: String? = nil, mode: String? = nil, detail: String? = nil, coverURL: String? = nil) {
        self.id = id
        self.src = src
        self.title = title
        self.mode = mode
        self.detail = detail
        self.coverURL = coverURL
    }

    /// Nil unless the value is an object with a non-empty `id` and `src`.
    public init?(_ value: ValueType?) {
        guard let id = SkeletonDataBinding.string(at: "id", in: value),
              let src = SkeletonDataBinding.string(at: "src", in: value) else { return nil }
        self.init(
            id: id,
            src: src,
            title: SkeletonDataBinding.string(at: "title", in: value),
            mode: SkeletonDataBinding.string(at: "mode", in: value),
            detail: SkeletonDataBinding.string(at: "detail", in: value),
            coverURL: SkeletonDataBinding.string(at: "coverURL", in: value)
        )
    }

    /// The playable tracks of a list value, in order. Entries without `id` or
    /// `src` are skipped, so a paid track never enters a queue by accident.
    public static func queue(from value: ValueType?) -> [SkeletonAudioQueueTrack] {
        guard case let .list(entries)? = value else { return [] }
        return entries.compactMap { SkeletonAudioQueueTrack($0) }
    }
}

public extension SkeletonButton {
    /// H: true when the button starts the player instead of sending an action.
    var startsAudioQueue: Bool {
        SkeletonDataBinding.normalized(playQueueKeypath) != nil
    }

    /// The tracks this button would play, read from the row (or root) value.
    func audioQueue(item: ValueType?) -> [SkeletonAudioQueueTrack] {
        guard let keypath = SkeletonDataBinding.normalized(playQueueKeypath) else { return [] }
        return SkeletonAudioQueueTrack.queue(from: SkeletonDataBinding.value(at: keypath, in: item))
    }

    /// Index to start at: the button's own track when `playQueueStartKeypath`
    /// names one that is in the queue, otherwise the top.
    func audioQueueStartIndex(item: ValueType?, queue: [SkeletonAudioQueueTrack]) -> Int {
        guard let startID = SkeletonDataBinding.string(at: playQueueStartKeypath, in: item),
              let index = queue.firstIndex(where: { $0.id == startID }) else { return 0 }
        return index
    }

    /// Whether this button shows `playingLabel`: its own track is playing, or,
    /// without a start track, the player plays exactly this button's list.
    func isPlaying(item: ValueType?, playingTrackID: String?, playingQueueIDs: [String]) -> Bool {
        guard startsAudioQueue, let playingTrackID else { return false }
        if let startID = SkeletonDataBinding.string(at: playQueueStartKeypath, in: item) {
            return startID == playingTrackID
        }
        let ids = audioQueue(item: item).map(\.id)
        return !ids.isEmpty && ids == playingQueueIDs
    }
}
