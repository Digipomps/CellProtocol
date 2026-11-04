// SPDX-License-Identifier: Apache-2.0
import Foundation

extension PerspectiveCell {
    /// Compatibility for the native graph tool without exposing the mutable
    /// Perspective actor across module/host boundaries.
    public func matchPrimaryPurposeGraph(requester: Identity) async throws -> Data {
        try await ensureRuntimeReady()
        guard await validateAccess("r---", at: "perspective", for: requester) else { throw FlowError.denied }
        let primary = try await context.getPrimaryPurpose()
        guard let start = await context.findPurposeByReference(primary.reference) else {
            throw PerspectiveError.noPrimaryPurpose
        }
        let signal = Signal(relationship: .interests, weight: 0.5,
            tolerance: Double.greatestFiniteMagnitude, token: UUID().uuidString, ttl: 1.0, hops: 2)
        let configuration = WeightedGraphRuntimeConfiguration(
            relationships: [.interests, .purposes, .entities, .states, .types, .parts, .partOf, .subTypes],
            maxHops: 2, ttl: 1.0, maxHits: 50)
        let result = try await WeightedGraphRuntime().match(start: start, signal: signal, configuration: configuration)
        guard await validateAccess("r---", at: "perspective", for: requester) else { throw FlowError.denied }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(result)
    }
}
