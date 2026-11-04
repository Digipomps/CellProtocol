// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Book14 threshold semantics shared by every Perspective host. Legacy aliases
/// are accepted only when they have exactly the same numeric meaning.
public enum PerspectiveQueryContract {
    public enum Failure: Error, Equatable { case invalidThreshold, conflictingThresholds }

    public static func minimumPurposeWeight(in payload: Object) throws -> Double {
        var resolved: Double?
        for key in ["minPurposeWeight", "minWeight", "minimumWeight"] {
            guard let value = payload[key] else { continue }
            let number: Double
            switch value {
            case .integer(let v): number = Double(v)
            case .float(let v): number = v
            default: throw Failure.invalidThreshold
            }
            guard number.isFinite else { throw Failure.invalidThreshold }
            if let resolved, resolved != number { throw Failure.conflictingThresholds }
            resolved = number
        }
        return resolved ?? 0
    }
}
