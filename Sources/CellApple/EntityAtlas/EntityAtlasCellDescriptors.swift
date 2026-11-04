// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CellBase

extension PerspectiveCell: EntityAtlasDescribing {
    public func entityAtlasDescriptor(requester: Identity) async throws -> EntityAtlasCellDescriptor {
        EntityAtlasCellDescriptor(
            title: "Perspective Cell",
            summary: "Maintains active purposes, purpose matching, and purpose-linked helper/goal structures for the local entity.",
            purposeRefs: ["purpose.perspective-management"],
            dependencyRefs: [],
            requiredCredentialClasses: [],
            capabilityHints: [
                "activePurpose",
                "addPurpose",
                "matchPurpose",
                "perspective.query.activePurposes",
                "perspective.query.interestsFromActivePurposes",
                "perspective.query.match"
            ],
            knowledgeRoles: []
        )
    }
}


@available(macOS 26.0, iOS 26.0, *)
extension AppleIntelligenceCell: EntityAtlasDescribing {
    public func entityAtlasDescriptor(requester: Identity) async throws -> EntityAtlasCellDescriptor {
        EntityAtlasCellDescriptor(
            title: "Apple Intelligence Cell",
            summary: "Orchestrates local assistant prompting, configuration discovery, and purpose-aware ranking over available cells.",
            purposeRefs: ["purpose.assistant-orchestration"],
            dependencyRefs: ["Perspective", "RelationalLearning"],
            requiredCredentialClasses: [],
            capabilityHints: [
                "ai.discover",
                "ai.rank",
                "ai.ensurePurpose",
                "ai.buildCluster",
                "ai.promptText",
                "ai.promptInstructions"
            ],
            knowledgeRoles: [.knowsCells]
        )
    }
}

extension EntityScannerCell: EntityAtlasDescribing {
    func entityAtlasDescriptor(requester: Identity) async throws -> EntityAtlasCellDescriptor {
        EntityAtlasCellDescriptor(
            title: "Entity Scanner Cell",
            summary: "Discovers nearby entities, exchanges contact payloads, and exports encounter summaries for human review.",
            purposeRefs: ["purpose.entity-contact-discovery"],
            dependencyRefs: [],
            requiredCredentialClasses: [],
            capabilityHints: [
                "start",
                "stop",
                "invite",
                "requestContact",
                "acceptContact",
                "exportEncounter",
                "exportEncounterJSON",
                "capabilities",
                "encounters"
            ],
            knowledgeRoles: []
        )
    }
}
