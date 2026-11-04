// SPDX-License-Identifier: Apache-2.0
import Foundation

extension RelationalLearningCell: EntityAtlasDescribing {
    public func entityAtlasDescriptor(requester: Identity) async throws -> EntityAtlasCellDescriptor {
        EntityAtlasCellDescriptor(
            title: "Relational Learning Cell",
            summary: "Learns weighted relationships between purposes, interests, entities, and context blocks from explicit lifecycle signals.",
            purposeRefs: ["purpose.relational-learning"],
            dependencyRefs: ["Perspective"],
            requiredCredentialClasses: [],
            capabilityHints: [
                "purposeStarted",
                "purposeSucceeded",
                "purposeFailed",
                "contextTransition",
                "policyUpdate",
                "userPreference",
                "scorePurposes",
                "scoreConfigurations",
                "userFeedback",
                "versionAgreement",
                "replay"
            ],
            knowledgeRoles: []
        )
    }
}

