// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  PortholeViewModel.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 17/10/2024.
//

import Foundation
import CellBase
import Combine

public class PortholeViewModel: ObservableObject {
    public enum ActionFeedbackState: String {
        case idle
        case working
        case succeeded
        case failed
    }

    @Published  var flowElements = [FlowElement]()
    @Published var cellReferences = [CellReference]()
    @Published public var localMutationVersion = 0
    @Published private var actionFeedbackStates: [String: ActionFeedbackState] = [:]
    
    @Published var skeleton = SkeletonDescriptions.skeletonDescriptionFromJson().skeleton

    @Published var outWardMenuConfigurations = [CellConfiguration]()
    @Published var connectionsMenuConfigurations = [CellConfiguration]()
    @Published var historyMenuConfigurations = [CellConfiguration]()
    @Published private(set) var currentRequesterIdentity: Identity?
    
    private var valueCache: Object = [:] // Change to Actor for thread safety
    public let cache = PortholeCache()
    @Published var showAlert = false
    @Published var alertTitle = "Connection challenge"
    @Published var alertMessage = ""
    @Published var alertPrimaryActionLabel = "Dismiss"
    private var alertHelperConfiguration: CellConfiguration?
    private var pendingAdmissionSessionID: String?
    private var pendingAdmissionCanAutoResolve = false
    private var pendingAdmissionRetryTask: Task<Void, Never>?
    private var pendingAdmissionAutoRetryTask: Task<Void, Never>?
    private var suppressChallengeAlertForSessionID: String?
    
    var flowLimit = 10
    var flowCancellable: AnyCancellable?
    
    var portholeCell: OrchestratorCell?
    public init() {
        print("*************** Init Porthole view model! **********************")
        Task {
//            await AppInitializer.shared.setupCellResolvers()
            
            if let vault = CellBase.defaultIdentityVault,
                let resolver = CellBase.defaultCellResolver,
                let identity = await vault.identity(for: "private", makeNewIfNotFound: true) {

                do {
                    await MainActor.run {
                        self.currentRequesterIdentity = identity
                    }
                portholeCell = try await resolver.cellAtEndpoint(endpoint: "cell:///Porthole", requester: identity) as? OrchestratorCell
//                    let _ = portholeCell?.getOwner().valueForKey(key: "String", requester: identity) // Must implement get / set
                    let resolverEmitter = FlowElementPusherCell(owner: identity)
                    try await resolver.setResolverEmitter(resolverEmitter, requester: identity)
                    let status = try await portholeCell!.attach(emitter: resolverEmitter, label: "resolver", requester: identity)
                    print("Attaching resolverEmitter to Porthole with status: \(status)")
                    
                    if let existingConfiguration = portholeCell?.getCellConfiguration(),
                       existingConfiguration.skeleton != nil {
                        await self.applyCellConfiguration(cellConfiguration: existingConfiguration)
                    } else {
                        let cellConfiguration = SkeletonDescriptions.skeletonDescriptionFromJson()
                        await self.applyCellConfiguration(cellConfiguration: cellConfiguration)
                        self.loadCellConfiguration(cellConfiguration)
                    }
//                    try await self.portholeCell?.setCellConfiguration(cellConfig: cellConfiguration)
                } catch {
                    print("loading Porthole failed with error: \(error)")
                }
                
//                do {
//                    try await portholeCell!.executeCellConfiguration()
//                } catch {
//                    print("Execute porthole cell config failed with error: \(error)")
//                    let configuration = SkeletonDescriptions.skeletonDescriptionFromJson()
//                    try await portholeCell!.setCellConfiguration(cellConfig: configuration)
//                    try await portholeCell!.executeCellConfiguration()
//                }
                if let references = portholeCell?.getCellConfiguration()?.cellReferences {
                    await MainActor.run {
                        for reference in references {
                            self.cellReferences.append(reference)
                        }
                    }
                }
                
                do {
                    
                    flowCancellable = try await self.portholeCell!.flow(requester: identity)
                        .sink(receiveCompletion: { completion in
                            print("Porthole flow got completion: \(completion)")
                            self.flowCancellable = nil
                        }) { [weak self] flowElement in
                            guard let self = self else { return }
//                            print("Porthole got flowElement: \(flowElement)")
                            Task {
                                
                                await self.appendFlowELement(flowElement)
                            }
                        }
                } catch {
                    print("starting feed failed with error: \(error)" )
                }
                do {
                    try await fetchOutwardMenu(requester: identity)
                } catch {
                    print("Getting outward menu failed with error: \(error)")
                }
                do {
                    try await fetchHistoryMenu(requester: identity)
                } catch {
                    print("Getting outward menu failed with error: \(error)")
                }
                
                
            }
        }
    }

    @MainActor
    public func markLocalMutation() {
        localMutationVersion += 1
        schedulePendingAdmissionRetry(trigger: "local_mutation")
    }

    @MainActor
    public func actionFeedbackState(for actionID: String) -> ActionFeedbackState {
        actionFeedbackStates[actionID] ?? .idle
    }

    @MainActor
    public func setActionFeedbackState(_ state: ActionFeedbackState, for actionID: String) {
        actionFeedbackStates[actionID] = state
    }

    @MainActor
    public func clearActionFeedbackState(for actionID: String) {
        actionFeedbackStates[actionID] = .idle
    }

    @MainActor
    public func rememberRequesterIdentity(_ identity: Identity?) {
        currentRequesterIdentity = identity
    }

    public func executionRequesterIdentity() async -> Identity? {
        currentRequesterIdentity
    }
    
    func fetchOutwardMenu(requester: Identity) async throws  {
        if let portholeCell = self.portholeCell {
            let configValuelist = try await portholeCell.get(keypath: "outwardMenu", requester: requester)
            
            
            if case let .list( configList) = configValuelist {
                print("******** Got outward list (\(configList.count)) ********")
                for configValue in configList {
                    if case let .cellConfiguration(cellConfiguration) = configValue {
                        await self.appendOutwardMenu(cellConfiguration: cellConfiguration)
                        
                    }
                }
            }
        }
    }
    
    func fetchHistoryMenu(requester: Identity) async throws  {
        if let portholeCell = self.portholeCell {
            let configValuelist = try await portholeCell.get(keypath: "historyMenu", requester: requester)
            
            
            if case let .list( configList) = configValuelist {
                print("******** Got history list (\(configList.count)) ********")
                await emptyHistoryMenu()
                for configValue in configList {
                    if case let .cellConfiguration(cellConfiguration) = configValue {
                        await self.appendHistoryMenu(cellConfiguration: cellConfiguration)
                        
                    }
                }
            }
        }
    }

    @MainActor
    func appendReferences(_ references: [CellReference]) {
        for reference in references {
            
            self.cellReferences.append(reference)
            
        }
    }
    
    @MainActor
    func appendFlowELement(_ flowElement: FlowElement) {
//        print("Appending flow element: \(flowElement) elements: \(flowElements.count)")
        self.flowElements.insert(flowElement, at: 0)
        self.handleConnectChallengeIfNeeded(flowElement)
        self.handleAdmissionFeedSignalIfNeeded(flowElement)
        if self.flowElements.count > flowLimit {
            self.flowElements.removeLast()
        }
    }
    
    @MainActor
    func appendOutwardMenu(cellConfiguration: CellConfiguration) {
        self.outWardMenuConfigurations.append(cellConfiguration)
    }
    
    @MainActor
    func emptyHistoryMenu() {
        self.historyMenuConfigurations.removeAll()
    }
    
    @MainActor
    func appendHistoryMenu(cellConfiguration: CellConfiguration) {
        self.historyMenuConfigurations.append(cellConfiguration)
    }
    
    
    @MainActor
    func applyCellConfiguration(cellConfiguration: CellConfiguration) {
//        print("Applying cellConf: \(cellConfiguration)")
        self.skeleton = cellConfiguration.skeleton
    }
    
    func loadCellConfiguration(_ cellConfiguration: CellConfiguration) {
        Task { [weak self] in
            guard let self = self,
                  let portholeCell = portholeCell else {
                return
            }
            if let identity = await executionRequesterIdentity() {
                do {
                    await MainActor.run {
                        self.currentRequesterIdentity = identity
                    }
                    try await portholeCell.loadCellConfiguration(cellConfiguration, requester: identity)
                    await self.applyCellConfiguration(cellConfiguration: cellConfiguration)
                    do {
                        try await fetchHistoryMenu(requester: identity)
                    } catch {
                        CellBase.diagnosticLog("PortholeViewModel outward menu fetch failed: \(error)", domain: .resolver)
                    }
                    
                    
                } catch {
                    CellBase.diagnosticLog("PortholeViewModel load failed for \(cellConfiguration.name): \(error)", domain: .resolver)
                }
                
            }
        }
    }

    @MainActor
    func executeAlertPrimaryAction() {
        if let helper = alertHelperConfiguration {
            loadCellConfiguration(helper)
        }
        showAlert = false
    }

    @MainActor
    private func schedulePendingAdmissionRetry(
        sessionID explicitSessionID: String? = nil,
        delayNanoseconds: UInt64 = 250_000_000,
        trigger: String
    ) {
        guard let sessionID = explicitSessionID ?? pendingAdmissionSessionID,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        pendingAdmissionRetryTask?.cancel()
        pendingAdmissionRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            if Task.isCancelled {
                return
            }
            CellBase.diagnosticLog(
                "PortholeViewModel retrying pending admission session=\(sessionID) trigger=\(trigger)",
                domain: .flow
            )
            _ = await self?.retryPendingAdmissionSession(sessionID: sessionID)
        }
    }

    @MainActor
    private func synchronizePendingAdmissionAutoRetry() {
        pendingAdmissionAutoRetryTask?.cancel()
        pendingAdmissionAutoRetryTask = nil

        guard let sessionID = pendingAdmissionSessionID,
              pendingAdmissionCanAutoResolve else {
            return
        }

        pendingAdmissionAutoRetryTask = Task { [weak self] in
            let retryIntervals: [UInt64] = [
                750_000_000,
                1_500_000_000,
                3_000_000_000,
                5_000_000_000
            ]

            for delay in retryIntervals {
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled {
                    return
                }
                guard await self?.shouldContinuePendingAdmissionAutoRetry(sessionID: sessionID) == true else {
                    return
                }
                _ = await self?.retryPendingAdmissionSession(sessionID: sessionID)
            }

            while await self?.shouldContinuePendingAdmissionAutoRetry(sessionID: sessionID) == true {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled {
                    return
                }
                guard await self?.shouldContinuePendingAdmissionAutoRetry(sessionID: sessionID) == true else {
                    return
                }
                _ = await self?.retryPendingAdmissionSession(sessionID: sessionID)
            }
        }
    }

    @MainActor
    private func shouldContinuePendingAdmissionAutoRetry(sessionID: String) -> Bool {
        pendingAdmissionSessionID == sessionID && pendingAdmissionCanAutoResolve
    }

    @MainActor
    private func clearPendingAdmissionState(sessionID: String? = nil, dismissAlert: Bool = false) {
        if let sessionID,
           pendingAdmissionSessionID != sessionID {
            return
        }
        pendingAdmissionSessionID = nil
        pendingAdmissionCanAutoResolve = false
        pendingAdmissionRetryTask?.cancel()
        pendingAdmissionRetryTask = nil
        pendingAdmissionAutoRetryTask?.cancel()
        pendingAdmissionAutoRetryTask = nil
        suppressChallengeAlertForSessionID = nil
        if dismissAlert {
            showAlert = false
        }
    }

    @MainActor
    private func handleAdmissionFeedSignalIfNeeded(_ flowElement: FlowElement) {
        guard pendingAdmissionSessionID != nil else {
            return
        }
        guard shouldTreatFlowElementAsAdmissionRetrySignal(flowElement) else {
            return
        }
        schedulePendingAdmissionRetry(
            delayNanoseconds: pendingAdmissionCanAutoResolve ? 150_000_000 : 350_000_000,
            trigger: "feed:\(flowElement.topic)"
        )
    }

    private func shouldTreatFlowElementAsAdmissionRetrySignal(_ flowElement: FlowElement) -> Bool {
        switch flowElement.topic {
        case "connect.challenge", "agreement.engagement", "developer.warning":
            return false
        default:
            break
        }

        if flowElement.origin != nil {
            return true
        }

        switch flowElement.properties?.type {
        case .event, .content:
            return true
        default:
            return false
        }
    }

    private func retryPendingAdmissionSession(sessionID: String) async -> ConnectState? {
        guard await shouldRetryPendingAdmissionSession(sessionID: sessionID) else {
            return nil
        }
        guard let portholeCell = portholeCell,
              let identity = await executionRequesterIdentity() else {
            return nil
        }
        await MainActor.run {
            suppressChallengeAlertForSessionID = sessionID
        }
        do {
            let state = try await portholeCell.retryAdmissionSession(id: sessionID, requester: identity)
            await MainActor.run {
                switch state {
                case .connected:
                    clearPendingAdmissionState(sessionID: sessionID, dismissAlert: true)
                case .denied, .notConnected:
                    clearPendingAdmissionState(sessionID: sessionID, dismissAlert: false)
                case .signContract:
                    break
                }
            }
            return state
        } catch {
            await MainActor.run {
                suppressChallengeAlertForSessionID = nil
            }
            CellBase.diagnosticLog("PortholeViewModel retryPendingAdmissionSession failed: \(error)", domain: .flow)
            return nil
        }
    }

    @MainActor
    private func shouldRetryPendingAdmissionSession(sessionID: String) -> Bool {
        pendingAdmissionSessionID == sessionID
    }

    @MainActor
    private func handleConnectChallengeIfNeeded(_ flowElement: FlowElement) {
        guard flowElement.topic == "connect.challenge",
              case let .object(contentObject) = flowElement.content else {
            return
        }

        var challengeObject = contentObject
        if let primaryIssue = firstIssueObject(from: contentObject) {
            for (key, value) in primaryIssue where challengeObject[key] == nil {
                challengeObject[key] = value
            }
        }

        let connectState = stringValue(challengeObject["state"]) ?? stringValue(contentObject["state"]) ?? "unmet"
        let reasonCode = stringValue(challengeObject["reasonCode"]) ?? "connect_challenge_unknown"
        let requiredAction = stringValue(challengeObject["requiredAction"]) ?? "review_agreement"
        let helper = cellConfigurationValue(challengeObject["helperCellConfiguration"])
        let sessionID = stringValue(challengeObject["sessionId"])
        let canAutoResolve = boolValue(challengeObject["canAutoResolve"]) ??
            boolValue(contentObject["canAutoResolve"]) ??
            false

        let baseMessage = stringValue(challengeObject["userMessage"]) ??
            fallbackMessage(for: connectState, reasonCode: reasonCode, requiredAction: requiredAction)
        let actionMessage = actionHint(for: requiredAction, hasHelper: helper != nil)

        if let sessionID {
            if pendingAdmissionSessionID != sessionID {
                suppressChallengeAlertForSessionID = nil
            }
            pendingAdmissionSessionID = sessionID
            pendingAdmissionCanAutoResolve = canAutoResolve
            synchronizePendingAdmissionAutoRetry()
            if suppressChallengeAlertForSessionID == sessionID {
                return
            }
        } else if connectState == "denied" {
            clearPendingAdmissionState(dismissAlert: false)
        }

        alertTitle = connectState == "denied" ? "Connection denied" : "Condition not resolved"
        alertMessage = actionMessage == nil ? baseMessage : "\(baseMessage)\n\n\(actionMessage!)"
        alertHelperConfiguration = helper
        alertPrimaryActionLabel = helper == nil ? "OK" : "Open helper"
        showAlert = true
    }

    private func fallbackMessage(for state: String, reasonCode: String, requiredAction: String) -> String {
        if state == "denied" {
            return "Connection was denied by the target cell."
        }
        if requiredAction == "prepay" {
            return "A prepayment is required before this condition can be resolved."
        }
        if requiredAction == "request_consent" || requiredAction == "grant_consent" {
            return "You need to provide consent before this condition can be resolved."
        }
        return "Connection could not continue because contract conditions are not met (\(reasonCode))."
    }

    private func actionHint(for requiredAction: String, hasHelper: Bool) -> String? {
        var hints = [String]()
        switch requiredAction {
        case "request_consent", "grant_consent":
            hints.append("You need to give consent to proceed.")
        case "prepay":
            hints.append("You need to complete prepayment to proceed.")
        case "open_helper_configuration":
            hints.append("Open the helper to complete the required step.")
        case "request_access":
            hints.append("Ask the owner (or delegated identity) for access.")
        case "review_agreement":
            hints.append("Review the agreement terms and resolve the missing condition.")
        default:
            break
        }
        if hasHelper {
            hints.append("Tap \"Open helper\" to get the guided tools.")
        }
        return hints.isEmpty ? nil : hints.joined(separator: " ")
    }

    private func firstIssueObject(from object: Object) -> Object? {
        guard let issuesValue = object["issues"],
              case let .list(issues) = issuesValue else {
            return nil
        }
        for issue in issues {
            if case let .object(issueObject) = issue {
                return issueObject
            }
        }
        return nil
    }

    private func stringValue(_ value: ValueType?) -> String? {
        guard let value else {
            return nil
        }
        switch value {
        case let .string(string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let .integer(integer):
            return String(integer)
        case let .number(number):
            return String(number)
        default:
            return nil
        }
    }

    private func cellConfigurationValue(_ value: ValueType?) -> CellConfiguration? {
        guard let value else {
            return nil
        }
        if case let .cellConfiguration(configuration) = value {
            return configuration
        }
        return nil
    }

    private func boolValue(_ value: ValueType?) -> Bool? {
        guard let value else {
            return nil
        }
        switch value {
        case let .bool(bool):
            return bool
        case let .string(string):
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
