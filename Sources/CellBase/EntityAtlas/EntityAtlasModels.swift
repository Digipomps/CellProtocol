// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum EntityAtlasFactSource: String, Codable {
    case resolverRegistration
    case runtimeObservation
    case cellDescriptor
    case cellConfiguration
    case vaultDocument
    case secureStore
}

public struct EntityAtlasProvenance: Codable, Equatable {
    public var source: EntityAtlasFactSource
    public var detail: String?
    public var confidence: Double?

    public init(source: EntityAtlasFactSource, detail: String? = nil, confidence: Double? = nil) {
        self.source = source
        self.detail = detail
        self.confidence = confidence
    }
}

public enum EntityAtlasKnowledgeRole: String, Codable, CaseIterable {
    case knowsCells
    case indexesCells
    case describesCells
}

public struct EntityAtlasCellDescriptor: Codable, Equatable {
    public var title: String?
    public var summary: String?
    public var purposeRefs: [String]
    public var dependencyRefs: [String]
    public var requiredCredentialClasses: [String]
    public var capabilityHints: [String]
    public var knowledgeRoles: [EntityAtlasKnowledgeRole]

    public init(
        title: String? = nil,
        summary: String? = nil,
        purposeRefs: [String] = [],
        dependencyRefs: [String] = [],
        requiredCredentialClasses: [String] = [],
        capabilityHints: [String] = [],
        knowledgeRoles: [EntityAtlasKnowledgeRole] = []
    ) {
        self.title = title
        self.summary = summary
        self.purposeRefs = purposeRefs
        self.dependencyRefs = dependencyRefs
        self.requiredCredentialClasses = requiredCredentialClasses
        self.capabilityHints = capabilityHints
        self.knowledgeRoles = knowledgeRoles
    }
}

public protocol EntityAtlasDescribing {
    func entityAtlasDescriptor(requester: Identity) async throws -> EntityAtlasCellDescriptor
}

public struct EntityAtlasCellControlState: Codable, Equatable {
    public var resolverScope: CellUsageScope?
    public var owned: Bool
    public var scaffoldAvailable: Bool
    public var runtimeAvailable: Bool
    public var runtimeAttached: Bool
    public var persistedAttachment: Bool

    public init(
        resolverScope: CellUsageScope? = nil,
        owned: Bool = false,
        scaffoldAvailable: Bool = false,
        runtimeAvailable: Bool = false,
        runtimeAttached: Bool = false,
        persistedAttachment: Bool = false
    ) {
        self.resolverScope = resolverScope
        self.owned = owned
        self.scaffoldAvailable = scaffoldAvailable
        self.runtimeAvailable = runtimeAvailable
        self.runtimeAttached = runtimeAttached
        self.persistedAttachment = persistedAttachment
    }

    public var absorbed: Bool {
        runtimeAttached || persistedAttachment
    }
}

public struct EntityAtlasCellRecord: Codable, Equatable {
    public var cellID: String
    public var name: String
    public var endpoint: String
    public var runtimeUUID: String?
    public var typeName: String?
    public var title: String?
    public var summary: String?
    public var purposes: [String]
    public var capabilities: [String]
    public var dependencyRefs: [String]
    public var requiredCredentialClasses: [String]
    public var knowledgeRoles: [EntityAtlasKnowledgeRole]
    public var controlState: EntityAtlasCellControlState
    public var provenance: [EntityAtlasProvenance]

    public init(
        cellID: String,
        name: String,
        endpoint: String,
        runtimeUUID: String? = nil,
        typeName: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        purposes: [String] = [],
        capabilities: [String] = [],
        dependencyRefs: [String] = [],
        requiredCredentialClasses: [String] = [],
        knowledgeRoles: [EntityAtlasKnowledgeRole] = [],
        controlState: EntityAtlasCellControlState = EntityAtlasCellControlState(),
        provenance: [EntityAtlasProvenance] = []
    ) {
        self.cellID = cellID
        self.name = name
        self.endpoint = endpoint
        self.runtimeUUID = runtimeUUID
        self.typeName = typeName
        self.title = title
        self.summary = summary
        self.purposes = purposes.sorted()
        self.capabilities = capabilities.sorted()
        self.dependencyRefs = dependencyRefs.sorted()
        self.requiredCredentialClasses = requiredCredentialClasses.sorted()
        self.knowledgeRoles = knowledgeRoles.sorted { $0.rawValue < $1.rawValue }
        self.controlState = controlState
        self.provenance = provenance
    }
}

public struct EntityAtlasScaffoldRecord: Codable, Equatable {
    public var scaffoldID: String
    public var name: String
    public var description: String?
    public var purposeRef: String?
    public var purposeDescription: String?
    public var sourceCellEndpoint: String?
    public var sourceCellName: String?
    public var referencedCellEndpoints: [String]
    public var provenance: [EntityAtlasProvenance]

    public init(
        scaffoldID: String,
        name: String,
        description: String? = nil,
        purposeRef: String? = nil,
        purposeDescription: String? = nil,
        sourceCellEndpoint: String? = nil,
        sourceCellName: String? = nil,
        referencedCellEndpoints: [String] = [],
        provenance: [EntityAtlasProvenance] = []
    ) {
        self.scaffoldID = scaffoldID
        self.name = name
        self.description = description
        self.purposeRef = purposeRef
        self.purposeDescription = purposeDescription
        self.sourceCellEndpoint = sourceCellEndpoint
        self.sourceCellName = sourceCellName
        self.referencedCellEndpoints = referencedCellEndpoints.sorted()
        self.provenance = provenance
    }
}

public enum EntityAtlasNodeKind: String, Codable {
    case entity
    case cell
    case scaffold
    case promptDocument
    case contextDocument
    case assistantProfile
    case modelProviderProfile
    case credentialHandle
}

public enum EntityAtlasRelationKind: String, Codable {
    case owns
    case scaffoldAvailable
    case runtimeAttached
    case persistedAttachment
    case solves
    case providesCapability
    case dependsOn
    case requiresCredential
    case usesPrompt
    case usesContext
    case usesModelProvider
    case derivedFromScaffold
    case knowsAbout
}

public struct EntityAtlasRelation: Codable, Equatable {
    public var fromID: String
    public var kind: EntityAtlasRelationKind
    public var toID: String
    public var explanation: String
    public var provenance: [EntityAtlasProvenance]

    public init(
        fromID: String,
        kind: EntityAtlasRelationKind,
        toID: String,
        explanation: String,
        provenance: [EntityAtlasProvenance] = []
    ) {
        self.fromID = fromID
        self.kind = kind
        self.toID = toID
        self.explanation = explanation
        self.provenance = provenance
    }
}

public enum EntityAtlasPurposeCoverageStatus: String, Codable {
    case covered
    case partial
    case blocked
}

public struct EntityAtlasPurposeCoverageExplanation: Codable, Equatable {
    public var purposeRef: String
    public var status: EntityAtlasPurposeCoverageStatus
    public var supportingCellIDs: [String]
    public var scaffoldCandidateCellIDs: [String]
    public var blockedReasons: [String]
    public var explanation: String

    public init(
        purposeRef: String,
        status: EntityAtlasPurposeCoverageStatus,
        supportingCellIDs: [String],
        scaffoldCandidateCellIDs: [String],
        blockedReasons: [String],
        explanation: String
    ) {
        self.purposeRef = purposeRef
        self.status = status
        self.supportingCellIDs = supportingCellIDs.sorted()
        self.scaffoldCandidateCellIDs = scaffoldCandidateCellIDs.sorted()
        self.blockedReasons = blockedReasons
        self.explanation = explanation
    }
}

public struct EntityAtlasSnapshot: Codable, Equatable {
    public var generatedAtEpochMs: Int
    public var cells: [EntityAtlasCellRecord]
    public var scaffolds: [EntityAtlasScaffoldRecord]
    public var promptDocuments: [AtlasPromptDocument]
    public var contextDocuments: [AtlasContextDocument]
    public var assistantProfiles: [AtlasAssistantProfile]
    public var providerProfiles: [AtlasModelProviderProfile]
    public var credentialHandles: [AtlasCredentialHandleRecord]
    public var relations: [EntityAtlasRelation]

    public init(
        generatedAtEpochMs: Int,
        cells: [EntityAtlasCellRecord],
        scaffolds: [EntityAtlasScaffoldRecord],
        promptDocuments: [AtlasPromptDocument],
        contextDocuments: [AtlasContextDocument],
        assistantProfiles: [AtlasAssistantProfile],
        providerProfiles: [AtlasModelProviderProfile],
        credentialHandles: [AtlasCredentialHandleRecord],
        relations: [EntityAtlasRelation]
    ) {
        self.generatedAtEpochMs = generatedAtEpochMs
        self.cells = cells.sorted { $0.cellID < $1.cellID }
        self.scaffolds = scaffolds.sorted { $0.scaffoldID < $1.scaffoldID }
        self.promptDocuments = promptDocuments.sorted { $0.id < $1.id }
        self.contextDocuments = contextDocuments.sorted { $0.id < $1.id }
        self.assistantProfiles = assistantProfiles.sorted { $0.id < $1.id }
        self.providerProfiles = providerProfiles.sorted { $0.id < $1.id }
        self.credentialHandles = credentialHandles.sorted { $0.id < $1.id }
        self.relations = relations.sorted { lhs, rhs in
            if lhs.fromID != rhs.fromID { return lhs.fromID < rhs.fromID }
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.toID < rhs.toID
        }
    }
}
