// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum PersonalCopilotAppStoreV1Contract {
    public static let appStoreScope = "personal-copilot-v1"
    public static let appStoreScopeInterest = "appStoreScope=\(appStoreScope)"
    public static let blockedConfigurationNamePrefixes = ["Conference", "Sponsor", "Admin", "Control Tower"]

    public static let catalogCellName = "PersonalCopilotConfigurationCatalog"
    public static let catalogEndpoint = "cell:///PersonalCopilotConfigurationCatalog"
    public static let catalogStateKeypath = "state"
    public static let catalogConfigurationsKeypath = "configurations"
    public static let catalogEntriesKeypath = "catalogEntries"
}

public struct PersonalCopilotConfigurationMetadata: Codable, Hashable {
    public var appStoreScope: String
    public var policyCategory: String
    public var ageRatingHint: String
    public var requiresLogin: Bool
    public var requiresUserGeneratedContentModeration: Bool
    public var nativePermissionRequests: [String]
    public var universalLink: String
    public var reviewSummary: String

    public init(
        appStoreScope: String = PersonalCopilotAppStoreV1Contract.appStoreScope,
        policyCategory: String,
        ageRatingHint: String = "12+",
        requiresLogin: Bool = true,
        requiresUserGeneratedContentModeration: Bool,
        nativePermissionRequests: [String] = [],
        universalLink: String,
        reviewSummary: String
    ) {
        self.appStoreScope = appStoreScope
        self.policyCategory = policyCategory
        self.ageRatingHint = ageRatingHint
        self.requiresLogin = requiresLogin
        self.requiresUserGeneratedContentModeration = requiresUserGeneratedContentModeration
        self.nativePermissionRequests = nativePermissionRequests
        self.universalLink = universalLink
        self.reviewSummary = reviewSummary
    }

    public var discoveryInterests: [String] {
        [
            "appStoreScope=\(appStoreScope)",
            "policyCategory=\(policyCategory)",
            "ageRatingHint=\(ageRatingHint)",
            "requiresLogin=\(requiresLogin)",
            "requiresUserGeneratedContentModeration=\(requiresUserGeneratedContentModeration)",
            "nativePermissionRequests=\(nativePermissionRequests.isEmpty ? "none" : nativePermissionRequests.joined(separator: ","))",
            "universalLink=\(universalLink)",
            "reviewSummary=\(reviewSummary)"
        ]
    }

    public func objectValue() -> Object {
        [
            "appStoreScope": .string(appStoreScope),
            "policyCategory": .string(policyCategory),
            "ageRatingHint": .string(ageRatingHint),
            "requiresLogin": .bool(requiresLogin),
            "requiresUserGeneratedContentModeration": .bool(requiresUserGeneratedContentModeration),
            "nativePermissionRequests": .list(nativePermissionRequests.map(ValueType.string)),
            "universalLink": .string(universalLink),
            "reviewSummary": .string(reviewSummary)
        ]
    }
}

public enum PersonalProfilePublisherContract {
    public static let cellName = "PersonalProfilePublisher"
    public static let endpoint = "cell:///PersonalProfilePublisher"
    public static let stateKeypath = "state"
    public static let publicReadModelKeypath = "publicReadModel"
    public static let publishKeypath = "publish"
    public static let unpublishKeypath = "unpublish"
    public static let deleteKeypath = "delete"
}

public enum PublicProfileDirectoryContract {
    public static let cellName = "PublicProfileDirectory"
    public static let endpoint = "cell:///PublicProfileDirectory"
    public static let stateKeypath = "state"
    public static let searchKeypath = "search"
    public static let reportProfileKeypath = "reportProfile"
    public static let hideProfileKeypath = "hideProfile"
    public static let blockProfileKeypath = "blockProfile"
    public static let blockedProfilesKeypath = "blockedProfiles"
}

public enum PersonalMatchmakingContract {
    public static let cellName = "PersonalMatchmaking"
    public static let endpoint = "cell:///PersonalMatchmaking"
    public static let stateKeypath = "state"
    public static let preferencesKeypath = "preferences"
    public static let setPreferencesKeypath = "setPreferences"
    public static let suggestionsKeypath = "suggestions"
    public static let requestConsentKeypath = "requestConsent"
    public static let approveMatchKeypath = "approveMatch"
    public static let declineMatchKeypath = "declineMatch"
}

public enum PersonalChatHubContract {
    public static let cellName = "PersonalChatHub"
    public static let endpoint = "cell:///PersonalChatHub"
    public static let stateKeypath = "state"
    public static let inviteKeypath = "invite"
    public static let acceptInviteKeypath = "acceptInvite"
    public static let declineInviteKeypath = "declineInvite"
    public static let setComposerKeypath = "setComposer"
    public static let sendComposedMessageKeypath = "sendComposedMessage"
    public static let clearComposerKeypath = "clearComposer"
    public static let reportMessageKeypath = "reportMessage"
    public static let blockUserKeypath = "blockUser"
    public static let blockedUsersKeypath = "blockedUsers"
    public static let moderationStatusKeypath = "moderationStatus"
    public static let assistantStateKeypath = "assistantState"
    public static let assistantSuggestionsKeypath = "assistantSuggestions"
    public static let assistantPolicyKeypath = "assistantPolicy"
    public static let pollsKeypath = "polls"
    public static let pollDraftKeypath = "pollDraft"
    public static let purposeWeightsKeypath = "purposeWeights"
    public static let analyzeDraftKeypath = "assistant.analyzeDraft"
    public static let acceptSuggestionKeypath = "assistant.acceptSuggestion"
    public static let dismissSuggestionKeypath = "assistant.dismissSuggestion"
    public static let queryResourceKeypath = "assistant.queryResource"
    public static let setCandidateQueryKeypath = "assistant.setCandidateQuery"
    public static let selectCandidateKeypath = "assistant.selectCandidate"
    public static let dropReceiveKeypath = "drop.receive"
    public static let pollSetQuestionKeypath = "poll.setQuestion"
    public static let pollSetOptionsKeypath = "poll.setOptions"
    public static let pollCreateKeypath = "poll.create"
    public static let pollVoteKeypath = "poll.vote"
    public static let pollCloseKeypath = "poll.close"
    public static let assistantInvitePurposeRef = "personal.chat.assist.invite"
    public static let assistantPollPurposeRef = "personal.chat.assist.poll"
    public static let assistantResourceRouterPurposeRef = "personal.chat.assist.resource-router"
    public static let assistantRAGQueryPurposeRef = "personal.chat.assist.rag-query"

    public static let reusedCellProtocolChatKeypaths = [
        "audience.inviteIdentities",
        "audience.acceptInvites",
        "audience.declineInvites",
        "sendComposedMessage",
        "clearComposer"
    ]
}

public enum PersonalMeetingCoordinatorContract {
    public static let cellName = "PersonalMeetingCoordinator"
    public static let endpoint = "cell:///PersonalMeetingCoordinator"
    public static let stateKeypath = "state"
    public static let proposeMeetingKeypath = "proposeMeeting"
    public static let meetingBridgeKeypath = "meetingBridge"
}
