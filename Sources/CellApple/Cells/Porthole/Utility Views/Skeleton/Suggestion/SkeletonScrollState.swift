// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI

/// Records scroll position only. This does not measure layout or contribute any
/// dimensions to V3-A; container sizes still come exclusively from the host.
struct SkeletonScrollState: View {
    @Environment(\.skeletonComponentLocalState) private var state
    @Environment(\.skeletonNativeElementID) private var elementID
    var body: some View {
        #if os(macOS)
        if let state { NativeScrollState(state: state, key: elementID).frame(width: 0, height: 0).accessibilityHidden(true) }
        #else
        EmptyView()
        #endif
    }
}

#if os(macOS)
import AppKit
private struct NativeScrollState: NSViewRepresentable {
    let state: SkeletonComponentLocalState
    let key: String
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {
        view.state = state; view.key = key
        DispatchQueue.main.async { [weak view] in view?.attach() }
    }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.detach() }

    final class Observer: NSView {
        var state: SkeletonComponentLocalState?
        var key = ""
        weak var clip: NSClipView?
        var observation: NSObjectProtocol?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        func attach() {
            guard let scroll = enclosingScrollView, clip !== scroll.contentView else { return }
            detach()
            let clip = scroll.contentView
            self.clip = clip
            if let offset = state?.scrollOffsets[key] {
                clip.scroll(to: offset); scroll.reflectScrolledClipView(clip)
            }
            clip.postsBoundsChangedNotifications = true
            observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: clip, queue: .main) { [weak self] _ in self?.record() }
        }
        func record() {
            if let clip { state?.scrollOffsets[key] = clip.bounds.origin }
        }
        func detach() {
            record()
            if let observation { NotificationCenter.default.removeObserver(observation); self.observation = nil }
            clip = nil
        }
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}
#endif
