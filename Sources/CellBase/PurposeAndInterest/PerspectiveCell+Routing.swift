// SPDX-License-Identifier: Apache-2.0
import Foundation

extension PerspectiveCell {
    /// The native host supplies its normal requester-visible configuration
    /// catalog. One private runtime survives all Porthole configuration swaps.
    public func installPerspectiveRouting(requester: Identity, catalog: @escaping PerspectiveRoutingRuntime.Catalog,
                                          clock: @escaping @Sendable () -> Date = { Date() }) async throws -> PerspectiveRoutingRuntime {
        guard await requesterProvesOwnership(requester) else { throw FlowError.denied }
        await routingInstallationGate.enter()
        do {
            if let runtime = perspectiveRoutingRuntime { await routingInstallationGate.leave(); return runtime }
            let runtime = try await PerspectiveRoutingRuntime.install(on: self, catalog: catalog, sourceTopicOwnedByHost: true, clock: clock)
            perspectiveRoutingRuntime = runtime
            await routingInstallationGate.leave(); return runtime
        } catch { await routingInstallationGate.leave(); throw error }
    }
}
