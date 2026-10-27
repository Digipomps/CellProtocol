// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import AVFoundation
import CellBase

/// D: the whole element is one link. Activation goes through the same
/// navigation rules as link buttons (`SkeletonButtonNavigationExecution`).
struct SkeletonNativeElementLink: View {
    let content: AnyView
    let link: SkeletonButton
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { open() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isLink)
            .accessibilityAction { open() }
    }

    private func open() {
        let link = link
        let openURL = openURL
        Task { @MainActor in
            _ = await SkeletonButtonNavigationExecution.open(link) { url, completion in
                openURL(url, completion: completion)
            }
        }
    }
}

/// F: one audio source with play/pause and a visible missing/failed state.
/// The source is opened only under the link rules (https, or same origin when
/// relative), so a skeleton cannot make the app fetch arbitrary schemes.
struct CellAudioView: View {
    let skeletonAudio: SkeletonAudio
    let userInfoValue: ValueType?
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    private var sourceURL: URL? {
        guard let raw = skeletonAudio.resolvedSource(item: userInfoValue) else { return nil }
        return SkeletonButtonNavigation.resolveURL(
            for: SkeletonButton(keypath: "", label: "", url: raw),
            relativeTo: SkeletonButtonNavigation.configuredBaseURL()
        )
    }

    var body: some View {
        let url = sourceURL
        let title = skeletonAudio.resolvedTitle(item: userInfoValue)
        HStack(spacing: 8) {
            Button {
                toggle(url)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(url == nil)
            .accessibilityLabel(Text(isPlaying ? "Pause" : "Play"))
            if let title {
                Text(title)
            }
            if url == nil {
                Text("Audio unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            player?.pause()
            isPlaying = false
        }
    }

    private func toggle(_ url: URL?) {
        guard let url else { return }
        if player == nil {
            player = AVPlayer(url: url)
        }
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
}
