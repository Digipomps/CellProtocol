import CellBase

// The Linux workflow first type-checks this external transport surface as a
// positive module-resolution control. It then enables the bypass attempt and
// proves that the same source can no longer type-check through a normal import.
func attemptTransportAuthorityBypass(
    _ request: DeviceIngressAuthorityRequest,
    resolver: any CellResolverProtocol
) async throws {
#if ATTEMPT_AUTHORITY_BYPASS
    _ = try await DeviceIngressResolverAuthorizer.authorize(
        request,
        resolver: resolver
    )
#endif
}
