// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase

/// A renderer-host hook that runs after CellApple has resolved a button against
/// its current row value. Hosts may use it to preserve host-local routing
/// metadata without moving that metadata into the portable Skeleton schema.
public struct SkeletonButtonResolutionTransform: Sendable {
    public typealias Body = @Sendable (
        _ template: SkeletonButton,
        _ resolved: SkeletonButton
    ) -> SkeletonButton

    private let body: Body

    public init(_ body: @escaping Body) {
        self.body = body
    }

    public func callAsFunction(
        template: SkeletonButton,
        resolved: SkeletonButton
    ) -> SkeletonButton {
        body(template, resolved)
    }
}

private struct SkeletonButtonResolutionTransformKey: EnvironmentKey {
    static let defaultValue: SkeletonButtonResolutionTransform? = nil
}

public extension EnvironmentValues {
    var skeletonButtonResolutionTransform: SkeletonButtonResolutionTransform? {
        get { self[SkeletonButtonResolutionTransformKey.self] }
        set { self[SkeletonButtonResolutionTransformKey.self] = newValue }
    }
}

public enum SkeletonButtonResolutionSupport {
    public static func resolve(
        template: SkeletonButton,
        userInfoValue: ValueType?,
        transform: SkeletonButtonResolutionTransform? = nil
    ) -> SkeletonButton {
        var resolved = template
        if case let .object(object)? = userInfoValue {
            if let urlValue = object["url"], case let .string(urlString) = urlValue {
                resolved.url = urlString
            }
            let keypathField = template.keypathKeypath ?? "keypath"
            let labelField = template.labelKeypath ?? "label"
            let payloadField = template.payloadKeypath ?? "payload"
            if let keypathValue = object[keypathField], case let .string(keypathString) = keypathValue {
                resolved.keypath = keypathString
            }
            if let payloadValue = object[payloadField] {
                resolved.payload = payloadValue
            }
            if let labelValue = object[labelField], case let .string(labelString) = labelValue {
                resolved.label = labelString
            }
        }
        return transform?(template: template, resolved: resolved) ?? resolved
    }
}
