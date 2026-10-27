// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  SkeletonAudio.swift
//  CellBase
//
//  F (PDD kunstnerside-som-flate): audio playback inside a skeleton, so a
//  music page (Butterpop Kollektivet, the general page builder) is a real
//  CellConfiguration instead of a custom app.
//
//  The element only says *what* to play. Delivery, access and track policy stay
//  in the music cells that serve the URL. Renderers play one track at a time per
//  surface, offer play, pause and seek, and show a visible error state when the
//  source is missing or cannot be loaded.
//

import Foundation

public struct SkeletonAudio: Codable, Identifiable {
    public var id = UUID()
    /// Fixed source URL. Ignored when `srcKeypath` is set.
    public var src: String?
    /// Row field (dotted keypath) that holds the source URL.
    public var srcKeypath: String?
    public var title: String?
    public var titleKeypath: String?
    /// Optional MIME type hint, for example `audio/mpeg`.
    public var mimeType: String?
    public var modifiers: SkeletonModifiers?

    public init(
        id: UUID = UUID(),
        src: String? = nil,
        srcKeypath: String? = nil,
        title: String? = nil,
        titleKeypath: String? = nil,
        mimeType: String? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.id = id
        self.src = src
        self.srcKeypath = srcKeypath
        self.title = title
        self.titleKeypath = titleKeypath
        self.mimeType = mimeType
        self.modifiers = modifiers
    }

    enum ElementKey: CodingKey { case Audio }
    enum CodingKeys: String, CodingKey {
        case id
        case src
        case srcKeypath
        case title
        case titleKeypath
        case mimeType
        case modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = decodedID
        }
        self.src = try container.decodeIfPresent(String.self, forKey: .src)
        self.srcKeypath = try container.decodeIfPresent(String.self, forKey: .srcKeypath)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.titleKeypath = try container.decodeIfPresent(String.self, forKey: .titleKeypath)
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        if SkeletonDataBinding.normalized(src) == nil && SkeletonDataBinding.normalized(srcKeypath) == nil {
            throw SkeletonFormatError(field: "src", reason: "Audio requires src or srcKeypath")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Audio)
        try elementContainer.encode(id, forKey: .id)
        try elementContainer.encodeIfPresent(src, forKey: .src)
        try elementContainer.encodeIfPresent(srcKeypath, forKey: .srcKeypath)
        try elementContainer.encodeIfPresent(title, forKey: .title)
        try elementContainer.encodeIfPresent(titleKeypath, forKey: .titleKeypath)
        try elementContainer.encodeIfPresent(mimeType, forKey: .mimeType)
        try elementContainer.encodeIfPresent(modifiers, forKey: .modifiers)
    }

    /// Row data wins over the static `src`. The result is unvetted; renderers
    /// open it only under the same rules as links (`SkeletonButtonNavigation`).
    public func resolvedSource(item: ValueType?) -> String? {
        if srcKeypath != nil {
            return SkeletonDataBinding.string(at: srcKeypath, in: item)
        }
        return SkeletonDataBinding.normalized(src)
    }

    public func resolvedTitle(item: ValueType?) -> String? {
        SkeletonDataBinding.string(at: titleKeypath, in: item) ?? SkeletonDataBinding.normalized(title)
    }
}
