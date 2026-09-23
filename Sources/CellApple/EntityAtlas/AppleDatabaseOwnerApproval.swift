// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import CellBase

/// Public metadata only. An existing handle is always opened with its pinned recipient; never recreated.
public struct AppleDatabaseSecretHandle: Codable, Sendable, Identifiable {
    public let id: String
    public let recipient: SecretRecipient
    public init(id: String, recipient: SecretRecipient) { self.id = id; self.recipient = recipient }
    public static func create() async throws -> Self {
        let id = UUID().uuidString.lowercased()
        let provider = try await AppleDatabaseSecretUnwrapper.create(handleID: id)
        return try await Self(id: id, recipient: provider.recipient())
    }
    public func provider() throws -> AppleDatabaseSecretUnwrapper { try .init(handleID: id, recipient: recipient) }
}

/// Last accepted owner-signed version is kept locally across restart, separately from the blind server.
/// Initial enrollment still requires the owner to trust the supplied current version/reference.
public actor AppleDatabaseOwnerApproval {
    private var approving = false
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func approve(_ package: DatabaseOwnerApprovalPackage, owner: Identity,
                        handle: AppleDatabaseSecretHandle) async throws -> DatabaseServiceGrant {
        guard !approving else { throw SecretCredentialError.locked }
        approving = true; defer { approving = false }
        try package.validate(owner: owner)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(package.record.context.secretID + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            let previous = try JSONDecoder().decode(SealedDatabaseSecret.self, from: Data(contentsOf: file))
            try previous.validate(owner: owner)
            guard previous.context.cellUUID == package.record.context.cellUUID,
                  previous.context.domain == package.record.context.domain,
                  previous.context.audience == package.record.context.audience,
                  package.record.context.revision >= previous.context.revision,
                  package.record.context.keyVersion >= previous.context.keyVersion,
                  package.record.context.policyVersion >= previous.context.policyVersion else { throw SecretCredentialError.staleVersion }
            if previous.context.revision == package.record.context.revision {
                guard try previous.digest() == package.record.digest() else { throw SecretCredentialError.staleVersion }
            }
        }
        let grant = try await DatabaseServiceGrant.approve(package.request, record: package.record, owner: owner,
            unwrapper: handle.provider(), transport: HTTPSSecretCredentialTransport(endpoint: package.secretEndpoint))
        try Task.checkCancellation()
        try JSONEncoder().encode(package.record).write(to: file, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return grant
    }
}
