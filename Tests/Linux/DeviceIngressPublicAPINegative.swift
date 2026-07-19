import Foundation
@_spi(HAVENRuntime) import CellBase

// A Scaffold composition root can construct the complete signed target pin,
// while ordinary transport code still cannot invoke staged authorization.
func makePinnedAuthorityReferenceForCompositionRoot() -> DeviceIngressAuthorityReference {
    DeviceIngressAuthorityReference(
        authorityID: "authority-1",
        agreementID: "agreement-1",
        targetCellUUID: "66666666-6666-4666-8666-666666666666",
        targetOwnerIdentityUUID: "11111111-1111-4111-8111-111111111111",
        targetOwnerSigningKeyFingerprint: "ECDSA:P-256:owner",
        signedAgreementSHA256: Data(repeating: 0x01, count: 32),
        subjectIdentityUUID: "22222222-2222-4222-8222-222222222222",
        subjectSigningKeyFingerprint: "ECDSA:P-256:subject",
        authorityGeneration: 1,
        revocationLedgerID: "revocation-ledger-1",
        revocationGeneration: 1,
        issuedAtMilliseconds: 1,
        validUntilMilliseconds: 2
    )
}

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
