// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class OID4VCIIssuerMetadataTests: XCTestCase {
    func testMetadataURLForRootIssuerIdentifierUsesWellKnownPath() throws {
        let url = try OID4VCIIssuerMetadata.metadataURL(for: "https://issuer.example.com")
        XCTAssertEqual(url.absoluteString, "https://issuer.example.com/.well-known/openid-credential-issuer")
    }

    func testMetadataURLForTenantIssuerIdentifierInsertsWellKnownBeforeTenantPath() throws {
        let url = try OID4VCIIssuerMetadata.metadataURL(for: "https://issuer.example.com/tenant-a")
        XCTAssertEqual(url.absoluteString, "https://issuer.example.com/.well-known/openid-credential-issuer/tenant-a")
    }

    func testDecodesJwtVcIssuerMetadataAndRecognizesKnownFormats() throws {
        let json = """
        {
          "credential_issuer": "https://issuer.example.com",
          "credential_endpoint": "https://issuer.example.com/credential",
          "credential_configurations_supported": {
            "UniversityDegreeCredential": {
              "format": "jwt_vc_json",
              "scope": "UniversityDegreeCredential",
              "cryptographic_binding_methods_supported": ["did", "jwk"],
              "credential_signing_alg_values_supported": ["ES256"],
              "proof_types_supported": {
                "jwt": {
                  "proof_signing_alg_values_supported": ["ES256"]
                }
              },
              "credential_definition": {
                "@context": ["https://www.w3.org/ns/credentials/v2"],
                "type": ["VerifiableCredential", "UniversityDegreeCredential"]
              },
              "credential_metadata": {
                "display": [
                  {
                    "name": "University Credential",
                    "locale": "en-US"
                  }
                ],
                "claims": [
                  {
                    "path": ["credentialSubject", "given_name"],
                    "display": [
                      {
                        "name": "Given Name",
                        "locale": "en-US"
                      }
                    ]
                  }
                ]
              }
            }
          }
        }
        """

        let metadata = try JSONDecoder().decode(OID4VCIIssuerMetadata.self, from: Data(json.utf8))

        XCTAssertEqual(metadata.credentialIssuer, "https://issuer.example.com")
        XCTAssertEqual(metadata.resolvedAuthorizationServerIdentifiers, ["https://issuer.example.com"])
        XCTAssertEqual(metadata.supportedFormats, [.jwtVcJson])

        let configuration = try XCTUnwrap(metadata.configuration(id: "UniversityDegreeCredential"))
        XCTAssertEqual(configuration.format, .jwtVcJson)
        XCTAssertEqual(configuration.credentialDefinition?.contexts, ["https://www.w3.org/ns/credentials/v2"])
        XCTAssertEqual(configuration.credentialDefinition?.type, ["VerifiableCredential", "UniversityDegreeCredential"])
        XCTAssertEqual(configuration.proofTypesSupported?["jwt"]?.proofSigningAlgValuesSupported, ["ES256"])

        XCTAssertNoThrow(try metadata.validatedAgainst(metadataURL: URL(string: "https://issuer.example.com/.well-known/openid-credential-issuer")!))
    }

    func testDecodesSdJwtMetadataWithKeyAttestations() throws {
        let json = """
        {
          "credential_issuer": "https://issuer.example.com/tenant",
          "authorization_servers": ["https://auth.example.com"],
          "credential_endpoint": "https://issuer.example.com/tenant/credential",
          "nonce_endpoint": "https://issuer.example.com/tenant/nonce",
          "credential_configurations_supported": {
            "SD_JWT_VC_example_in_OpenID4VCI": {
              "format": "dc+sd-jwt",
              "scope": "SD_JWT_VC_example_in_OpenID4VCI",
              "cryptographic_binding_methods_supported": ["jwk"],
              "credential_signing_alg_values_supported": ["ES256"],
              "proof_types_supported": {
                "jwt": {
                  "proof_signing_alg_values_supported": ["ES256"],
                  "key_attestations_required": {
                    "key_storage": ["iso_18045_moderate"],
                    "user_authentication": ["iso_18045_moderate"]
                  }
                }
              },
              "vct": "https://credentials.example.com/identity_credential"
            }
          }
        }
        """

        let metadata = try JSONDecoder().decode(OID4VCIIssuerMetadata.self, from: Data(json.utf8))

        XCTAssertEqual(metadata.supportedFormats, [.sdJwtVc])
        XCTAssertEqual(metadata.resolvedAuthorizationServerIdentifiers, ["https://auth.example.com"])

        let configuration = try XCTUnwrap(metadata.configuration(id: "SD_JWT_VC_example_in_OpenID4VCI"))
        XCTAssertEqual(configuration.format, .sdJwtVc)
        XCTAssertEqual(configuration.vct, "https://credentials.example.com/identity_credential")
        XCTAssertEqual(configuration.proofTypesSupported?["jwt"]?.keyAttestationsRequired?.keyStorage, ["iso_18045_moderate"])

        XCTAssertNoThrow(try metadata.validatedAgainst(metadataURL: URL(string: "https://issuer.example.com/.well-known/openid-credential-issuer/tenant")!))
    }

    func testDecodesMdocConfigurationWithIntegerAlgorithms() throws {
        let json = """
        {
          "credential_issuer": "https://issuer.example.com",
          "credential_endpoint": "https://issuer.example.com/credential",
          "credential_configurations_supported": {
            "org.iso.18013.5.1.mDL": {
              "format": "mso_mdoc",
              "doctype": "org.iso.18013.5.1.mDL",
              "credential_signing_alg_values_supported": [-7]
            }
          }
        }
        """

        let metadata = try JSONDecoder().decode(OID4VCIIssuerMetadata.self, from: Data(json.utf8))
        let configuration = try XCTUnwrap(metadata.configuration(id: "org.iso.18013.5.1.mDL"))

        XCTAssertEqual(configuration.format, .isoMdoc)
        XCTAssertEqual(configuration.doctype, "org.iso.18013.5.1.mDL")
        XCTAssertEqual(configuration.credentialSigningAlgValuesSupported, [.integer(-7)])
    }

    func testRejectsNonHttpsCredentialIssuerIdentifiers() throws {
        let json = """
        {
          "credential_issuer": "http://issuer.example.com",
          "credential_endpoint": "https://issuer.example.com/credential",
          "credential_configurations_supported": {}
        }
        """

        let metadata = try JSONDecoder().decode(OID4VCIIssuerMetadata.self, from: Data(json.utf8))
        XCTAssertThrowsError(try metadata.validateIssuerIdentifier())
    }
}
