// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if canImport(Security)
import Security
#endif

public enum OID4VPSignedRequestTrustVerificationError: Error, Equatable {
    case unsupportedTrustMechanism(prefix: String)
    case missingDIDDocument(String)
    case missingTrustedAttestationIssuer(String)
    case missingX509TrustAnchors(String)
    case invalidX509CertificateChain
    case x509LeafCertificateHashMismatch(expected: String, actual: String)
    case x509DNSNameMismatch(expected: String)
    case requestSignatureInvalid
    case verifierAttestationSignatureInvalid
    case redirectURINotAllowed(String)
}

public enum OID4VPSignedRequestTrustSource: Equatable, Sendable {
    case decentralizedIdentifier(did: String, keyID: String)
    case verifierAttestation(issuer: String, subject: String)
    case x509Hash(hash: String)
    case x509SanDNS(dnsName: String)
}

public struct OID4VPSignedRequestTrustVerificationResult: Equatable, Sendable {
    public var source: OID4VPSignedRequestTrustSource
    public var requestSignatureVerified: Bool
    public var verifierAttestationSignatureVerified: Bool

    public init(
        source: OID4VPSignedRequestTrustSource,
        requestSignatureVerified: Bool,
        verifierAttestationSignatureVerified: Bool
    ) {
        self.source = source
        self.requestSignatureVerified = requestSignatureVerified
        self.verifierAttestationSignatureVerified = verifierAttestationSignatureVerified
    }
}

public protocol OID4VPSignedRequestTrustMaterialProvider {
    func didDocument(for did: String) async throws -> DIDDocument?
    func verifierAttestationIssuerJWKSet(for issuer: String) async throws -> JOSEJWKSet?
    func x509TrustAnchors(for requestObject: OID4VPRequestObject) async throws -> [Data]?
}

public struct OID4VPStaticSignedRequestTrustMaterialProvider: OID4VPSignedRequestTrustMaterialProvider {
    public var didDocumentsByIdentifier: [String: DIDDocument]
    public var verifierAttestationIssuerKeys: [String: JOSEJWKSet]
    public var x509TrustAnchorsByClientID: [String: [Data]]

    public init(
        didDocumentsByIdentifier: [String: DIDDocument] = [:],
        verifierAttestationIssuerKeys: [String: JOSEJWKSet] = [:],
        x509TrustAnchorsByClientID: [String: [Data]] = [:]
    ) {
        self.didDocumentsByIdentifier = didDocumentsByIdentifier
        self.verifierAttestationIssuerKeys = verifierAttestationIssuerKeys
        self.x509TrustAnchorsByClientID = x509TrustAnchorsByClientID
    }

    public func didDocument(for did: String) async throws -> DIDDocument? {
        didDocumentsByIdentifier[did]
    }

    public func verifierAttestationIssuerJWKSet(for issuer: String) async throws -> JOSEJWKSet? {
        verifierAttestationIssuerKeys[issuer]
    }

    public func x509TrustAnchors(for requestObject: OID4VPRequestObject) async throws -> [Data]? {
        x509TrustAnchorsByClientID[requestObject.clientID]
    }
}

public enum OID4VPSignedRequestTrustVerifier {
    public static func verify(
        _ signedRequest: OID4VPSignedRequestObject,
        provider: any OID4VPSignedRequestTrustMaterialProvider
    ) async throws -> OID4VPSignedRequestTrustVerificationResult {
        switch signedRequest.requestObject.resolvedClientIdentifierPrefix {
        case .decentralizedIdentifier:
            return try await verifyDecentralizedIdentifierRequest(signedRequest, provider: provider)
        case .verifierAttestation:
            return try await verifyVerifierAttestationRequest(signedRequest, provider: provider)
        case .x509Hash:
            return try await verifyX509BoundRequest(
                signedRequest,
                provider: provider,
                expectedDNSName: nil
            )
        case .x509SanDNS:
            return try await verifyX509BoundRequest(
                signedRequest,
                provider: provider,
                expectedDNSName: signedRequest.requestObject.clientIdentifierValue
            )
        case .redirectURI, .preRegistered, .openidFederation, .other:
            throw OID4VPSignedRequestTrustVerificationError.unsupportedTrustMechanism(
                prefix: signedRequest.requestObject.resolvedClientIdentifierPrefix.rawIdentifier
            )
        }
    }

    private static func verifyDecentralizedIdentifierRequest(
        _ signedRequest: OID4VPSignedRequestObject,
        provider: any OID4VPSignedRequestTrustMaterialProvider
    ) async throws -> OID4VPSignedRequestTrustVerificationResult {
        let did = signedRequest.requestObject.clientIdentifierValue
        guard let didDocument = try await provider.didDocument(for: did) else {
            throw OID4VPSignedRequestTrustVerificationError.missingDIDDocument(did)
        }

        let keyID = signedRequest.header.keyID ?? ""
        try DIDIssuerBindingValidator.validateKeyID(
            keyID,
            issuerIdentifier: did,
            didDocument: didDocument,
            requiredUse: .verification
        )

        guard let verificationMethod = didDocument.verificationMethodsDict[keyID] else {
            throw OID4VPSignedRequestTrustVerificationError.requestSignatureInvalid
        }

        guard try verifyRequestSignature(
            signedRequest,
            with: verificationMethod
        ) else {
            throw OID4VPSignedRequestTrustVerificationError.requestSignatureInvalid
        }

        return OID4VPSignedRequestTrustVerificationResult(
            source: .decentralizedIdentifier(did: did, keyID: keyID),
            requestSignatureVerified: true,
            verifierAttestationSignatureVerified: false
        )
    }

    private static func verifyVerifierAttestationRequest(
        _ signedRequest: OID4VPSignedRequestObject,
        provider: any OID4VPSignedRequestTrustMaterialProvider
    ) async throws -> OID4VPSignedRequestTrustVerificationResult {
        guard let verifierAttestation = signedRequest.verifierAttestation else {
            throw OID4VPSignedRequestTrustVerificationError.verifierAttestationSignatureInvalid
        }

        guard let issuerJWKSet = try await provider.verifierAttestationIssuerJWKSet(
            for: verifierAttestation.claims.issuer
        ) else {
            throw OID4VPSignedRequestTrustVerificationError.missingTrustedAttestationIssuer(
                verifierAttestation.claims.issuer
            )
        }

        guard try verifyJWS(
            verifierAttestation.jws,
            algorithm: verifierAttestation.header.algorithm,
            keyID: verifierAttestation.header.keyID,
            jwkSet: issuerJWKSet
        ) else {
            throw OID4VPSignedRequestTrustVerificationError.verifierAttestationSignatureInvalid
        }

        if let redirectURIs = verifierAttestation.claims.redirectURIs,
           let redirectURI = signedRequest.requestObject.redirectURI?.absoluteString,
           !redirectURIs.contains(redirectURI) {
            throw OID4VPSignedRequestTrustVerificationError.redirectURINotAllowed(redirectURI)
        }

        guard try JOSEJWSVerifier.verify(
            jws: signedRequest.jws,
            algorithm: signedRequest.header.algorithm,
            using: verifierAttestation.claims.confirmation.jwk
        ) else {
            throw OID4VPSignedRequestTrustVerificationError.requestSignatureInvalid
        }

        return OID4VPSignedRequestTrustVerificationResult(
            source: .verifierAttestation(
                issuer: verifierAttestation.claims.issuer,
                subject: verifierAttestation.claims.subject
            ),
            requestSignatureVerified: true,
            verifierAttestationSignatureVerified: true
        )
    }

    private static func verifyX509BoundRequest(
        _ signedRequest: OID4VPSignedRequestObject,
        provider: any OID4VPSignedRequestTrustMaterialProvider,
        expectedDNSName: String?
    ) async throws -> OID4VPSignedRequestTrustVerificationResult {
        #if canImport(Security)
        guard let x5c = signedRequest.header.certificateChain,
              let leafCertificateData = Data(base64Encoded: x5c[0]) else {
            throw OID4VPSignedRequestTrustVerificationError.invalidX509CertificateChain
        }

        if signedRequest.requestObject.resolvedClientIdentifierPrefix == .x509Hash {
            let actualHash = JOSEBase64URL.encode(Data(SHA256.hash(data: leafCertificateData)))
            let expectedHash = signedRequest.requestObject.clientIdentifierValue
            guard actualHash == expectedHash else {
                throw OID4VPSignedRequestTrustVerificationError.x509LeafCertificateHashMismatch(
                    expected: expectedHash,
                    actual: actualHash
                )
            }
        }

        guard let anchorData = try await provider.x509TrustAnchors(for: signedRequest.requestObject),
              !anchorData.isEmpty else {
            throw OID4VPSignedRequestTrustVerificationError.missingX509TrustAnchors(
                signedRequest.requestObject.clientID
            )
        }

        try validateX509Trust(
            certificateChain: x5c,
            anchorData: anchorData,
            expectedDNSName: expectedDNSName
        )

        guard try JOSEJWSVerifier.verify(
            jws: signedRequest.jws,
            algorithm: signedRequest.header.algorithm,
            certificateData: leafCertificateData
        ) else {
            throw OID4VPSignedRequestTrustVerificationError.requestSignatureInvalid
        }

        let source: OID4VPSignedRequestTrustSource
        if let expectedDNSName {
            source = .x509SanDNS(dnsName: expectedDNSName)
        } else {
            source = .x509Hash(hash: signedRequest.requestObject.clientIdentifierValue)
        }

        return OID4VPSignedRequestTrustVerificationResult(
            source: source,
            requestSignatureVerified: true,
            verifierAttestationSignatureVerified: false
        )
        #else
        throw OID4VPSignedRequestTrustVerificationError.unsupportedTrustMechanism(
            prefix: signedRequest.requestObject.resolvedClientIdentifierPrefix.rawIdentifier
        )
        #endif
    }

    private static func verifyRequestSignature(
        _ signedRequest: OID4VPSignedRequestObject,
        with verificationMethod: DIDVerificationMethod
    ) throws -> Bool {
        switch verificationMethod.publicKeyType {
        case .publicKeyMultibase(let multibase):
            let decoded = try DIDKeyParser.decodeMultikey(multibase)
            return try JOSEJWSVerifier.verify(
                jws: signedRequest.jws,
                algorithm: signedRequest.header.algorithm,
                publicKey: decoded.publicKey,
                curveType: decoded.curveType
            )
        case .publicKeyJwk(let publicKeyJwk):
            return try JOSEJWSVerifier.verify(
                jws: signedRequest.jws,
                algorithm: signedRequest.header.algorithm,
                using: JOSEJWK(
                    keyType: publicKeyJwk.kty,
                    keyID: publicKeyJwk.kid,
                    algorithm: publicKeyJwk.alg?.rawValue,
                    curve: publicKeyJwk.crv.rawValue,
                    x: publicKeyJwk.x
                )
            )
        case .publicBase58:
            return false
        }
    }

    private static func verifyJWS(
        _ jws: JOSECompactJWS,
        algorithm: String,
        keyID: String?,
        jwkSet: JOSEJWKSet
    ) throws -> Bool {
        let candidateKeys: [JOSEJWK]
        if let keyID {
            candidateKeys = jwkSet.keys.filter { $0.keyID == keyID }
        } else {
            candidateKeys = jwkSet.keys
        }

        for key in candidateKeys {
            if (try? JOSEJWSVerifier.verify(jws: jws, algorithm: algorithm, using: key)) == true {
                return true
            }
        }
        return false
    }

    #if canImport(Security)
    private static func validateX509Trust(
        certificateChain: [String],
        anchorData: [Data],
        expectedDNSName: String?
    ) throws {
        let certificates = certificateChain.compactMap { encoded -> SecCertificate? in
            guard let data = Data(base64Encoded: encoded) else {
                return nil
            }
            return SecCertificateCreateWithData(nil, data as CFData)
        }
        let anchors = anchorData.compactMap { data in
            SecCertificateCreateWithData(nil, data as CFData)
        }

        guard certificates.count == certificateChain.count,
              !certificates.isEmpty,
              anchors.count == anchorData.count,
              !anchors.isEmpty else {
            throw OID4VPSignedRequestTrustVerificationError.invalidX509CertificateChain
        }

        if let expectedDNSName {
            let sslPolicy = SecPolicyCreateSSL(false, expectedDNSName as CFString)
            if try evaluateX509Trust(certificates: certificates, anchors: anchors, policy: sslPolicy) {
                return
            }

            let basicPolicy = SecPolicyCreateBasicX509()
            if try evaluateX509Trust(certificates: certificates, anchors: anchors, policy: basicPolicy) {
                throw OID4VPSignedRequestTrustVerificationError.x509DNSNameMismatch(
                    expected: expectedDNSName
                )
            }

            throw OID4VPSignedRequestTrustVerificationError.invalidX509CertificateChain
        }

        let basicPolicy = SecPolicyCreateBasicX509()
        guard try evaluateX509Trust(certificates: certificates, anchors: anchors, policy: basicPolicy) else {
            throw OID4VPSignedRequestTrustVerificationError.invalidX509CertificateChain
        }
    }

    private static func evaluateX509Trust(
        certificates: [SecCertificate],
        anchors: [SecCertificate],
        policy: SecPolicy
    ) throws -> Bool {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificates as CFTypeRef, policy, &trust)
        guard status == errSecSuccess, let trust else {
            throw OID4VPSignedRequestTrustVerificationError.invalidX509CertificateChain
        }

        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
    #endif
}
