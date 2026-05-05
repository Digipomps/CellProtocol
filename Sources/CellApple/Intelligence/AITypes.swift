// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  AITypes.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 22/12/2025.
//

import Foundation

public enum AITopics {
    public static let state = "ai.assistant.state"
    public static let recommendations = "ai.assistant.recommendations"
    public static let requestConfigs = "ai.intent.requestConfigurations"
    public static let responseConfigs = "ai.intent.response.configurations"
    public static let exploreRequest = "explore.request"
    public static let exploreResponse = "explore.response"
    public static let exploreAnnounce = "explore.announce"
}

public enum AIKeys {
    public static let root = "ai"
    public static let status = "status"
    public static let currentPurposeRef = "currentPurposeRef"
    public static let purposeClusterRefs = "purposeClusterRefs"
    public static let candidates = "candidates"
    public static let scoringWeights = "scoringWeights"
    public static let lastDiscoveryAt = "lastDiscoveryAt"
    public static let lastError = "lastError"
    public static let outbox = "outbox" // list of ValueType.object messages for Flow
    public static let sendFlowOnIngest = "sendFlowOnIngest"
    public static let promptText = "promptText"
    public static let promptInstructions = "promptInstructions"
    public static let rankEnabled = "rankEnabled"
    public static let rankWeights = "rankWeights"
    public static let lastToolArguments = "lastToolArguments"
}

public enum AIStatus: String, Codable {
    case idle, discovering, ready, error
}
