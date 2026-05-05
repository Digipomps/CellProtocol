// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct OID4VPStaticVerifierMetadataRecord: Equatable, Sendable {
    public var clientIDs: [String]
    public var metadata: OID4VPVerifierMetadata
    public var source: OID4VPResolvedVerifierMetadataSource

    public init(
        clientIDs: [String],
        metadata: OID4VPVerifierMetadata,
        source: OID4VPResolvedVerifierMetadataSource = .preRegistered
    ) {
        self.clientIDs = clientIDs
        self.metadata = metadata
        self.source = source
    }
}

public struct OID4VPStaticVerifierMetadataProvider: OID4VPVerifierMetadataProvider {
    private let recordsByClientID: [String: OID4VPStaticVerifierMetadataRecord]

    public init(records: [OID4VPStaticVerifierMetadataRecord]) {
        var recordsByClientID: [String: OID4VPStaticVerifierMetadataRecord] = [:]
        for record in records {
            for clientID in record.clientIDs where !clientID.isEmpty {
                recordsByClientID[clientID] = record
            }
        }
        self.recordsByClientID = recordsByClientID
    }

    public func metadata(for requestObject: OID4VPRequestObject) async throws -> OID4VPResolvedVerifierMetadata? {
        guard let record = recordsByClientID[requestObject.clientID] else {
            return nil
        }
        try record.metadata.validate()
        return OID4VPResolvedVerifierMetadata(
            metadata: record.metadata,
            source: record.source,
            clientIdentifierPrefix: requestObject.resolvedClientIdentifierPrefix
        )
    }
}

public struct OID4VPCompositeVerifierMetadataProvider: OID4VPVerifierMetadataProvider {
    public var providers: [any OID4VPVerifierMetadataProvider]

    public init(providers: [any OID4VPVerifierMetadataProvider]) {
        self.providers = providers
    }

    public func metadata(for requestObject: OID4VPRequestObject) async throws -> OID4VPResolvedVerifierMetadata? {
        for provider in providers {
            if let metadata = try await provider.metadata(for: requestObject) {
                return metadata
            }
        }
        return nil
    }
}
