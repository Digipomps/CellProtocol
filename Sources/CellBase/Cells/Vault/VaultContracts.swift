// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct VaultNoteRecord: Codable, Equatable {
    public var id: String
    public var slug: String?
    public var title: String
    public var content: String
    public var tags: [String]
    public var createdAtEpochMs: Int
    public var updatedAtEpochMs: Int

    public init(
        id: String,
        slug: String? = nil,
        title: String,
        content: String,
        tags: [String] = [],
        createdAtEpochMs: Int,
        updatedAtEpochMs: Int
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.content = content
        self.tags = tags
        self.createdAtEpochMs = createdAtEpochMs
        self.updatedAtEpochMs = updatedAtEpochMs
    }
}

public struct VaultLinkRecord: Codable, Equatable, Hashable {
    public var fromNoteID: String
    public var toNoteID: String
    public var relationship: String
    public var createdAtEpochMs: Int

    public init(fromNoteID: String, toNoteID: String, relationship: String = "wiki", createdAtEpochMs: Int) {
        self.fromNoteID = fromNoteID
        self.toNoteID = toNoteID
        self.relationship = relationship
        self.createdAtEpochMs = createdAtEpochMs
    }
}

public struct VaultStatePayload: Codable, Equatable {
    public static let currentSchemaVersion = "haven.vault.state.v1"

    public var status: String
    public var cell: String
    public var schemaVersion: String
    public var stateVersion: Int
    public var noteCount: Int
    public var linkCount: Int
    public var notes: [VaultNoteRecord]
    public var links: [VaultLinkRecord]
    public var operations: [String]
    public var updatedAtEpochMs: Int

    public init(
        status: String = "ok",
        cell: String = "VaultCell",
        schemaVersion: String = VaultStatePayload.currentSchemaVersion,
        stateVersion: Int,
        noteCount: Int,
        linkCount: Int,
        notes: [VaultNoteRecord],
        links: [VaultLinkRecord],
        operations: [String],
        updatedAtEpochMs: Int
    ) {
        self.status = status
        self.cell = cell
        self.schemaVersion = schemaVersion
        self.stateVersion = stateVersion
        self.noteCount = noteCount
        self.linkCount = linkCount
        self.notes = notes
        self.links = links
        self.operations = operations
        self.updatedAtEpochMs = updatedAtEpochMs
    }
}

public struct VaultMutationEvent: Codable {
    public static let currentSchemaVersion = "haven.vault.mutation.v1"

    public var schemaVersion: String
    public var stateVersion: Int
    public var operation: String
    public var recordKind: String
    public var recordID: String
    public var result: ValueType
    public var emittedAtEpochMs: Int

    public init(
        schemaVersion: String = VaultMutationEvent.currentSchemaVersion,
        stateVersion: Int,
        operation: String,
        recordKind: String,
        recordID: String,
        result: ValueType,
        emittedAtEpochMs: Int
    ) {
        self.schemaVersion = schemaVersion
        self.stateVersion = stateVersion
        self.operation = operation
        self.recordKind = recordKind
        self.recordID = recordID
        self.result = result
        self.emittedAtEpochMs = emittedAtEpochMs
    }
}

public enum VaultSortBy: String, Codable {
    case id
    case title
    case createdAt
    case updatedAt
}

public struct VaultQuery: Codable, Equatable {
    public var ids: [String]?
    public var text: String?
    public var tags: [String]?
    public var limit: Int?
    public var offset: Int?
    public var sortBy: VaultSortBy?
    public var descending: Bool?

    public init(
        ids: [String]? = nil,
        text: String? = nil,
        tags: [String]? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        sortBy: VaultSortBy? = nil,
        descending: Bool? = nil
    ) {
        self.ids = ids
        self.text = text
        self.tags = tags
        self.limit = limit
        self.offset = offset
        self.sortBy = sortBy
        self.descending = descending
    }
}

public struct VaultFieldError: Codable, Equatable {
    public var field: String
    public var code: String
    public var message: String

    public init(field: String, code: String, message: String) {
        self.field = field
        self.code = code
        self.message = message
    }
}

public struct VaultCellErrorPayload: Codable, Equatable {
    public var status: String
    public var operation: String
    public var code: String
    public var message: String
    public var fieldErrors: [VaultFieldError]

    enum CodingKeys: String, CodingKey {
        case status
        case operation
        case code
        case message
        case fieldErrors = "field_errors"
    }

    public init(
        status: String = "error",
        operation: String,
        code: String,
        message: String,
        fieldErrors: [VaultFieldError] = []
    ) {
        self.status = status
        self.operation = operation
        self.code = code
        self.message = message
        self.fieldErrors = fieldErrors
    }
}
