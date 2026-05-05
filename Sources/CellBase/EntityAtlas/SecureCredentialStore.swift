// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public protocol SecureCredentialStore {
    func store(secret: Data, handleID: String) async throws
    func loadSecret(handleID: String) async throws -> Data?
    func deleteSecret(handleID: String) async throws
}

public actor InMemorySecureCredentialStore: SecureCredentialStore {
    private var secretsByHandleID: [String: Data] = [:]

    public init() {}

    public func store(secret: Data, handleID: String) async throws {
        secretsByHandleID[handleID] = secret
    }

    public func loadSecret(handleID: String) async throws -> Data? {
        secretsByHandleID[handleID]
    }

    public func deleteSecret(handleID: String) async throws {
        secretsByHandleID[handleID] = nil
    }
}

public enum CredentialVaultServiceError: Error {
    case metadataNotFound(String)
}

public struct CredentialVaultService {
    private let repository: AtlasVaultDocumentRepository
    private let secureStore: SecureCredentialStore

    public init(
        repository: AtlasVaultDocumentRepository = AtlasVaultDocumentRepository(),
        secureStore: SecureCredentialStore
    ) {
        self.repository = repository
        self.secureStore = secureStore
    }

    public func createHandle(
        _ handle: AtlasCredentialHandleRecord,
        secret: Data,
        in vault: VaultCell,
        requester: Identity
    ) async throws {
        try await secureStore.store(secret: secret, handleID: handle.id)
        try await repository.upsert(handle, in: vault, requester: requester)
    }

    public func rotateHandle(
        handleID: String,
        newSecret: Data,
        in vault: VaultCell,
        requester: Identity,
        rotatedAtEpochMs: Int
    ) async throws -> AtlasCredentialHandleRecord {
        guard var handle = try await repository.fetch(AtlasCredentialHandleRecord.self, id: handleID, from: vault, requester: requester) else {
            throw CredentialVaultServiceError.metadataNotFound(handleID)
        }
        handle.lastRotatedAtEpochMs = rotatedAtEpochMs
        handle.updatedAtEpochMs = max(rotatedAtEpochMs, handle.updatedAtEpochMs + 1)
        try await secureStore.store(secret: newSecret, handleID: handleID)
        try await repository.upsert(handle, in: vault, requester: requester)
        return handle
    }

    public func revokeHandle(
        handleID: String,
        in vault: VaultCell,
        requester: Identity,
        revokedAtEpochMs: Int
    ) async throws -> AtlasCredentialHandleRecord {
        guard var handle = try await repository.fetch(AtlasCredentialHandleRecord.self, id: handleID, from: vault, requester: requester) else {
            throw CredentialVaultServiceError.metadataNotFound(handleID)
        }
        handle.revokedAtEpochMs = revokedAtEpochMs
        handle.updatedAtEpochMs = max(revokedAtEpochMs, handle.updatedAtEpochMs + 1)
        try await secureStore.deleteSecret(handleID: handleID)
        try await repository.upsert(handle, in: vault, requester: requester)
        return handle
    }

    public func secret(for handleID: String) async throws -> Data? {
        try await secureStore.loadSecret(handleID: handleID)
    }
}
