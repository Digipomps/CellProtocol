// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum AtlasVaultDocumentKind: String, Codable, CaseIterable {
    case prompt
    case context
    case assistantProfile
    case modelProviderProfile
    case credentialHandle

    public var tag: String {
        "atlas.kind.\(rawValue)"
    }

    public var nodePrefix: String {
        "atlas.\(rawValue)"
    }
}

public enum AtlasDocumentScopeKind: String, Codable {
    case entity
    case assistant
    case purpose
    case cell
    case session
}

public struct AtlasDocumentScope: Codable, Equatable {
    public var kind: AtlasDocumentScopeKind
    public var reference: String?

    public init(kind: AtlasDocumentScopeKind, reference: String? = nil) {
        self.kind = kind
        self.reference = reference
    }

    public func matches(kind otherKind: AtlasDocumentScopeKind, reference otherReference: String?) -> Bool {
        guard kind == otherKind else { return false }
        switch (reference?.trimmingCharacters(in: .whitespacesAndNewlines), otherReference?.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs == rhs
        default:
            return false
        }
    }

    public var tag: String {
        switch kind {
        case .entity:
            return "atlas.scope.entity"
        case .assistant:
            return "atlas.scope.assistant"
        case .purpose:
            return "atlas.scope.purpose"
        case .cell:
            return "atlas.scope.cell"
        case .session:
            return "atlas.scope.session"
        }
    }
}

public struct AtlasVaultDerivedLink: Codable, Equatable {
    public var fromDocumentID: String
    public var toDocumentID: String
    public var relationship: String

    public init(fromDocumentID: String, toDocumentID: String, relationship: String) {
        self.fromDocumentID = fromDocumentID
        self.toDocumentID = toDocumentID
        self.relationship = relationship
    }
}

public protocol AtlasVaultDocumentConvertible: Codable, Equatable {
    static var atlasKind: AtlasVaultDocumentKind { get }
    var id: String { get }
    var title: String { get }
    var scope: AtlasDocumentScope { get }
    var tags: [String] { get }
    var createdAtEpochMs: Int { get }
    var updatedAtEpochMs: Int { get }
    func derivedLinks() -> [AtlasVaultDerivedLink]
}

public extension AtlasVaultDocumentConvertible {
    var nodeID: String {
        "\(Self.atlasKind.nodePrefix):\(id)"
    }

    var noteTags: [String] {
        Array(Set(["atlas.document", Self.atlasKind.tag, scope.tag] + tags)).sorted()
    }

    func derivedLinks() -> [AtlasVaultDerivedLink] {
        []
    }
}

public enum AtlasCredentialAccessMode: String, Codable {
    case apiKey
    case token
    case localModel
    case other
}

public struct AtlasPromptDocument: Codable, Equatable, AtlasVaultDocumentConvertible {
    public static let atlasKind: AtlasVaultDocumentKind = .prompt

    public var id: String
    public var title: String
    public var scope: AtlasDocumentScope
    public var body: String
    public var revision: Int
    public var tags: [String]
    public var createdAtEpochMs: Int
    public var updatedAtEpochMs: Int

    public init(
        id: String,
        title: String,
        scope: AtlasDocumentScope,
        body: String,
        revision: Int = 1,
        tags: [String] = [],
        createdAtEpochMs: Int,
        updatedAtEpochMs: Int
    ) {
        self.id = id
        self.title = title
        self.scope = scope
        self.body = body
        self.revision = revision
        self.tags = tags
        self.createdAtEpochMs = createdAtEpochMs
        self.updatedAtEpochMs = updatedAtEpochMs
    }
}

public struct AtlasContextDocument: Codable, Equatable, AtlasVaultDocumentConvertible {
    public static let atlasKind: AtlasVaultDocumentKind = .context

    public var id: String
    public var title: String
    public var scope: AtlasDocumentScope
    public var body: String
    public var blockIDs: [String]
    public var tags: [String]
    public var createdAtEpochMs: Int
    public var updatedAtEpochMs: Int

    public init(
        id: String,
        title: String,
        scope: AtlasDocumentScope,
        body: String,
        blockIDs: [String] = [],
        tags: [String] = [],
        createdAtEpochMs: Int,
        updatedAtEpochMs: Int
    ) {
        self.id = id
        self.title = title
        self.scope = scope
        self.body = body
        self.blockIDs = blockIDs.sorted()
        self.tags = tags
        self.createdAtEpochMs = createdAtEpochMs
        self.updatedAtEpochMs = updatedAtEpochMs
    }
}

public struct AtlasModelProviderProfile: Codable, Equatable, AtlasVaultDocumentConvertible {
    public static let atlasKind: AtlasVaultDocumentKind = .modelProviderProfile

    public var id: String
    public var title: String
    public var scope: AtlasDocumentScope
    public var providerID: String
    public var accessMode: AtlasCredentialAccessMode
    public var allowedModels: [String]
    public var costPreference: String?
    public var latencyPreference: String?
    public var privacyPreference: String?
    public var credentialHandleRefs: [String]
    public var usageConstraints: [String]
    public var assistantCompatibility: [String]
    public var tags: [String]
    public var createdAtEpochMs: Int
    public var updatedAtEpochMs: Int

    public init(
        id: String,
        title: String,
        scope: AtlasDocumentScope = AtlasDocumentScope(kind: .entity),
        providerID: String,
        accessMode: AtlasCredentialAccessMode,
        allowedModels: [String] = [],
        costPreference: String? = nil,
        latencyPreference: String? = nil,
        privacyPreference: String? = nil,
        credentialHandleRefs: [String] = [],
        usageConstraints: [String] = [],
        assistantCompatibility: [String] = [],
        tags: [String] = [],
        createdAtEpochMs: Int,
        updatedAtEpochMs: Int
    ) {
        self.id = id
        self.title = title
        self.scope = scope
        self.providerID = providerID
        self.accessMode = accessMode
        self.allowedModels = allowedModels.sorted()
        self.costPreference = costPreference
        self.latencyPreference = latencyPreference
        self.privacyPreference = privacyPreference
        self.credentialHandleRefs = credentialHandleRefs.sorted()
        self.usageConstraints = usageConstraints.sorted()
        self.assistantCompatibility = assistantCompatibility.sorted()
        self.tags = tags
        self.createdAtEpochMs = createdAtEpochMs
        self.updatedAtEpochMs = updatedAtEpochMs
    }

    public func derivedLinks() -> [AtlasVaultDerivedLink] {
        credentialHandleRefs.map { handleID in
            AtlasVaultDerivedLink(fromDocumentID: id, toDocumentID: handleID, relationship: "usesCredentialHandle")
        }
    }
}

public struct AtlasAssistantProfile: Codable, Equatable, AtlasVaultDocumentConvertible {
    public static let atlasKind: AtlasVaultDocumentKind = .assistantProfile

    public var id: String
    public var title: String
    public var scope: AtlasDocumentScope
    public var providerProfileRef: String?
    public var promptRefs: [String]
    public var contextRefs: [String]
    public var executionPolicy: String?
    public var tags: [String]
    public var createdAtEpochMs: Int
    public var updatedAtEpochMs: Int

    public init(
        id: String,
        title: String,
        scope: AtlasDocumentScope = AtlasDocumentScope(kind: .assistant),
        providerProfileRef: String? = nil,
        promptRefs: [String] = [],
        contextRefs: [String] = [],
        executionPolicy: String? = nil,
        tags: [String] = [],
        createdAtEpochMs: Int,
        updatedAtEpochMs: Int
    ) {
        self.id = id
        self.title = title
        self.scope = scope
        self.providerProfileRef = providerProfileRef
        self.promptRefs = promptRefs
        self.contextRefs = contextRefs
        self.executionPolicy = executionPolicy
        self.tags = tags
        self.createdAtEpochMs = createdAtEpochMs
        self.updatedAtEpochMs = updatedAtEpochMs
    }

    public func derivedLinks() -> [AtlasVaultDerivedLink] {
        var links = [AtlasVaultDerivedLink]()
        if let providerProfileRef, !providerProfileRef.isEmpty {
            links.append(AtlasVaultDerivedLink(fromDocumentID: id, toDocumentID: providerProfileRef, relationship: "usesProviderProfile"))
        }
        links.append(contentsOf: promptRefs.map { AtlasVaultDerivedLink(fromDocumentID: id, toDocumentID: $0, relationship: "usesPromptDocument") })
        links.append(contentsOf: contextRefs.map { AtlasVaultDerivedLink(fromDocumentID: id, toDocumentID: $0, relationship: "usesContextDocument") })
        return links
    }
}

public struct AtlasCredentialHandleRecord: Codable, Equatable, AtlasVaultDocumentConvertible {
    public static let atlasKind: AtlasVaultDocumentKind = .credentialHandle

    public var id: String
    public var title: String
    public var scope: AtlasDocumentScope
    public var providerID: String
    public var credentialClass: String
    public var accessMode: AtlasCredentialAccessMode
    public var label: String
    public var revokedAtEpochMs: Int?
    public var lastRotatedAtEpochMs: Int?
    public var metadata: [String: String]
    public var tags: [String]
    public var createdAtEpochMs: Int
    public var updatedAtEpochMs: Int

    public init(
        id: String,
        title: String,
        scope: AtlasDocumentScope = AtlasDocumentScope(kind: .entity),
        providerID: String,
        credentialClass: String,
        accessMode: AtlasCredentialAccessMode,
        label: String,
        revokedAtEpochMs: Int? = nil,
        lastRotatedAtEpochMs: Int? = nil,
        metadata: [String: String] = [:],
        tags: [String] = [],
        createdAtEpochMs: Int,
        updatedAtEpochMs: Int
    ) {
        self.id = id
        self.title = title
        self.scope = scope
        self.providerID = providerID
        self.credentialClass = credentialClass
        self.accessMode = accessMode
        self.label = label
        self.revokedAtEpochMs = revokedAtEpochMs
        self.lastRotatedAtEpochMs = lastRotatedAtEpochMs
        self.metadata = metadata
        self.tags = tags
        self.createdAtEpochMs = createdAtEpochMs
        self.updatedAtEpochMs = updatedAtEpochMs
    }
}

public struct AtlasVaultDocumentSnapshot: Codable, Equatable {
    public var promptDocuments: [AtlasPromptDocument]
    public var contextDocuments: [AtlasContextDocument]
    public var assistantProfiles: [AtlasAssistantProfile]
    public var providerProfiles: [AtlasModelProviderProfile]
    public var credentialHandles: [AtlasCredentialHandleRecord]

    public init(
        promptDocuments: [AtlasPromptDocument] = [],
        contextDocuments: [AtlasContextDocument] = [],
        assistantProfiles: [AtlasAssistantProfile] = [],
        providerProfiles: [AtlasModelProviderProfile] = [],
        credentialHandles: [AtlasCredentialHandleRecord] = []
    ) {
        self.promptDocuments = promptDocuments.sorted { $0.id < $1.id }
        self.contextDocuments = contextDocuments.sorted { $0.id < $1.id }
        self.assistantProfiles = assistantProfiles.sorted { $0.id < $1.id }
        self.providerProfiles = providerProfiles.sorted { $0.id < $1.id }
        self.credentialHandles = credentialHandles.sorted { $0.id < $1.id }
    }
}

public struct AtlasDocumentSyncReport: Codable, Equatable {
    public var inserted: Int
    public var updated: Int
    public var skipped: Int
    public var derivedLinksWritten: Int

    public init(inserted: Int = 0, updated: Int = 0, skipped: Int = 0, derivedLinksWritten: Int = 0) {
        self.inserted = inserted
        self.updated = updated
        self.skipped = skipped
        self.derivedLinksWritten = derivedLinksWritten
    }
}

public struct AtlasVaultDocumentRepository {
    private struct VaultSuccessEnvelope<T: Decodable>: Decodable {
        var status: String
        var operation: String
        var result: T
    }

    private struct VaultListResult: Codable, Equatable {
        var items: [VaultNoteRecord]
        var count: Int
        var total: Int
        var offset: Int
        var limit: Int
    }

    public init() {}

    public func upsert<T: AtlasVaultDocumentConvertible>(_ document: T, in vault: VaultCell, requester: Identity) async throws {
        let note = try noteRecord(from: document)
        if let existing = try await rawNote(id: document.id, from: vault, requester: requester) {
            let updated = VaultNoteRecord(
                id: note.id,
                slug: existing.slug ?? note.slug,
                title: note.title,
                content: note.content,
                tags: note.tags,
                createdAtEpochMs: existing.createdAtEpochMs,
                updatedAtEpochMs: max(note.updatedAtEpochMs, existing.updatedAtEpochMs + 1)
            )
            _ = try await vault.set(keypath: "vault.note.update", value: try VaultCellCodec.encode(updated), requester: requester)
        } else {
            _ = try await vault.set(keypath: "vault.note.create", value: try VaultCellCodec.encode(note), requester: requester)
        }

        try await writeDerivedLinks(for: document, into: vault, requester: requester)
    }

    public func fetch<T: AtlasVaultDocumentConvertible>(_ type: T.Type, id: String, from vault: VaultCell, requester: Identity) async throws -> T? {
        guard let note = try await rawNote(id: id, from: vault, requester: requester) else {
            return nil
        }
        return try decode(documentType: type, from: note)
    }

    public func list<T: AtlasVaultDocumentConvertible>(
        _ type: T.Type,
        from vault: VaultCell,
        requester: Identity,
        scope: AtlasDocumentScope? = nil
    ) async throws -> [T] {
        let notes = try await rawNotes(tag: T.atlasKind.tag, from: vault, requester: requester)
        let documents = try notes.compactMap { note -> T? in
            guard note.tags.contains(T.atlasKind.tag) else { return nil }
            return try decode(documentType: type, from: note)
        }
        guard let scope else {
            return documents.sorted { $0.id < $1.id }
        }
        return documents
            .filter { $0.scope == scope }
            .sorted { $0.id < $1.id }
    }

    public func loadAll(from vault: VaultCell, requester: Identity) async throws -> AtlasVaultDocumentSnapshot {
        let notes = try await rawNotes(tag: "atlas.document", from: vault, requester: requester)
        var prompts = [AtlasPromptDocument]()
        var contexts = [AtlasContextDocument]()
        var assistants = [AtlasAssistantProfile]()
        var providers = [AtlasModelProviderProfile]()
        var handles = [AtlasCredentialHandleRecord]()

        for note in notes {
            guard let kind = kind(from: note.tags) else { continue }
            switch kind {
            case .prompt:
                prompts.append(try decode(documentType: AtlasPromptDocument.self, from: note))
            case .context:
                contexts.append(try decode(documentType: AtlasContextDocument.self, from: note))
            case .assistantProfile:
                assistants.append(try decode(documentType: AtlasAssistantProfile.self, from: note))
            case .modelProviderProfile:
                providers.append(try decode(documentType: AtlasModelProviderProfile.self, from: note))
            case .credentialHandle:
                handles.append(try decode(documentType: AtlasCredentialHandleRecord.self, from: note))
            }
        }

        return AtlasVaultDocumentSnapshot(
            promptDocuments: prompts,
            contextDocuments: contexts,
            assistantProfiles: assistants,
            providerProfiles: providers,
            credentialHandles: handles
        )
    }

    public func sync<T: AtlasVaultDocumentConvertible>(
        _ documents: [T],
        into vault: VaultCell,
        requester: Identity
    ) async throws -> AtlasDocumentSyncReport {
        var report = AtlasDocumentSyncReport()
        for document in documents.sorted(by: { $0.id < $1.id }) {
            if let existing: T = try await fetch(T.self, id: document.id, from: vault, requester: requester) {
                if existing.updatedAtEpochMs >= document.updatedAtEpochMs {
                    report.skipped += 1
                    continue
                }
                try await upsert(document, in: vault, requester: requester)
                report.updated += 1
            } else {
                try await upsert(document, in: vault, requester: requester)
                report.inserted += 1
            }
            report.derivedLinksWritten += document.derivedLinks().count
        }
        return report
    }

    private func noteRecord<T: AtlasVaultDocumentConvertible>(from document: T) throws -> VaultNoteRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let content = String(decoding: data, as: UTF8.self)
        return VaultNoteRecord(
            id: document.id,
            slug: nil,
            title: document.title,
            content: content,
            tags: document.noteTags,
            createdAtEpochMs: document.createdAtEpochMs,
            updatedAtEpochMs: document.updatedAtEpochMs
        )
    }

    private func decode<T: AtlasVaultDocumentConvertible>(documentType: T.Type, from note: VaultNoteRecord) throws -> T {
        let data = Data(note.content.utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func kind(from tags: [String]) -> AtlasVaultDocumentKind? {
        AtlasVaultDocumentKind.allCases.first { tags.contains($0.tag) }
    }

    private func rawNote(id: String, from vault: VaultCell, requester: Identity) async throws -> VaultNoteRecord? {
        let payload = try VaultCellCodec.encode(["id": id])
        guard let response = try await vault.set(keypath: "vault.note.get", value: payload, requester: requester) else {
            return nil
        }
        guard case let .object(object) = response,
              let status = VaultCellCodec.string(from: object["status"]),
              status == "ok",
              let envelope: VaultSuccessEnvelope<VaultNoteRecord> = try? VaultCellCodec.decode(response) else {
            return nil
        }
        return envelope.result
    }

    private func rawNotes(tag: String, from vault: VaultCell, requester: Identity) async throws -> [VaultNoteRecord] {
        let query = VaultQuery(tags: [tag], limit: 1000, offset: 0, sortBy: .id, descending: false)
        let payload = try VaultCellCodec.encode(query)
        guard let response = try await vault.set(keypath: "vault.note.list", value: payload, requester: requester) else {
            return []
        }
        guard let envelope: VaultSuccessEnvelope<VaultListResult> = try? VaultCellCodec.decode(response) else {
            return []
        }
        return envelope.result.items.sorted { $0.id < $1.id }
    }

    private func writeDerivedLinks<T: AtlasVaultDocumentConvertible>(for document: T, into vault: VaultCell, requester: Identity) async throws {
        for link in document.derivedLinks().sorted(by: { lhs, rhs in
            if lhs.relationship != rhs.relationship { return lhs.relationship < rhs.relationship }
            if lhs.fromDocumentID != rhs.fromDocumentID { return lhs.fromDocumentID < rhs.fromDocumentID }
            return lhs.toDocumentID < rhs.toDocumentID
        }) {
            let record = VaultLinkRecord(
                fromNoteID: link.fromDocumentID,
                toNoteID: link.toDocumentID,
                relationship: link.relationship,
                createdAtEpochMs: max(document.createdAtEpochMs, document.updatedAtEpochMs)
            )
            _ = try await vault.set(keypath: "vault.link.add", value: try VaultCellCodec.encode(record), requester: requester)
        }
    }
}
