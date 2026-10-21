// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Routing context for a source action that came from a mounted `ComponentSurface`:
/// which instance of which definition the person acted in. Never authority and never
/// part of the cell's action payload (SKJELETT_ELEMENTER §2.2, Kjetils valg A 2026-10-08).
///
/// A host that dispatches a mounted action to a local cell sets `SkeletonComponentActionContext.mount`
/// around the `set`/`get`; a cell that needs the instance (for example to know which list a
/// typed text belongs to) reads it. Meddle's wire contract has no metadata slot, so this must
/// not cross a bridge silently — a remote host gets no context and the cell falls back.
///
/// `ScaffoldKit.ComponentActionContext` in CellScaffold carries the same fields; the integration
/// package replaces it with a typealias to this type so cells and hosts share one TaskLocal.
public struct SkeletonComponentActionMount: Codable, Equatable, Sendable {
    public let instanceID: String
    public let componentID: String
    public let revision: String

    public init(instanceID: String, componentID: String, revision: String) {
        self.instanceID = instanceID
        self.componentID = componentID
        self.revision = revision
    }
}

public enum SkeletonComponentActionContext {
    @TaskLocal public static var mount: SkeletonComponentActionMount?
}
