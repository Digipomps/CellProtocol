// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum DIDDocumentValidationError: Error, Equatable {
    case invalidDocumentID(String)
    case missingVerificationMethods
    case duplicateVerificationMethodID(String)
    case verificationMethodControllerMismatch(id: String, controller: String)
    case missingPublicKeyMaterial(String)
    case missingReferencedVerificationMethod(String)
    case missingVerificationMethodForUse(String)
}

public enum DIDIssuerBindingError: Error, Equatable {
    case issuerMustBeDID(String)
    case issuerDocumentMismatch(expected: String, actual: String)
    case keyIDMustBeDIDURL(String)
    case keyIDDocumentMismatch(expected: String, actual: String)
    case keyIDNotAuthorizedForUse(keyID: String, use: String)
}

public struct DIDDocumentValidationResult: Equatable, Sendable {
    public var verificationMethodIDs: [String]
    public var assertionMethodIDs: [String]
    public var authenticationMethodIDs: [String]
    public var keyAgreementMethodIDs: [String]

    public init(
        verificationMethodIDs: [String],
        assertionMethodIDs: [String],
        authenticationMethodIDs: [String],
        keyAgreementMethodIDs: [String]
    ) {
        self.verificationMethodIDs = verificationMethodIDs
        self.assertionMethodIDs = assertionMethodIDs
        self.authenticationMethodIDs = authenticationMethodIDs
        self.keyAgreementMethodIDs = keyAgreementMethodIDs
    }
}

public enum DIDDocumentValidator {
    public static func validate(_ didDocument: DIDDocument) throws -> DIDDocumentValidationResult {
        guard didDocument.id.hasPrefix("did:") else {
            throw DIDDocumentValidationError.invalidDocumentID(didDocument.id)
        }

        guard let verificationMethods = didDocument.verificationMethods, !verificationMethods.isEmpty else {
            throw DIDDocumentValidationError.missingVerificationMethods
        }

        var knownMethodIDs = Set<String>()
        for verificationMethod in verificationMethods {
            if !knownMethodIDs.insert(verificationMethod.id).inserted {
                throw DIDDocumentValidationError.duplicateVerificationMethodID(verificationMethod.id)
            }
            if verificationMethod.controller != didDocument.id {
                throw DIDDocumentValidationError.verificationMethodControllerMismatch(
                    id: verificationMethod.id,
                    controller: verificationMethod.controller
                )
            }
            if !hasPublicKeyMaterial(verificationMethod) {
                throw DIDDocumentValidationError.missingPublicKeyMaterial(verificationMethod.id)
            }
        }

        let assertionMethodIDs = try resolveVerificationMethodIDs(for: .assertion, in: didDocument)
        let authenticationMethodIDs = try resolveVerificationMethodIDs(for: .authentication, in: didDocument)
        let keyAgreementMethodIDs = try resolveVerificationMethodIDs(for: .keyAgreement, in: didDocument)

        return DIDDocumentValidationResult(
            verificationMethodIDs: verificationMethods.map(\.id).sorted(),
            assertionMethodIDs: assertionMethodIDs.sorted(),
            authenticationMethodIDs: authenticationMethodIDs.sorted(),
            keyAgreementMethodIDs: keyAgreementMethodIDs.sorted()
        )
    }

    public static func resolveVerificationMethodIDs(
        for use: DIDDocument.VCKeyUse,
        in didDocument: DIDDocument
    ) throws -> [String] {
        switch use {
        case .verification:
            return didDocument.verificationMethods?.map(\.id) ?? []
        case .assertion:
            return try resolve(idsFrom: didDocument.assertionMethods, in: didDocument)
        case .authentication:
            return try resolve(idsFrom: didDocument.authentications, in: didDocument)
        case .keyAgreement:
            return try resolve(idsFrom: didDocument.keyAgreements, in: didDocument)
        }
    }

    private static func resolve(
        idsFrom verifications: [DIDVerification]?,
        in didDocument: DIDDocument
    ) throws -> [String] {
        guard let verifications else { return [] }
        return try verifications.map { verification in
            let verificationMethod = try resolve(verification, in: didDocument)
            return verificationMethod.id
        }
    }

    private static func resolve(
        idsFrom authentications: [DIDAuthentication]?,
        in didDocument: DIDDocument
    ) throws -> [String] {
        guard let authentications else { return [] }
        return try authentications.map { authentication in
            let verificationMethod = try resolve(authentication, in: didDocument)
            return verificationMethod.id
        }
    }

    private static func resolve(
        _ verification: DIDVerification,
        in didDocument: DIDDocument
    ) throws -> DIDVerificationMethod {
        switch verification {
        case .embedded(let method):
            return method
        case .reference(let reference):
            guard let method = didDocument.verificationMethodsDict[reference] else {
                throw DIDDocumentValidationError.missingReferencedVerificationMethod(reference)
            }
            return method
        }
    }

    private static func resolve(
        _ authentication: DIDAuthentication,
        in didDocument: DIDDocument
    ) throws -> DIDVerificationMethod {
        switch authentication {
        case .reference(let reference):
            guard let method = didDocument.verificationMethodsDict[reference] else {
                throw DIDDocumentValidationError.missingReferencedVerificationMethod(reference)
            }
            return method
        case .embedded(let embedded):
            return DIDVerificationMethod(
                id: embedded.id,
                type: embedded.type,
                controller: didDocument.id,
                publicKeyType: .publicKeyMultibase(embedded.publicKeyMultibase)
            )
        }
    }

    private static func hasPublicKeyMaterial(_ verificationMethod: DIDVerificationMethod) -> Bool {
        switch verificationMethod.publicKeyType {
        case .publicKeyMultibase(let multibase):
            return !multibase.isEmpty
        case .publicBase58(let base58):
            return !base58.isEmpty
        case .publicKeyJwk(let jwk):
            return jwk.x?.isEmpty == false
        }
    }
}

public enum DIDIssuerBindingValidator {
    public static func validateIssuer(
        issuerIdentifier: String,
        didDocument: DIDDocument
    ) throws {
        guard issuerIdentifier.hasPrefix("did:") else {
            throw DIDIssuerBindingError.issuerMustBeDID(issuerIdentifier)
        }
        guard issuerIdentifier == didDocument.id else {
            throw DIDIssuerBindingError.issuerDocumentMismatch(
                expected: issuerIdentifier,
                actual: didDocument.id
            )
        }

        _ = try DIDDocumentValidator.validate(didDocument)

        let assertionMethodIDs = try DIDDocumentValidator.resolveVerificationMethodIDs(
            for: .assertion,
            in: didDocument
        )
        guard !assertionMethodIDs.isEmpty else {
            throw DIDDocumentValidationError.missingVerificationMethodForUse("assertion")
        }
    }

    public static func validateKeyID(
        _ keyID: String,
        issuerIdentifier: String,
        didDocument: DIDDocument,
        requiredUse: DIDDocument.VCKeyUse = .assertion
    ) throws {
        try validateIssuer(issuerIdentifier: issuerIdentifier, didDocument: didDocument)

        guard let fragmentIndex = keyID.firstIndex(of: "#") else {
            throw DIDIssuerBindingError.keyIDMustBeDIDURL(keyID)
        }

        let didPart = String(keyID[..<fragmentIndex])
        guard didPart == issuerIdentifier else {
            throw DIDIssuerBindingError.keyIDDocumentMismatch(
                expected: issuerIdentifier,
                actual: didPart
            )
        }

        let allowedMethodIDs = try DIDDocumentValidator.resolveVerificationMethodIDs(
            for: requiredUse,
            in: didDocument
        )
        guard allowedMethodIDs.contains(keyID) else {
            throw DIDIssuerBindingError.keyIDNotAuthorizedForUse(
                keyID: keyID,
                use: string(for: requiredUse)
            )
        }
    }

    private static func string(for use: DIDDocument.VCKeyUse) -> String {
        switch use {
        case .verification:
            return "verification"
        case .assertion:
            return "assertion"
        case .authentication:
            return "authentication"
        case .keyAgreement:
            return "keyAgreement"
        }
    }
}
