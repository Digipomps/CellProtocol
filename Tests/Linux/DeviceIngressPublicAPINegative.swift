import CellBase

// Plain transport code can name verified request values, but it cannot invoke
// the internal staged resolver-authority operation.
func attemptStagedAuthorityFromTransport(
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
