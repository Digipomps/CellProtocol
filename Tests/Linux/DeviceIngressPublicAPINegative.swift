import CellBase

// This file is intentionally expected not to type-check. The Linux workflow
// proves that an external transport module cannot invoke staged authorization.
func attemptTransportAuthorityBypass(
    _ request: DeviceIngressAuthorityRequest,
    resolver: any CellResolverProtocol
) async throws {
    _ = try await DeviceIngressResolverAuthorizer.authorize(
        request,
        resolver: resolver
    )
}
