// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase

struct SkeletonComponentInstance {
    let instanceID: String
    private(set) var mount: SkeletonComponentMount
    private(set) var definitionGeneration = 0

    init(instanceID: String, mount: SkeletonComponentMount) { self.instanceID = instanceID; self.mount = mount }

    mutating func update(_ next: SkeletonComponentMount) {
        if next.componentID != mount.componentID || next.revision != mount.revision {
            mount = next; definitionGeneration += 1
        } else {
            // The same revision is immutable. Keep Swift identities in the
            // definition, updating only instance data and the source endpoint.
            mount.item = next.item
            mount.sourceCellEndpoint = next.sourceCellEndpoint
        }
    }

    var actionScope: SkeletonNativeActionScope {
        SkeletonNativeActionScope(sourceCellEndpoint: mount.sourceCellEndpoint,
            mount: .init(instanceID: instanceID, componentID: mount.componentID, revision: mount.revision))
    }

    static func decode(_ value: ValueType) throws -> SkeletonComponentMount {
        try JSONDecoder().decode(SkeletonComponentMount.self, from: JSONEncoder().encode(value))
    }
}

/// Mounted state belongs to instanceID, not the source path or revision. Stable
/// field/tree keys in SkeletonView preserve surviving descendants on revision.
struct CellComponentSurfaceView: View {
    let surface: SkeletonComponentSurface
    let data: SkeletonRenderDataContext
    @Environment(\.skeletonComponentAncestors) private var ancestors
    @Environment(\.skeletonNativeActionHandler) private var actionHandler
    @StateObject private var localState = SkeletonComponentLocalState()
    @State private var instance: SkeletonComponentInstance?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let instance, failure == nil {
                SkeletonView(element: instance.mount.skeleton, showsKeyboardToolbar: false,
                    renderData: data.row(instance.mount.item))
                    .environment(\.skeletonComponentLocalState, localState)
                    .environment(\.skeletonNativeActionScope, instance.actionScope)
                    .environment(\.skeletonComponentAncestors, ancestors + [surface.instanceID])
                    .environment(\.skeletonNativeElementID, "component:" + surface.instanceID)
                if actionHandler == nil {
                    Text("ComponentSurface: source actions require a host adapter (mount metadata).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(failure ?? "ComponentSurface: unresolved mount").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("skeleton.component.\(surface.instanceID)")
        .task(id: surface.instanceID + ":" + surface.sourceKeypath + ":" + data.signature) {
            guard !ancestors.contains(surface.instanceID), ancestors.count < 64,
                  let value = data.resolve(surface.sourceKeypath) else {
                failure = "ComponentSurface: unresolved or recursive mount"
                instance = nil
                return
            }
            do {
                let mount = try SkeletonComponentInstance.decode(value)
                if instance?.instanceID == surface.instanceID { instance?.update(mount) }
                else { instance = .init(instanceID: surface.instanceID, mount: mount) }
                failure = nil
            } catch {
                instance = nil; failure = "ComponentSurface: invalid mount — \(error.localizedDescription)"
            }
        }
    }
}
