// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@_spi(HAVENRuntime) @testable import CellBase

final class DeviceIngressContractTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_454_400)
    private let audience = "staging.haven.digipomps.org"

    func testRealSignedAgreementIsResolverAuthorizedAndSameCellMutationCompletes() async throws {
        let fixture = try await makeFixture()
        let admission = try await admit(fixture)

        XCTAssertEqual(admission.pair.request.operation, DeviceIngressOperation.register)
        XCTAssertEqual(admission.authority.path, DeviceIngressAuthorityPath.signedAgreement)
        XCTAssertEqual(
            admission.record.requestSHA256,
            DeviceIngressCanonicalWire.sha256(fixture.requestData)
        )
        XCTAssertEqual(
            admission.admissionReceipt.persistenceSemantics,
            DeviceIngressAdmissionReceipt.durableBeforeMutation
        )
        XCTAssertEqual(
            admission.mutationReceipt.persistenceSemantics,
            DeviceIngressMutationReceipt.atomicRecheckAndDurableMutation
        )
        XCTAssertEqual(
            admission.admissionReceipt.targetOwnerIdentityUUID,
            fixture.request.authority.targetOwnerIdentityUUID
        )
        XCTAssertEqual(
            admission.admissionReceipt.signedAgreementSHA256,
            fixture.request.authority.signedAgreementSHA256
        )
        XCTAssertEqual(
            admission.mutationReceipt.targetOwnerIdentityUUID,
            fixture.request.authority.targetOwnerIdentityUUID
        )
        XCTAssertEqual(admission.authority.signedAgreementSHA256, fixture.signedAgreementSHA256)
        let requestCount = await fixture.authorityCell.authorityRequestCount()
        let mutationCount = await fixture.authorityCell.mutationCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(mutationCount, 1)
    }

    func testCanonicalDecoderRejectsAlternateRawBytesAndOversizedEnvelope() async throws {
        let fixture = try await makeFixture()
        var nonCanonical = fixture.requestData
        nonCanonical.append(0x0A)

        XCTAssertThrowsError(try DeviceIngressCanonicalWire.decodeCanonical(nonCanonical)) { error in
            XCTAssertEqual(error as? DeviceIngressCanonicalWireError, .nonCanonicalPayload)
        }
        XCTAssertThrowsError(
            try DeviceIngressCanonicalWire.decodeCanonical(
                Data(repeating: 0x20, count: DeviceIngressEnvelope.maximumEncodedBytes + 1)
            )
        ) { error in
            XCTAssertEqual(error as? DeviceIngressCanonicalWireError, .payloadTooLarge)
        }
    }

    func testRejectsWrongAudienceDomainPurposeAndSubject() async throws {
        let fixture = try await makeFixture()

        var wrongAudience = fixture.request
        wrongAudience.audience = "attacker.example"
        wrongAudience.proof = nil
        wrongAudience = try await DeviceIngressEnvelopeSigner.sign(
            wrongAudience,
            with: fixture.subject
        )
        try await assertRequestError(
            .wrongAudience,
            requestData: wrongAudience.canonicalWireData(),
            fixture: fixture
        )

        var wrongDomain = fixture.request
        wrongDomain.identityDomain = "domain:device:attacker"
        wrongDomain.proof = nil
        wrongDomain = try await DeviceIngressEnvelopeSigner.sign(
            wrongDomain,
            with: fixture.subject
        )
        try await assertRequestError(
            .wrongDomain,
            requestData: wrongDomain.canonicalWireData(),
            fixture: fixture
        )

        var wrongPurpose = fixture.request
        wrongPurpose.purpose = "purpose://scaffold.operations"
        wrongPurpose.proof = nil
        wrongPurpose = try await DeviceIngressEnvelopeSigner.sign(
            wrongPurpose,
            with: fixture.subject
        )
        try await assertRequestError(
            .wrongPurpose,
            requestData: wrongPurpose.canonicalWireData(),
            fixture: fixture
        )

        let attackerVault = EphemeralIdentityVault()
        var attacker = Identity(
            "33333333-3333-4333-8333-333333333333",
            displayName: DeviceIngressEnvelope.identityDomain,
            identityVault: attackerVault
        )
        await attackerVault.addIdentity(
            identity: &attacker,
            for: DeviceIngressEnvelope.identityDomain
        )
        var wrongSubject = fixture.request
        wrongSubject.subject = try XCTUnwrap(
            DeviceIngressIdentityDescriptor.publicDescriptor(for: attacker)
        )
        wrongSubject.signer = wrongSubject.subject
        wrongSubject.domainBinding = await attackerVault.identityDomainBinding(for: attacker)
        wrongSubject.proof = nil
        wrongSubject = try await DeviceIngressEnvelopeSigner.sign(
            wrongSubject,
            with: attacker
        )
        try await assertRequestError(
            .authoritySubjectMismatch,
            requestData: wrongSubject.canonicalWireData(),
            fixture: fixture
        )
    }

    func testRejectsExpiredFutureAndOutOfChallengeRequests() async throws {
        let fixture = try await makeFixture()

        var expired = fixture.request
        expired.issuedAtMilliseconds = milliseconds(now.addingTimeInterval(-30))
        expired.expiresAtMilliseconds = milliseconds(now.addingTimeInterval(-1))
        expired.proof = nil
        expired = try await DeviceIngressEnvelopeSigner.sign(expired, with: fixture.subject)
        try await assertRequestError(
            .expired,
            requestData: expired.canonicalWireData(),
            fixture: fixture
        )

        var future = fixture.request
        future.issuedAtMilliseconds = milliseconds(now.addingTimeInterval(31))
        future.expiresAtMilliseconds = milliseconds(now.addingTimeInterval(91))
        future.proof = nil
        future = try await DeviceIngressEnvelopeSigner.sign(future, with: fixture.subject)
        try await assertRequestError(
            .issuedInFuture,
            requestData: future.canonicalWireData(),
            fixture: fixture
        )

        var outside = fixture.request
        outside.issuedAtMilliseconds += 1
        outside.expiresAtMilliseconds = fixture.challenge.expiresAtMilliseconds + 1
        outside.proof = nil
        outside = try await DeviceIngressEnvelopeSigner.sign(outside, with: fixture.subject)
        try await assertRequestError(
            .requestOutsideChallengeLifetime,
            requestData: outside.canonicalWireData(),
            fixture: fixture
        )

        var expiresExactlyNow = fixture.request
        expiresExactlyNow.issuedAtMilliseconds = milliseconds(now.addingTimeInterval(-30))
        expiresExactlyNow.expiresAtMilliseconds = milliseconds(now)
        expiresExactlyNow.proof = nil
        expiresExactlyNow = try await DeviceIngressEnvelopeSigner.sign(
            expiresExactlyNow,
            with: fixture.subject
        )
        try await assertRequestError(
            .expired,
            requestData: expiresExactlyNow.canonicalWireData(),
            fixture: fixture
        )
    }

    func testRejectsBodyChallengeAndSignatureByteMismatchAndOversizedBody() async throws {
        let fixture = try await makeFixture()

        try await assertRequestError(
            .bodyDigestMismatch,
            requestData: fixture.requestData,
            body: Data("tampered".utf8),
            fixture: fixture
        )

        var wrongChallengeDigest = fixture.request
        wrongChallengeDigest.challengeSHA256 = Data(repeating: 0, count: 32)
        wrongChallengeDigest.proof = nil
        wrongChallengeDigest = try await DeviceIngressEnvelopeSigner.sign(
            wrongChallengeDigest,
            with: fixture.subject
        )
        try await assertRequestError(
            .challengeDigestMismatch,
            requestData: wrongChallengeDigest.canonicalWireData(),
            fixture: fixture
        )

        var tampered = fixture.request
        var tamperedSignature = try XCTUnwrap(tampered.proof?.signature)
        tamperedSignature[0] ^= 0x01
        tampered.proof?.signature = tamperedSignature
        try await assertRequestError(
            .invalidProof,
            requestData: tampered.canonicalWireData(),
            fixture: fixture
        )

        try await assertRequestError(
            .bodyTooLarge,
            requestData: fixture.requestData,
            body: Data(repeating: 0, count: DeviceIngressEnvelope.maximumBodyBytes + 1),
            fixture: fixture
        )
    }

    func testRejectsWrongIssuerOperationBindingAndNonceBounds() async throws {
        let fixture = try await makeFixture()
        let untrustedVault = EphemeralIdentityVault()
        var untrusted = Identity(
            "44444444-4444-4444-8444-444444444444",
            displayName: "untrusted",
            identityVault: untrustedVault
        )
        await untrustedVault.addIdentity(identity: &untrusted, for: "untrusted")
        let untrustedDescriptor = try XCTUnwrap(
            DeviceIngressIdentityDescriptor.publicDescriptor(for: untrusted)
        )
        XCTAssertThrowsError(
            try DeviceIngressEnvelopeVerifier.verifyChallenge(
                canonicalData: fixture.challengeData,
                expectedAudience: audience,
                expectedIssuer: untrustedDescriptor,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? DeviceIngressValidationError, .invalidProof)
        }

        var wrongBinding = fixture.request
        wrongBinding.capability = DeviceIngressOperation.submit.capability
        wrongBinding.proof = nil
        wrongBinding = try await DeviceIngressEnvelopeSigner.sign(
            wrongBinding,
            with: fixture.subject
        )
        try await assertRequestError(
            .operationBindingMismatch,
            requestData: wrongBinding.canonicalWireData(),
            fixture: fixture
        )

        var shortNonce = fixture.request
        shortNonce.nonce = Data(repeating: 0x01, count: 31)
        shortNonce.proof = nil
        shortNonce = try await DeviceIngressEnvelopeSigner.sign(
            shortNonce,
            with: fixture.subject
        )
        try await assertRequestError(
            .invalidNonce,
            requestData: shortNonce.canonicalWireData(),
            fixture: fixture
        )
    }

    func testRequesterCannotRetargetChallengeAfterSigning() async throws {
        let fixture = try await makeFixture()
        var retargeted = fixture.request
        retargeted.authority.targetCellUUID = "99999999-9999-4999-8999-999999999999"
        retargeted.proof = nil
        retargeted = try await DeviceIngressEnvelopeSigner.sign(
            retargeted,
            with: fixture.subject
        )

        try await assertRequestError(
            .challengeMismatch,
            requestData: retargeted.canonicalWireData(),
            fixture: fixture
        )
    }

    func testRejectsReplayBeforeSecondCellMutation() async throws {
        let fixture = try await makeFixture()
        _ = try await admit(fixture)

        do {
            _ = try await admit(fixture)
            XCTFail("Expected a replay rejection")
        } catch let error as DeviceIngressValidationError {
            XCTAssertEqual(error, .replayDetected)
        }
        let requestCount = await fixture.authorityCell.authorityRequestCount()
        let mutationCount = await fixture.authorityCell.mutationCount()
        let recordCount = await fixture.ledger.committedRecordsSnapshot().count
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(mutationCount, 1)
        XCTAssertEqual(recordCount, 1)
    }

    func testConcurrentReplayProducesOneMutationAndOneRejection() async throws {
        let fixture = try await makeFixture()
        async let first = admissionOutcome(fixture)
        async let second = admissionOutcome(fixture)
        let concurrentOutcomes = await (first, second)
        let outcomes = [concurrentOutcomes.0, concurrentOutcomes.1].sorted()

        XCTAssertEqual(outcomes, ["replayDetected", "success"])
        let mutationCount = await fixture.authorityCell.mutationCount()
        let recordCount = await fixture.ledger.committedRecordsSnapshot().count
        XCTAssertEqual(mutationCount, 1)
        XCTAssertEqual(recordCount, 1)
    }

    func testRejectsMissingProofDigestInvalidBindingAndGenerationOverflow() async throws {
        let fixture = try await makeFixture()

        var missingProof = fixture.request
        missingProof.proof = nil
        try await assertRequestError(
            .invalidProof,
            requestData: missingProof.canonicalWireData(),
            fixture: fixture
        )

        var missingDigest = fixture.request
        missingDigest.bodySHA256 = nil
        missingDigest.proof = nil
        missingDigest = try await DeviceIngressEnvelopeSigner.sign(
            missingDigest,
            with: fixture.subject
        )
        try await assertRequestError(
            .missingBodyDigest,
            requestData: missingDigest.canonicalWireData(),
            fixture: fixture
        )

        var invalidBinding = fixture.request
        invalidBinding.domainBinding = nil
        invalidBinding.proof = nil
        invalidBinding = try await DeviceIngressEnvelopeSigner.sign(
            invalidBinding,
            with: fixture.subject
        )
        try await assertRequestError(
            .invalidDomainBinding,
            requestData: invalidBinding.canonicalWireData(),
            fixture: fixture
        )

        var legacyAuthority = fixture.request
        legacyAuthority.authority.schema = "cellprotocol.device-ingress.authority-reference.v1"
        legacyAuthority.proof = nil
        legacyAuthority = try await DeviceIngressEnvelopeSigner.sign(
            legacyAuthority,
            with: fixture.subject
        )
        try await assertRequestError(
            .invalidAuthorityReference,
            requestData: legacyAuthority.canonicalWireData(),
            fixture: fixture
        )

        var overflow = fixture.request
        overflow.authority.authorityGeneration =
            DeviceIngressAuthorityReference.maximumJSONSafeGeneration + 1
        overflow.proof = nil
        overflow = try await DeviceIngressEnvelopeSigner.sign(
            overflow,
            with: fixture.subject
        )
        try await assertRequestError(
            .invalidAuthorityReference,
            requestData: overflow.canonicalWireData(),
            fixture: fixture
        )
    }

    func testRequiresCryptographicAgreementSubjectGrantAndCurrentGenerations() async throws {
        try await assertAdmissionError(
            .authorityDenied("agreement_missing"),
            mode: .denied
        )
        try await assertAdmissionError(.agreementProofInvalid, mode: .wrongAgreementGrant)
        try await assertAdmissionError(.agreementProofInvalid, mode: .wrongAgreementSubject)
        try await assertAdmissionError(.agreementProofInvalid, mode: .tamperedAgreement)
        try await assertAdmissionError(.authorityGenerationStale, mode: .higherGeneration)
        try await assertAdmissionError(.revocationRollbackDetected, mode: .lowerGeneration)
    }

    func testSignedChallengePinsResolverTargetOwnerAndExactAgreementBytes() async throws {
        let substitutions: [(Mode, DeviceIngressValidationError, Int)] = [
            (.wrongResolvedTargetCell, .authorityResolutionMismatch, 0),
            (.wrongResolvedTargetOwner, .authorityResolutionMismatch, 0),
            (.wrongSignedAgreementDigest, .agreementProofInvalid, 1),
        ]

        for (mode, expectedError, expectedAuthorityRequests) in substitutions {
            let fixture = try await makeFixture(mode: mode)
            do {
                _ = try await admit(fixture)
                XCTFail("Expected resolver/Contract substitution to be rejected for \(mode)")
            } catch let error as DeviceIngressValidationError {
                XCTAssertEqual(error, expectedError)
            }
            let authorityRequestCount = await fixture.authorityCell.authorityRequestCount()
            let admissionCount = await fixture.ledger.committedRecordsSnapshot().count
            let mutationCount = await fixture.authorityCell.mutationCount()
            XCTAssertEqual(authorityRequestCount, expectedAuthorityRequests)
            XCTAssertEqual(admissionCount, 0)
            XCTAssertEqual(mutationCount, 0)
        }
    }

    func testRevocationBetweenAdmissionAndMutationConsumesChallengeWithoutMutation() async throws {
        let fixture = try await makeFixture(mode: .revokeBeforeMutation)
        do {
            _ = try await admit(fixture)
            XCTFail("Expected mutation-time revocation")
        } catch let error as DeviceIngressValidationError {
            XCTAssertEqual(error, .mutationDenied("revoked_before_mutation"))
        }
        let recordCount = await fixture.ledger.committedRecordsSnapshot().count
        let mutationCount = await fixture.authorityCell.mutationCount()
        XCTAssertEqual(recordCount, 1)
        XCTAssertEqual(mutationCount, 0)
    }

    func testRejectsNonDurableAdmissionAndInvalidMutationReceipts() async throws {
        let nonDurable = try await makeFixture(ledgerMode: .nonDurable)
        do {
            _ = try await admit(nonDurable)
            XCTFail("Expected non-durable receipt rejection")
        } catch let error as DeviceIngressValidationError {
            XCTAssertEqual(error, .invalidAdmissionReceipt)
        }
        let nonDurableMutationCount = await nonDurable.authorityCell.mutationCount()
        XCTAssertEqual(nonDurableMutationCount, 0)

        let wrongAdmissionPin = try await makeFixture(ledgerMode: .wrongTargetPin)
        do {
            _ = try await admit(wrongAdmissionPin)
            XCTFail("Expected target-pin receipt rejection")
        } catch let error as DeviceIngressValidationError {
            XCTAssertEqual(error, .invalidAdmissionReceipt)
        }
        let wrongAdmissionPinMutationCount = await wrongAdmissionPin.authorityCell.mutationCount()
        XCTAssertEqual(wrongAdmissionPinMutationCount, 0)

        let invalidMutation = try await makeFixture(mode: .invalidMutationReceipt)
        do {
            _ = try await admit(invalidMutation)
            XCTFail("Expected mutation receipt rejection")
        } catch let error as DeviceIngressValidationError {
            XCTAssertEqual(error, .invalidMutationReceipt)
        }
        let invalidMutationCount = await invalidMutation.authorityCell.mutationCount()
        XCTAssertEqual(invalidMutationCount, 0)
    }

    func testAuthorityBearingResultsExposeReadOnlyKeyPaths() {
        XCTAssertFalse(isWritable(\DeviceIngressVerifiedPair.request))
        XCTAssertFalse(isWritable(\DeviceIngressAuthorityRequest.authority))
        XCTAssertFalse(isWritable(\DeviceIngressCompletedAdmission.mutationReceipt))
        XCTAssertFalse(isWritable(\DeviceIngressAdmissionRecord.revocationGeneration))
    }

    func testChallengeFactoryGeneratesPrivateDescriptorsAndFreshCSPRNGNonces() async throws {
        let fixture = try await makeFixture()
        let first = try await DeviceIngressChallengeFactory.issue(
            operation: .register,
            audience: audience,
            subject: fixture.request.subject,
            authority: fixture.request.authority,
            issuer: fixture.issuer,
            now: now
        )
        let second = try await DeviceIngressChallengeFactory.issue(
            operation: .register,
            audience: audience,
            subject: fixture.request.subject,
            authority: fixture.request.authority,
            issuer: fixture.issuer,
            now: now
        )
        let firstEnvelope = try DeviceIngressCanonicalWire.decodeCanonical(first)
        let secondEnvelope = try DeviceIngressCanonicalWire.decodeCanonical(second)

        XCTAssertEqual(firstEnvelope.nonce.count, 32)
        XCTAssertNotEqual(firstEnvelope.nonce, secondEnvelope.nonce)
        XCTAssertNotEqual(firstEnvelope.challengeID, secondEnvelope.challengeID)
        XCTAssertNil(firstEnvelope.subject.displayName)
        XCTAssertNil(firstEnvelope.signer.displayName)

        var invalidAuthority = fixture.request.authority
        invalidAuthority.signedAgreementSHA256 = Data()
        do {
            _ = try await DeviceIngressChallengeFactory.issue(
                operation: .register,
                audience: audience,
                subject: fixture.request.subject,
                authority: invalidAuthority,
                issuer: fixture.issuer,
                now: now
            )
            XCTFail("Expected the challenge factory to reject an incomplete target pin")
        } catch let error as DeviceIngressValidationError {
            XCTAssertEqual(error, .invalidAuthorityReference)
        }
    }

    private enum Mode: Equatable {
        case authorized
        case denied
        case wrongAgreementGrant
        case wrongAgreementSubject
        case tamperedAgreement
        case higherGeneration
        case lowerGeneration
        case wrongResolvedTargetCell
        case wrongResolvedTargetOwner
        case wrongSignedAgreementDigest
        case revokeBeforeMutation
        case invalidMutationReceipt
    }

    private struct Fixture {
        let issuer: Identity
        let issuerDescriptor: IdentityPublicKeyDescriptor
        let subject: Identity
        let challenge: DeviceIngressEnvelope
        let challengeData: Data
        let request: DeviceIngressEnvelope
        let requestData: Data
        let body: Data
        let service: DeviceIngressAdmissionService
        let ledger: FixtureAdmissionLedger
        let authorityCell: FixtureDeviceIngressAuthorityCell
        let signedAgreementSHA256: Data
    }

    private func makeFixture(
        mode: Mode = .authorized,
        ledgerMode: FixtureAdmissionLedger.ReceiptMode = .valid
    ) async throws -> Fixture {
        let issuerVault = EphemeralIdentityVault()
        var issuer = Identity(
            "11111111-1111-4111-8111-111111111111",
            displayName: "Device ingress authority",
            identityVault: issuerVault
        )
        await issuerVault.addIdentity(
            identity: &issuer,
            for: "domain:scaffold:device-ingress-challenge"
        )
        let subjectVault = EphemeralIdentityVault()
        var subject = Identity(
            "22222222-2222-4222-8222-222222222222",
            displayName: DeviceIngressEnvelope.identityDomain,
            identityVault: subjectVault
        )
        await subjectVault.addIdentity(
            identity: &subject,
            for: DeviceIngressEnvelope.identityDomain
        )
        let issuerDescriptor = try XCTUnwrap(
            DeviceIngressIdentityDescriptor.publicDescriptor(for: issuer)
        )
        let subjectDescriptor = try XCTUnwrap(
            DeviceIngressIdentityDescriptor.publicDescriptor(for: subject)
        )
        let subjectFingerprint = try XCTUnwrap(subject.signingPublicKeyFingerprint)

        let scope = DeviceIngressAgreementScope(
            operation: .register,
            audience: audience
        )
        let agreementSubject: Identity
        if mode == .wrongAgreementSubject {
            let wrongSubjectVault = EphemeralIdentityVault()
            var wrongSubject = Identity(
                "55555555-5555-4555-8555-555555555555",
                displayName: DeviceIngressEnvelope.identityDomain,
                identityVault: wrongSubjectVault
            )
            await wrongSubjectVault.addIdentity(
                identity: &wrongSubject,
                for: DeviceIngressEnvelope.identityDomain
            )
            agreementSubject = wrongSubject
        } else {
            agreementSubject = subject
        }
        let agreement = Agreement(owner: issuer)
        agreement.conditions = []
        agreement.grants = [Grant(
            keypath: mode == .wrongAgreementGrant
                ? "deviceIngress.wrong"
                : try scope.grantKeypath(),
            permission: DeviceIngressOperation.register.requiredAccess
        )]
        agreement.signatories = [issuer, agreementSubject]
        agreement.state = .signed
        agreement.duration = 3_600
        let contract = try await Contract.signed(
            agreement: agreement,
            issuer: issuer,
            subject: agreementSubject,
            domain: DeviceIngressEnvelope.identityDomain,
            issuedAt: now.addingTimeInterval(-60)
        )
        if mode == .tamperedAgreement {
            contract.agreement.name = "tampered after signing"
        }
        let canonicalAgreement = try SignedAgreementEntitySupport.canonicalData(contract)
        let canonicalAgreementSHA256 = DeviceIngressCanonicalWire.sha256(canonicalAgreement)
        let targetCellUUID = "66666666-6666-4666-8666-666666666666"
        let targetOwnerFingerprint = try XCTUnwrap(issuer.signingPublicKeyFingerprint)
        let referenceGeneration: UInt64 = mode == .lowerGeneration ? 2 : 1
        let evidenceGeneration: UInt64
        switch mode {
        case .higherGeneration:
            evidenceGeneration = referenceGeneration + 1
        case .lowerGeneration:
            evidenceGeneration = referenceGeneration - 1
        default:
            evidenceGeneration = referenceGeneration
        }
        let authority = DeviceIngressAuthorityReference(
            authorityID: "authority-1",
            agreementID: contract.uuid,
            targetCellUUID: targetCellUUID,
            targetOwnerIdentityUUID: issuer.uuid,
            targetOwnerSigningKeyFingerprint: targetOwnerFingerprint,
            signedAgreementSHA256: mode == .wrongSignedAgreementDigest
                ? Data(repeating: 0, count: 32)
                : canonicalAgreementSHA256,
            subjectIdentityUUID: subject.uuid,
            subjectSigningKeyFingerprint: subjectFingerprint,
            authorityGeneration: referenceGeneration,
            revocationLedgerID: "device-revocations-1",
            revocationGeneration: referenceGeneration,
            issuedAtMilliseconds: milliseconds(
                Date(timeIntervalSince1970: contract.issuedAt)
            ),
            validUntilMilliseconds: milliseconds(
                Date(timeIntervalSince1970: contract.expiresAt)
            )
        )
        let challengeData = try await DeviceIngressChallengeFactory.issue(
            operation: .register,
            audience: audience,
            subject: subjectDescriptor,
            authority: authority,
            issuer: issuer,
            now: now,
            lifetimeMilliseconds: 120_000,
            envelopeID: "challenge-envelope-1",
            challengeID: "challenge-1",
            nonce: Data((0..<32).map(UInt8.init))
        )
        let challenge = try DeviceIngressCanonicalWire.decodeCanonical(challengeData)
        let body = Data(#"{"participantId":"binding-participant","pushToken":"private"}"#.utf8)
        let bindingCandidate = await subjectVault.identityDomainBinding(for: subject)
        let binding = try XCTUnwrap(bindingCandidate)
        let requestData = try await DeviceIngressRequestFactory.sign(
            canonicalChallengeData: challengeData,
            protectedBody: body,
            requester: subject,
            domainBinding: binding,
            expectedAudience: audience,
            expectedChallengeIssuer: issuerDescriptor,
            now: now
        )
        let request = try DeviceIngressCanonicalWire.decodeCanonical(requestData)
        let evidence = DeviceIngressAuthorityEvidence(
            canonicalSignedAgreement: canonicalAgreement,
            authorityID: authority.authorityID,
            authorityGeneration: evidenceGeneration,
            revocationLedgerID: authority.revocationLedgerID,
            revocationGeneration: evidenceGeneration
        )
        let substituteOwnerVault = EphemeralIdentityVault()
        var substituteOwner = Identity(
            "77777777-7777-4777-8777-777777777777",
            displayName: "Substituted resolver owner",
            identityVault: substituteOwnerVault
        )
        await substituteOwnerVault.addIdentity(
            identity: &substituteOwner,
            for: "domain:scaffold:substituted-device-ingress"
        )
        let authorityCell = await FixtureDeviceIngressAuthorityCell(
            owner: mode == .wrongResolvedTargetOwner ? substituteOwner : issuer,
            decision: mode == .denied
                ? .denied(reasonCode: "agreement_missing")
                : .authorized(evidence),
            mutationMode: mode == .revokeBeforeMutation
                ? .revokeBeforeMutation
                : mode == .invalidMutationReceipt ? .invalidReceipt : .commit,
            currentAuthorityGeneration: evidenceGeneration,
            currentRevocationGeneration: evidenceGeneration,
            signedAgreementSHA256: canonicalAgreementSHA256
        )
        authorityCell.uuid = mode == .wrongResolvedTargetCell
            ? "88888888-8888-4888-8888-888888888888"
            : targetCellUUID
        let resolver = MockCellResolver()
        try await resolver.registerNamedEmitCell(
            name: "DeviceRegistration",
            emitCell: authorityCell,
            scope: .scaffoldUnique,
            identity: issuer
        )
        let ledger = FixtureAdmissionLedger(receiptMode: ledgerMode)
        let service = DeviceIngressAdmissionService(
            expectedAudience: audience,
            expectedChallengeIssuer: issuerDescriptor,
            resolver: resolver,
            ledger: ledger
        )
        return Fixture(
            issuer: issuer,
            issuerDescriptor: issuerDescriptor,
            subject: subject,
            challenge: challenge,
            challengeData: challengeData,
            request: request,
            requestData: requestData,
            body: body,
            service: service,
            ledger: ledger,
            authorityCell: authorityCell,
            signedAgreementSHA256: canonicalAgreementSHA256
        )
    }

    private func admit(_ fixture: Fixture) async throws -> DeviceIngressCompletedAdmission {
        try await fixture.service.admitAndMutate(
            canonicalRequestData: fixture.requestData,
            protectedBody: fixture.body,
            canonicalChallengeData: fixture.challengeData,
            now: now
        )
    }

    private func admissionOutcome(_ fixture: Fixture) async -> String {
        do {
            _ = try await admit(fixture)
            return "success"
        } catch let error as DeviceIngressValidationError {
            return String(describing: error)
        } catch {
            return "unexpected:\(String(describing: error))"
        }
    }

    private func assertAdmissionError(
        _ expected: DeviceIngressValidationError,
        mode: Mode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try await makeFixture(mode: mode)
        do {
            _ = try await admit(fixture)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as DeviceIngressValidationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    private func assertRequestError(
        _ expected: DeviceIngressValidationError,
        requestData: Data,
        body: Data? = nil,
        fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try DeviceIngressEnvelopeVerifier.verifyRequest(
                canonicalData: requestData,
                protectedBody: body ?? fixture.body,
                canonicalChallengeData: fixture.challengeData,
                expectedAudience: audience,
                expectedChallengeIssuer: fixture.issuerDescriptor,
                now: now
            )
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as DeviceIngressValidationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    private func isWritable<Root, Value>(_ keyPath: KeyPath<Root, Value>) -> Bool { false }
    private func isWritable<Root, Value>(_ keyPath: WritableKeyPath<Root, Value>) -> Bool { true }
}

private final class FixtureDeviceIngressAuthorityCell: GeneralCell, DeviceIngressAuthorityCell {
    enum MutationMode: Equatable {
        case commit
        case revokeBeforeMutation
        case invalidReceipt
    }

    private actor State {
        var requests: [DeviceIngressAuthorityRequest] = []
        var mutationAdmissionIDs: [String] = []
        let decision: DeviceIngressAuthorityDecision
        let mutationMode: MutationMode
        var currentAuthorityGeneration: UInt64
        var currentRevocationGeneration: UInt64
        let signedAgreementSHA256: Data

        init(
            decision: DeviceIngressAuthorityDecision,
            mutationMode: MutationMode,
            currentAuthorityGeneration: UInt64,
            currentRevocationGeneration: UInt64,
            signedAgreementSHA256: Data
        ) {
            self.decision = decision
            self.mutationMode = mutationMode
            self.currentAuthorityGeneration = currentAuthorityGeneration
            self.currentRevocationGeneration = currentRevocationGeneration
            self.signedAgreementSHA256 = signedAgreementSHA256
        }

        func resolve(_ request: DeviceIngressAuthorityRequest) -> DeviceIngressAuthorityDecision {
            requests.append(request)
            return decision
        }

        func commit(
            _ command: DeviceIngressMutationCommand,
            targetCellUUID: String,
            targetOwnerIdentityUUID: String,
            targetOwnerFingerprint: String
        ) -> DeviceIngressMutationDecision {
            if mutationMode == .revokeBeforeMutation {
                currentRevocationGeneration += 1
                return .denied(reasonCode: "revoked_before_mutation")
            }
            guard mutationMode != .invalidReceipt,
                  command.admissionRecord.targetCellUUID == targetCellUUID,
                  command.admissionRecord.targetOwnerSigningKeyFingerprint
                    == targetOwnerFingerprint,
                  command.admissionRecord.authorityGeneration
                    == currentAuthorityGeneration,
                  command.admissionRecord.revocationGeneration
                    == currentRevocationGeneration,
                  command.admissionRecord.signedAgreementSHA256
                    == signedAgreementSHA256 else {
                return .committed(DeviceIngressMutationReceipt(
                    admissionID: "invalid",
                    requestSHA256: Data(),
                    targetCellUUID: targetCellUUID,
                    targetOwnerIdentityUUID: targetOwnerIdentityUUID,
                    targetOwnerSigningKeyFingerprint: targetOwnerFingerprint,
                    signedAgreementSHA256: signedAgreementSHA256,
                    authorityGeneration: currentAuthorityGeneration,
                    revocationGeneration: currentRevocationGeneration,
                    mutationRecordSHA256: Data(),
                    committedAtMilliseconds: command.admissionReceipt.committedAtMilliseconds
                ))
            }
            mutationAdmissionIDs.append(command.admissionRecord.admissionID)
            return .committed(DeviceIngressMutationReceipt(
                admissionID: command.admissionRecord.admissionID,
                requestSHA256: command.admissionRecord.requestSHA256,
                targetCellUUID: targetCellUUID,
                targetOwnerIdentityUUID: targetOwnerIdentityUUID,
                targetOwnerSigningKeyFingerprint: targetOwnerFingerprint,
                signedAgreementSHA256: signedAgreementSHA256,
                authorityGeneration: currentAuthorityGeneration,
                revocationGeneration: currentRevocationGeneration,
                mutationRecordSHA256: DeviceIngressCanonicalWire.sha256(command.protectedBody),
                committedAtMilliseconds: command.admissionReceipt.committedAtMilliseconds
            ))
        }
    }

    private let state: State

    required init(owner: Identity) async {
        state = State(
            decision: .denied(reasonCode: "unconfigured"),
            mutationMode: .commit,
            currentAuthorityGeneration: 0,
            currentRevocationGeneration: 0,
            signedAgreementSHA256: Data()
        )
        await super.init(owner: owner)
    }

    init(
        owner: Identity,
        decision: DeviceIngressAuthorityDecision,
        mutationMode: MutationMode,
        currentAuthorityGeneration: UInt64,
        currentRevocationGeneration: UInt64,
        signedAgreementSHA256: Data
    ) async {
        state = State(
            decision: decision,
            mutationMode: mutationMode,
            currentAuthorityGeneration: currentAuthorityGeneration,
            currentRevocationGeneration: currentRevocationGeneration,
            signedAgreementSHA256: signedAgreementSHA256
        )
        await super.init(owner: owner)
    }

    required init(from decoder: Decoder) throws {
        state = State(
            decision: .denied(reasonCode: "decoded_fixture_denied"),
            mutationMode: .commit,
            currentAuthorityGeneration: 0,
            currentRevocationGeneration: 0,
            signedAgreementSHA256: Data()
        )
        try super.init(from: decoder)
    }

    func resolveDeviceIngressAuthority(
        for request: DeviceIngressAuthorityRequest
    ) async -> DeviceIngressAuthorityDecision {
        await state.resolve(request)
    }

    func commitDeviceIngressMutation(
        _ command: DeviceIngressMutationCommand
    ) async -> DeviceIngressMutationDecision {
        let owner = storedOwnerIdentity
        let fingerprint = owner.signingPublicKeyFingerprint ?? ""
        return await state.commit(
            command,
            targetCellUUID: uuid,
            targetOwnerIdentityUUID: owner.uuid,
            targetOwnerFingerprint: fingerprint
        )
    }

    func authorityRequestCount() async -> Int { await state.requests.count }
    func mutationCount() async -> Int { await state.mutationAdmissionIDs.count }
}

private actor FixtureAdmissionLedger: DeviceIngressDurableAdmissionLedger {
    enum ReceiptMode {
        case valid
        case nonDurable
        case wrongTargetPin
    }

    private var records: [DeviceIngressAdmissionRecord] = []
    private var nonceDigests: Set<Data> = []
    private let receiptMode: ReceiptMode

    init(receiptMode: ReceiptMode = .valid) {
        self.receiptMode = receiptMode
    }

    func commit(_ record: DeviceIngressAdmissionRecord) async -> DeviceIngressAdmissionCommitOutcome {
        guard nonceDigests.insert(record.nonceSHA256).inserted else {
            return .replay(existingAdmissionID: record.admissionID)
        }
        records.append(record)
        guard let canonical = try? record.canonicalData() else {
            return .unavailable
        }
        return .committed(DeviceIngressAdmissionReceipt(
            admissionID: record.admissionID,
            recordSHA256: DeviceIngressCanonicalWire.sha256(canonical),
            requestSHA256: record.requestSHA256,
            targetCellUUID: receiptMode == .wrongTargetPin
                ? "99999999-9999-4999-8999-999999999999"
                : record.targetCellUUID,
            targetOwnerIdentityUUID: record.targetOwnerIdentityUUID,
            targetOwnerSigningKeyFingerprint: record.targetOwnerSigningKeyFingerprint,
            signedAgreementSHA256: record.signedAgreementSHA256,
            authorityGeneration: record.authorityGeneration,
            revocationGeneration: record.revocationGeneration,
            durableSequence: UInt64(records.count),
            committedAtMilliseconds: record.admittedAtMilliseconds,
            persistenceSemantics: receiptMode == .nonDurable
                ? "memory_only"
                : DeviceIngressAdmissionReceipt.durableBeforeMutation
        ))
    }

    func committedRecordsSnapshot() -> [DeviceIngressAdmissionRecord] { records }
}
