import Foundation
@_spi(HAVENRuntime) import CellBase

// A trusted Scaffold composition root can construct a complete signed target
// pin. SPI access organizes integration APIs; it grants no runtime authority.
func makePinnedAuthorityReferenceForCompositionRoot() -> DeviceIngressAuthorityReference {
    DeviceIngressAuthorityReference(
        authorityID: "authority-1",
        agreementID: "agreement-1",
        targetCellUUID: "66666666-6666-4666-8666-666666666666",
        targetOwnerIdentityUUID: "33333333-3333-4333-8333-333333333333",
        targetOwnerSigningKeyFingerprint: "ECDSA:P-256:owner",
        signedAgreementSHA256: Data(repeating: 0x01, count: 32),
        subjectIdentityUUID: "22222222-2222-4222-8222-222222222222",
        subjectSigningKeyFingerprint: "ECDSA:P-256:subject",
        authorityGeneration: 1,
        revocationLedgerID: "revocation-ledger-1",
        revocationGeneration: 1,
        contentPolicy: DeviceIngressContentPolicy(
            requestBodyContentContractSHA256: Data(repeating: 0x01, count: 32),
            responseContentContractSHA256: Data(repeating: 0x02, count: 32)
        ),
        issuedAtMilliseconds: 1,
        validUntilMilliseconds: 2
    )
}
