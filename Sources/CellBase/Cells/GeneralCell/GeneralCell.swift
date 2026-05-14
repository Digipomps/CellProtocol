// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

enum GeneralCellErrors: Error {
    case noPublisherForLabel
    case noSchemaForKey
}


open class GeneralCell: CellProtocol, OwnerInstantiable, Codable {
    var ttl = 7776000 // 90 days
    var schemaDict = Object()
    var schemaDescriptionDict = Object()
    private var cellScopeInternal: CellUsageScope
    public var cellScope: CellUsageScope {
        get {
            return cellScopeInternal
        }
        set {
            cellScopeInternal = newValue
            
        }
    }
    public var persistancy: Persistancy
    
    
    public func keys(requester: Identity) async throws -> [String] {
        // validate permissions
        
        return Array(schemaDict.keys)
    }
    
    public func typeForKey(key: String, requester: Identity) async throws -> ValueType {
        // validate permissions
        guard let schema = schemaDict[key] else {
            throw GeneralCellErrors.noSchemaForKey
        }
                
        return schema
    }

    public func schemaDescriptionForKey(key: String, requester: Identity) async throws -> ValueType {
        guard let description = schemaDescriptionDict[key] else {
            throw GeneralCellErrors.noSchemaForKey
        }
        return description
    }

    public func registerExploreSchema(
        requester: Identity,
        key: String,
        schema: ValueType,
        description: ValueType = .string("*")
    ) async {
        if await isAllowedToSetupIntercepts(requester: requester) {
            self.register(key: key, schema: schema, description: description)
        }
    }
    
    
    public func connectedLabels(requester: Identity) async -> [String] {

        if await validateAccess("r--", at: "connectedCellEmitters", for: requester) {
            return  await auditor.connectedLabels()
        }
        return [String]()
    }
    
    public func label(for uuid: String, requester: Identity) async -> String? {
        var label: String?
        if await validateAccess("r--", at: "labelForUuid", for: requester) {
        for currentLabel in await auditor.connectedLabels() {
            if let emitCell = await auditor.loadConnectedCellEmitterForLabel(currentLabel) {
                if emitCell.uuid == uuid {
                    label = currentLabel
                    break
                }
            }
        }
        }
        return label
    }
    
    public var uuid: String = UUID().uuidString
    public var name: String
    internal var owner: Identity
    public var agreementTemplate: Agreement
    var feedProperties = FeedProperties(endpoint: URL(string: "ws://localhost/dev/null"), type: .continous, mimetype: nil)

    // Publishers and Cancellables
    private var feedPublisher = PassthroughSubject<FlowElement, Error>()
    public var identityDomain: String = "private"
    
//    internal let dispatchQueue = DispatchQueue.init(label: "General Cell dispatch queue")
    private var initialized = false
    
    private var intercepts = Intercepts()
    private var auditor = GeneralAuditor()
    
    
    
    
    required public init(owner: Identity) async {
        self.owner = owner
        self.agreementTemplate = Agreement(owner: owner)
        self.cellScopeInternal = .template
        self.persistancy = .ephemeral
        self.name = self.uuid
    }
    
    public func doneInitializing() {
        initialized = true
    }
    
    public func getOwner(requester: Identity) async throws  -> Identity {
        // test access throw denied
        return owner
    }
    
    public init() async { // This should only be used while we are developing
        
        if let tmpOwner = await (CellBase.defaultIdentityVault?.identity(for: identityDomain, makeNewIfNotFound: true)) {
            self.owner = tmpOwner
        } else {
            owner = Identity()
        }
        self.agreementTemplate = Agreement(owner: owner)
        CellBase.diagnosticLog("Created GeneralCell for owner \(owner.uuid)", domain: .lifecycle)
        self.cellScopeInternal = .template
        self.persistancy = .ephemeral
        self.name = self.uuid
    }
    
    deinit {
        CellBase.diagnosticLog("Deinitializing GeneralCell \(self.uuid)", domain: .lifecycle)
        // ...clean up...
        
    }
    
     enum CodingKeys: String, CodingKey
    {
        case uuid
        case owner
//        case name
        case contractTemplate
        case magnetTemplates
        case toolTemplates
        case povTemplates
        case experiences
        case feedEndpoint
        case feedProperties
        case identityDomain
        case cellScope
        case persistancy
        case name
    }
    
    public required init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.uuid) {
            if let suppliedUuid = try? values.decode(String.self, forKey: .uuid) {
                uuid = suppliedUuid
            } else {
                uuid = UUID.init().uuidString
            }
        } else {
            uuid = UUID.init().uuidString
        }
        
        owner = try values.decode(Identity.self, forKey: .owner)
        
        agreementTemplate = try! values.decode(Agreement.self, forKey: .contractTemplate)
        
        identityDomain = try values.decode(String.self, forKey: .identityDomain)
        self.cellScopeInternal = try values.decode(CellUsageScope.self, forKey: .cellScope)
        self.persistancy = try values.decode(Persistancy.self, forKey: .persistancy)
        
        if let tmpName = try values.decodeIfPresent(String.self, forKey: .name) {
            name = tmpName
        } else {
            name = String(describing: uuid)
        }
        
    }
    
    open func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(agreementTemplate, forKey: .contractTemplate)
        
        try? container.encode(feedProperties, forKey: .feedProperties)
        try container.encode(identityDomain, forKey: .identityDomain)
        try container.encode(self.owner, forKey: .owner)
        try container.encode(cellScopeInternal, forKey: .cellScope)
        try container.encode(persistancy, forKey: .persistancy)
        
            }
    
// High level utility functions
    
    // Easy subscribe Dont care about identity used
    public func subscribeToPublisherWithEndpoint(_ endpoint: String, label: String) async throws {
        guard let identity = await CellBase.defaultIdentityVault?.identity(for: endpoint, makeNewIfNotFound: true) else {
            return
        }
        guard let emitCell = try await CellBase.defaultCellResolver?.cellAtEndpoint(endpoint: endpoint, requester: identity) else {
            return
        }
        
        let connectState = try await self.attach(emitter: emitCell, label: label, requester: identity)
        if connectState != .connected {
            CellBase.diagnosticLog(
                "subscribeToPublisherWithEndpoint connectState=\(connectState) endpoint=\(endpoint) label=\(label)",
                domain: .flow
            )
        }
    }
    
    // Run through connect (maybe add contract) and start Feed (finds appropriate Identity)
    public func instantFeed() async -> AnyPublisher<FlowElement, Error> {
//            Task { [weak self] in
//            guard let self = self else { return }
            if let identity = await (CellBase.defaultIdentityVault?.identity(for: identityDomain, makeNewIfNotFound: true)) {
                CellBase.diagnosticLog("instantFeed identity=\(identity.uuid)", domain: .flow)
//                do {
                    let connectState = await self.admit(context: ConnectContext(source: nil, target: self, identity: identity))
                    
                    if connectState != .connected && connectState != .notConnected {
                        Task { [weak self] in
                            guard let self = self else { return }
                            let flowElement = FlowElement(title: "GEN", content: .string("Feed denied. \(connectState)"), properties: FlowElement.Properties( type: .content, contentType: .string))
                            self.feedPublisher.send(flowElement)
                            self.feedPublisher.send(completion: .failure(FlowError.denied))
                        }
                    }
//                else {
//                        await self.startFeed(requester: identity)
//                    }
            } else {
                Task { [weak self] in
                    guard let self = self else { return }
                    let flowElement = FlowElement(title: "Error", content: .string("No Identity for domain: \(identityDomain)"), properties: FlowElement.Properties( type: .content, contentType: .string))
                    self.feedPublisher.send(flowElement)
                    self.feedPublisher.send(completion: .failure(FlowError.noIdentity))
                }
            }
//        }
//        return self.feedPublisher.share().eraseToAnyPublisher()
        return self.getFeedPublisher()
    }
    
    
// Cell Absorb functions
    
    public func attach(emitter: Emit, label: String, requester: Identity) async throws -> ConnectState {
        let connectContext = ConnectContext(source: self, target: emitter, identity: requester)
        let connectState = await emitter.admit(context: connectContext )
        CellBase.diagnosticLog("attach label=\(label) connectState=\(connectState)", domain: .flow)
        let adjustedConnectState =  try await self.consumeConnectResponseForIdentity(connectState: connectState, label: label, identity: requester, emitCell: emitter)
        return adjustedConnectState
    }

    public func retryAdmissionSession(id: String, requester: Identity) async throws -> ConnectState {
        guard let session = await auditor.loadAdmissionSession(id: id) else {
            throw FlowError.noResolver
        }
        guard let target = await auditor.loadAdmissionTargetForLabel(session.label) else {
            throw CellBaseError.noTargetCell
        }
        return try await attach(emitter: target, label: session.label, requester: requester)
    }
    
    
    private struct ContractChallengeIssue {
        let conditionName: String
        let conditionType: String
        let state: ConditionState
        let descriptor: ConnectChallengeDescriptor?

        var reasonCode: String {
            descriptor?.reasonCode ?? "condition_\(state.rawValue)"
        }

        var userMessage: String {
            if let message = descriptor?.userMessage,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            return "Condition '\(conditionName)' is \(state.rawValue)."
        }

        var requiredAction: String {
            descriptor?.requiredAction ?? "review_agreement"
        }

        var canAutoResolve: Bool {
            descriptor?.canAutoResolve ?? false
        }

        var helperCellConfiguration: CellConfiguration? {
            descriptor?.helperCellConfiguration
        }

        var developerHint: String? {
            descriptor?.developerHint
        }

        var hasActionableRemediation: Bool {
            guard let descriptor else {
                return false
            }
            if helperCellConfiguration != nil {
                return true
            }
            let normalizedAction = descriptor.requiredAction.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedAction.isEmpty && normalizedAction != "none" && normalizedAction != "review_agreement" {
                return true
            }
            return false
        }

        func asObject() -> Object {
            var object: Object = [
                "conditionName": .string(conditionName),
                "conditionType": .string(conditionType),
                "state": .string(state.rawValue),
                "reasonCode": .string(reasonCode),
                "userMessage": .string(userMessage),
                "requiredAction": .string(requiredAction),
                "canAutoResolve": .bool(canAutoResolve)
            ]
            if let helperCellConfiguration {
                object["helperCellConfiguration"] = .cellConfiguration(helperCellConfiguration)
            }
            if let developerHint,
               !developerHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                object["developerHint"] = .string(developerHint)
            }
            return object
        }
    }

    private struct ContractChallengeEvaluation {
        let contractCondition: ContractCondition
        let issues: [ContractChallengeIssue]
    }

    func consumeConnectResponseForIdentity( connectState: ConnectState, label: String, identity: Identity, emitCell: Emit) async throws -> ConnectState {
        var adjustedConnectState = connectState
        switch connectState {
        case .connected:
            await auditor.removeAdmissionSessionForLabel(label)
            await self.addEmitter(emitCell, for: label, requester: identity)
        case .signContract:
            let connectContext = ConnectContext(source: self, target: emitCell, identity: identity)
            let challengeEvaluation = await self.processContractChallenge(context: connectContext , agreementTemplate: emitCell.agreementTemplate)
            if challengeEvaluation.contractCondition == .met {
                // Sign contract here...
                let contract = emitCell.agreementTemplate
                contract.signatories.append(identity)
                    contract.sign(identity: identity)
                adjustedConnectState = .connected
                
                let contractState = try await emitCell.addAgreement(contract, for: identity)
                if contractState == .signed {
                    await auditor.removeAdmissionSessionForLabel(label)
                    await self.addEmitter(emitCell, for: label, requester: identity)
                } else if  contractState != .template {
                    let flowElement = FlowElement(id: UUID().uuidString, title: "Not signed contract", content: .string(contractState.rawValue), properties: FlowElement.Properties(type: .alert, contentType: .string))
                    self.feedPublisher.send(flowElement)
                    
                } else {
                    CellBase.diagnosticLog("connect response returned template agreement state for label=\(label)", domain: .flow)
                }
            } else {
                emitLegacyConsentEvent(context: connectContext, agreementTemplate: emitCell.agreementTemplate, emitCell: emitCell)
                let session = await upsertAdmissionSession(
                    label: label,
                    state: .signContract,
                    identity: identity,
                    emitCell: emitCell,
                    agreementTemplate: emitCell.agreementTemplate,
                    issues: challengeEvaluation.issues
                )
                emitConnectChallenge(
                    state: .signContract,
                    context: connectContext,
                    agreementTemplate: emitCell.agreementTemplate,
                    issues: challengeEvaluation.issues,
                    session: session,
                    emitCell: emitCell
                )
            }
        case .denied:
            let connectContext = ConnectContext(source: self, target: emitCell, identity: identity)
            let deniedIssue = ContractChallengeIssue(
                conditionName: "Connection admission",
                conditionType: "ConnectState.denied",
                state: .unmet,
                descriptor: ConnectChallengeDescriptor(
                    reasonCode: "connect_denied",
                    userMessage: "Tilkoblingen ble avvist av mottakeren.",
                    requiredAction: "request_access",
                    canAutoResolve: false,
                    helperCellConfiguration: nil,
                    developerHint: "Emitter returned .denied from admit(context:)."
                )
            )
            let session = await upsertAdmissionSession(
                label: label,
                state: .denied,
                identity: identity,
                emitCell: emitCell,
                agreementTemplate: emitCell.agreementTemplate,
                issues: [deniedIssue]
            )
            emitConnectChallenge(
                state: .denied,
                context: connectContext,
                agreementTemplate: emitCell.agreementTemplate,
                issues: [deniedIssue],
                session: session,
                emitCell: emitCell
            )
        case .notConnected:
            CellBase.diagnosticLog("connect response remained notConnected for label=\(label)", domain: .flow)
        }
        return adjustedConnectState
    }
    
    private func addEmitter(_ emitter: Emit, for label: String, requester: Identity) async {
        let existingEmitter = await auditor.loadConnectedCellEmitterForLabel(label)
        let emitterChanged = existingEmitter?.uuid != emitter.uuid

        await auditor.storeConnectedCellEmitterForLabel(label: label, emitter: emitter)

        if emitterChanged {
            await auditor.storeSubscribedFeedForLabel(label: label, subscribedFeed: nil)
            await auditor.storeFeedCancellablesForLabel(label: label, feedCancellable: nil)
        }
    }
    
    private func processContractChallenge(context: ConnectContext, agreementTemplate: Agreement) async -> ContractChallengeEvaluation {
        var contractCondition = ContractCondition.unresolved
        var issues = [ContractChallengeIssue]()
        let agreement = agreementTemplate
        if let identity = context.identity {
            agreement.signatories.append(identity)
            // check if conditions in contract is governed by automatic policies
            if agreement.conditions.count > 0 {
                var allConditionsMet = true
                for currentCondition in agreement.conditions {
                    CellBase.diagnosticLog("Evaluating condition \(currentCondition.name)", domain: .flow)
                    let currentConditionState = await currentCondition.isMet(context: context)
                    if  currentConditionState != .met {
                        allConditionsMet = false

                        var descriptor: ConnectChallengeDescriptor?
                        if let challengeProvider = currentCondition as? ConnectChallengeProvidingCondition {
                            descriptor = await challengeProvider.connectChallengeDescriptor(context: context)
                        }
                        if descriptor == nil {
                            descriptor = defaultChallengeDescriptor(for: currentCondition, state: currentConditionState)
                        }
                        issues.append(
                            ContractChallengeIssue(
                                conditionName: currentCondition.name,
                                conditionType: String(describing: type(of: currentCondition)),
                                state: currentConditionState,
                                descriptor: descriptor
                            )
                        )

                        if currentConditionState == .engage,
                           currentCondition is ConditionalEngagement {
                            CellBase.diagnosticLog("Condition \(currentCondition.name) requested engagement", domain: .flow)
                            let conditionalCondition = currentCondition as! ConditionalEngagement
                            // add engagement to feed
                            do {
                                let engagementData = try JSONEncoder().encode(conditionalCondition.engagement)
                                let engagementObject = try JSONDecoder().decode(Object.self, from: engagementData)

                                var conditionalEngagementFlowElement = FlowElement(id: UUID().uuidString, title: conditionalCondition.name, content: .object(engagementObject), properties: FlowElement.Properties(type: .event, contentType: .experienceTemplate))
                                conditionalEngagementFlowElement.topic = "agreement.engagement"

                                self.feedPublisher.send(conditionalEngagementFlowElement)
                            } catch {
                                print("Encoding engagement data (General) failed with error: \(error)")
                            }
                       }
                    }
                }
                if allConditionsMet { // not an very actual way to solve it
                    //
                    contractCondition = .met
                    

                }
                // if not handled automaticly issue a message to Person using app
                //            displayAlert = true
                
                
            } else {
                contractCondition = .met // Maybe it shouldnt be possible with conditionless, but easier to test with
            }
        }
        return ContractChallengeEvaluation(contractCondition: contractCondition, issues: issues)
    }

    private func defaultChallengeDescriptor(for condition: any Condition, state: ConditionState) -> ConnectChallengeDescriptor {
        let normalizedType = String(describing: type(of: condition))
        let message: String
        switch state {
        case .engage:
            message = "Condition '\(condition.name)' requires user action before access can be granted."
        case .unmet:
            message = "Condition '\(condition.name)' is not met."
        case .unresolved:
            message = "Condition '\(condition.name)' could not be resolved automatically."
        case .met:
            message = "Condition '\(condition.name)' is met."
        }
        let helperConfiguration = reviewAgreementHelperConfiguration(
            title: "Agreement review required",
            message: message
        )
        return ConnectChallengeDescriptor(
            reasonCode: "condition_\(state.rawValue)_\(normalizedType)",
            userMessage: message,
            requiredAction: "review_agreement",
            canAutoResolve: false,
            helperCellConfiguration: helperConfiguration,
            developerHint: "Add ConnectChallengeProvidingCondition conformance to provide user guidance and helper tools."
        )
    }

    private func reviewAgreementHelperConfiguration(title: String, message: String) -> CellConfiguration {
        var configuration = CellConfiguration(name: "Agreement Review")
        configuration.description = "Aapner AgreementWorkbench for aa gjennomgaa avtalen og se hva som mangler for opptak."
        configuration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: "cell:///AgreementWorkbench",
            sourceCellName: "AgreementWorkbenchCell",
            purpose: "Review unresolved agreement conditions",
            purposeDescription: "Bruk workbench til aa forstaa avtalen, grants og conditions foer du prover admission pa nytt.",
            interests: ["agreement", "access", "conditions", "proofs", "retry"],
            menuSlots: ["upperMid"]
        )
        configuration.addReference(CellReference(endpoint: "cell:///AgreementWorkbench", subscribeFeed: false, label: "agreementWorkbench"))
        configuration.skeleton = .VStack(SkeletonVStack(elements: [
            .Text(SkeletonText(text: title)),
            .Text(SkeletonText(text: message)),
            .Text(SkeletonText(keypath: "agreementWorkbench.state.headline")),
            .Text(SkeletonText(keypath: "agreementWorkbench.state.intro")),
            .Text(SkeletonText(keypath: "agreementWorkbench.state.friendlySummary")),
            .Text(SkeletonText(keypath: "agreementWorkbench.state.saveResult"))
        ]))
        return configuration
    }

    private func upsertAdmissionSession(
        label: String,
        state: ConnectState,
        identity: Identity,
        emitCell: Emit,
        agreementTemplate: Agreement,
        issues: [ContractChallengeIssue]
    ) async -> AdmissionSession {
        let now = Int(Date().timeIntervalSince1970)
        let primaryIssue = issues.first
        await auditor.storeAdmissionTarget(emitCell, for: label)
        if var existing = await auditor.loadAdmissionSessionForLabel(label) {
            existing.refresh(
                targetCellUUID: emitCell.uuid,
                agreementUUID: agreementTemplate.uuid,
                agreementName: agreementTemplate.name,
                connectState: state,
                primaryReasonCode: primaryIssue?.reasonCode,
                requiredAction: primaryIssue?.requiredAction,
                issueCount: issues.count,
                updatedAt: now
            )
            await auditor.storeAdmissionSession(existing)
            return existing
        }

        let session = AdmissionSession(
            label: label,
            requesterUUID: identity.uuid,
            targetCellUUID: emitCell.uuid,
            agreementUUID: agreementTemplate.uuid,
            agreementName: agreementTemplate.name,
            connectState: state,
            primaryReasonCode: primaryIssue?.reasonCode,
            requiredAction: primaryIssue?.requiredAction,
            issueCount: issues.count,
            createdAt: now
        )
        await auditor.storeAdmissionSession(session)
        return session
    }

    private func emitLegacyConsentEvent(context: ConnectContext, agreementTemplate: Agreement, emitCell: Emit) {
        let contentObject: Object = [
            "state": .string("unmet"),
            "agreement": .agreementPayload(agreementTemplate),
            "context": .connectContext(context)
        ]

        var flowElement = FlowElement(
            id: UUID().uuidString,
            title: "Not resolved",
            content: .object(contentObject),
            properties: FlowElement.Properties(type: .alert, contentType: .object)
        )
        flowElement.origin = emitCell.uuid
        flowElement.topic = "consent"
        self.feedPublisher.send(flowElement)
    }

    private func emitConnectChallenge(
        state: ConnectState,
        context: ConnectContext,
        agreementTemplate: Agreement,
        issues: [ContractChallengeIssue],
        session: AdmissionSession?,
        emitCell: Emit
    ) {
        let primaryIssue = issues.first
        let title: String
        switch state {
        case .denied:
            title = "Connection denied"
        case .signContract:
            title = "Contract condition unresolved"
        case .connected:
            title = "Connection challenge"
        case .notConnected:
            title = "Connection unavailable"
        }

        var contentObject: Object = [
            "state": .string(state == .denied ? "denied" : "unmet"),
            "connectState": .connectState(state),
            "agreement": .agreementPayload(agreementTemplate),
            "context": .connectContext(context),
            "issues": .list(issues.map { .object($0.asObject()) }),
            "issueCount": .integer(issues.count)
        ]

        if let session {
            contentObject["sessionId"] = .string(session.id)
            contentObject["session"] = .object(session.asObject())
        }

        if let primaryIssue {
            contentObject["reasonCode"] = .string(primaryIssue.reasonCode)
            contentObject["userMessage"] = .string(primaryIssue.userMessage)
            contentObject["requiredAction"] = .string(primaryIssue.requiredAction)
            contentObject["canAutoResolve"] = .bool(primaryIssue.canAutoResolve)
            if let helper = primaryIssue.helperCellConfiguration {
                contentObject["helperCellConfiguration"] = .cellConfiguration(helper)
            }
            if let developerHint = primaryIssue.developerHint {
                contentObject["developerHint"] = .string(developerHint)
            }
        } else {
            contentObject["reasonCode"] = .string("connect_challenge_unknown")
            contentObject["userMessage"] = .string("Connection challenge could not be resolved.")
            contentObject["requiredAction"] = .string("review_agreement")
            contentObject["canAutoResolve"] = .bool(false)
        }

        var flowElement = FlowElement(
            id: UUID().uuidString,
            title: title,
            content: .object(contentObject),
            properties: FlowElement.Properties(type: .alert, contentType: .object)
        )
        flowElement.origin = emitCell.uuid
        flowElement.topic = "connect.challenge"
        self.feedPublisher.send(flowElement)

#if DEBUG
        let hasActionableIssue = issues.contains(where: { $0.hasActionableRemediation })
        if !hasActionableIssue {
            var warningObject: Object = [
                "state": .string("insufficient_connect_challenge_metadata"),
                "agreement": .agreementPayload(agreementTemplate),
                "context": .connectContext(context),
                "issueCount": .integer(issues.count),
                "message": .string("No actionable remediation data was provided. Add a helper CellConfiguration or explicit requiredAction/userMessage.")
            ]
            if let primaryIssue {
                warningObject["conditionName"] = .string(primaryIssue.conditionName)
                warningObject["conditionType"] = .string(primaryIssue.conditionType)
            }
            var warningEvent = FlowElement(
                id: UUID().uuidString,
                title: "Connect challenge metadata missing",
                content: .object(warningObject),
                properties: FlowElement.Properties(type: .alert, contentType: .object)
            )
            warningEvent.origin = emitCell.uuid
            warningEvent.topic = "developer.warning"
            self.feedPublisher.send(warningEvent)
        }
#endif
    }
    
    // change to absorb flow
    public func absorbFlow(label: String, requester: Identity) async throws {  
//        Task { [weak self] in
//            guard let self = self else { return }
            if let emitCell = await self.auditor.loadConnectedCellEmitterForLabel(label) {
                if await self.auditor.loadSubscribedFeedsForLabel(label) == nil {
                    let subscribeFeedPublisher = try await emitCell.flow(requester: requester)
                    await self.auditor.storeSubscribedFeedForLabel(label: label, subscribedFeed: subscribeFeedPublisher)
                    let feedCancellable = subscribeFeedPublisher
                        .sink(receiveCompletion: { completion in
                            CellBase.diagnosticLog("feed completion label=\(label) completion=\(completion)", domain: .flow)
                            
                        }, receiveValue: { [weak self] flowElement in
                            guard let self = self else { return }
//                                print("General got feed item: \(flowElement.title) label: \(flowElement.label)")
                            Task {
                                if let intercept = await self.intercepts.loadFeedIntercept() {
                                    if let transformedFlowElement = await intercept(flowElement, requester) {
                                        self.feedPublisher.send(transformedFlowElement)
                                    }
                                } else {
                                    self.feedPublisher.send(flowElement)
                                }
                            }
                        })
                    await self.auditor.storeFeedCancellablesForLabel(label: label, feedCancellable: feedCancellable)
                    
                } else {
                    CellBase.diagnosticLog("feed already active for label=\(label)", domain: .flow)
                }
            } else {
                print("No emitter for \(label)") // FIXME: server reports this error
                self.feedPublisher.send(completion: .failure(GeneralCellErrors.noPublisherForLabel))
            }
//        }
    }
   
    private func handleFeedEvent(eventDescriptionValue: FlowElementValueType, requester: Identity) async -> FlowElement? {
        do {
            if case let .object(descriptionObject) = eventDescriptionValue,
                let type = try descriptionObject["type"]?.stringValue(),
               let publisherUuid = try descriptionObject["uuid"]?.stringValue() {
                if type == "closing", // use switch later
                    let activeLabel = await auditor.connectedLabel(for: publisherUuid) {
                        detach(label: activeLabel, requester: requester)
                    }
                
            }
        } catch {
            print("handling event faiuled with error: \(error)")
        }
        return nil
    }
    
    private func handleFeedAlert(alertDescriptionValue: FlowElementValueType, requester: Identity) async -> FlowElement? {
        
        return nil
    }
    
    public func getFeedPublisher() -> AnyPublisher<FlowElement, Error> {
        feedPublisher.eraseToAnyPublisher()
    }
    
    
    open func flow(requester: Identity) async throws  -> AnyPublisher<FlowElement, Error> {
        if await validateAccess("r--", at: "feed", for: requester) {
            CellBase.defaultCellResolver?.logAction(context: ConnectContext(source: nil, target: self, identity: requester), action: "feed", param: "nil")
            return feedPublisher.eraseToAnyPublisher()
        }
        throw StreamState.denied
    }
    
    open func admit(context: ConnectContext) async -> ConnectState {
//        let connectStatePublisher = PassthroughSubject<ConnectState, Error>()
        var connectState = ConnectState.notConnected
       if let identity = context.identity {
               let identityState = await self.determineIdentityState(identity: identity)
               
               switch identityState {
               case .owner:
                   connectState = .connected
                   
               case .member:
                   connectState = .connected
               case .other:
                   connectState = .signContract
               }
               
               
       } else {
           print("No identity to determine state for!")
       }
        CellBase.defaultCellResolver?.logAction(context: context, action: "connect", param: connectState.rawValue)
        
       return connectState
    }
    
    
    public func close(requester: Identity) {
        //opportunity to do some decrementing connected count - and following cleanup
        CellBase.diagnosticLog("Closing GeneralCell \(self.uuid)", domain: .lifecycle)
        
    }
    
    public func addAgreement(_ agreement: Agreement, for identity: Identity) async -> AgreementState {
        let context = ConnectContext(source: nil, target: self, identity: identity)
        if agreement.conditions.count == 0 {
            return .template // not sure about this...
        }
        
        if await allConditionsResolved(agreement.conditions, context: context) {
            
            await self.auditor.addContract(agreement)
            await self.auditor.addMember(identity)
            
        
            // sign contract
            agreement.state = .signed
            // cache grants?
        } else {
            agreement.state = .rejected
            
        }
        return agreement.state
    }
    
    private func allConditionsResolved(_ conditions: [Condition], context: ConnectContext) async -> Bool {
        var resolved = true
        for condition in conditions {
            if await condition.isMet(context: context) != .met {
                resolved = false
                break
            }
        }
        return resolved
    }
    
    open func advertise(for identity: Identity) async -> AnyCell {
        let manifest = try? await self.exploreManifest(requester: identity)
        return AnyCell(
            uuid: self.uuid,
            name: "",
            contractTemplate: self.agreementTemplate,
            owner: self.owner,
            experiences: nil,
            feedEndpoint: nil,
            feedProperties: nil,
            identityDomain: self.identityDomain,
            exploreManifest: manifest
        )
    }
    
    open func state(requester: Identity) async throws -> ValueType {
        return .string("not implemented")
    }
    
    enum KeyValueErrors: Error {
        case notFound
        case denied
        case otherError
    }
    
    
    open func get(keypath: String, requester: Identity) async throws -> ValueType {
        CellBase.defaultCellResolver?.logAction(context: ConnectContext(source: nil, target: self, identity: requester), action: "get", param: keypath)
        let resolvedKeyPath = keypath // will look for substitutions later?
        
        let keypathArray = resolvedKeyPath.split(separator: ".")
        let contextKey = String(keypathArray[0])
        let childKeypath = String(resolvedKeyPath.dropFirst("\(keypathArray[0]).".count))
        
        switch contextKey {
        case "isMember":
            let result = await isMember(uuid: childKeypath, requester: self.owner)
            return .bool(result)
        case "members":
            print("Key members not implemented")
        default:
            break
        }
        
        if
            let connectedCell = await self.getEmitterWithLabel(contextKey, requester: requester),
            let keypathLookup = connectedCell as? Meddle
        {
            if let value = try? await keypathLookup.get(keypath: childKeypath, requester: requester) {
                return value
            }
            if let value = try? await fallbackNestedLookup(
                through: keypathLookup,
                keypath: childKeypath,
                requester: requester
            ) {
                return value
            }
        }
        
        if
            await self.validateAccess("r---", at: contextKey, for: requester) {
            
            if let intercept = await self.intercepts.loadInterceptGet(keypath: keypath) {
                CellBase.diagnosticLog("get intercept key=\(contextKey) keypath=\(keypath)", domain: .flow)
                return try await intercept(keypath, requester)
            } else if let intercept = await self.intercepts.loadInterceptValueForKey(key: contextKey) {
                CellBase.diagnosticLog("get value intercept key=\(contextKey)", domain: .flow)
                return await intercept(requester)
            } else if let intercept = await self.intercepts.loadInterceptGet(keypath: contextKey) {
                CellBase.diagnosticLog("get nested intercept root=\(contextKey) keypath=\(keypath)", domain: .flow)
                let rootValue = try await intercept(contextKey, requester)
                return try resolveNestedValue(rootValue, childKeypath: childKeypath)
            } else {
                throw KeyValueErrors.notFound
            }
            
            
        }
        throw KeyValueErrors.denied
        
    }

    private func fallbackNestedLookup(
        through target: Meddle,
        keypath: String,
        requester: Identity
    ) async throws -> ValueType {
        let (rootKey, nestedKeypath) = splitRootLookupKeypath(keypath)
        guard !rootKey.isEmpty, !nestedKeypath.isEmpty else {
            throw KeyValueErrors.notFound
        }

        let rootValue = try await target.get(keypath: rootKey, requester: requester)
        return try resolveNestedValue(rootValue, childKeypath: nestedKeypath)
    }

    private func splitRootLookupKeypath(_ keypath: String) -> (root: String, remainder: String) {
        guard let firstSeparator = keypath.firstIndex(where: { $0 == "." || $0 == "[" }) else {
            return (keypath, "")
        }

        let root = String(keypath[..<firstSeparator])
        let remainder = String(keypath[firstSeparator...])
        return (root, remainder)
    }

    private func resolveNestedValue(_ value: ValueType, childKeypath: String) throws -> ValueType {
        let trimmedChildKeypath = childKeypath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChildKeypath.isEmpty else {
            return value
        }

        if case let .object(object) = value {
            let normalizedPath = trimmedChildKeypath.hasPrefix(".")
                ? String(trimmedChildKeypath.dropFirst())
                : trimmedChildKeypath
            return try object.get(keypath: normalizedPath)
        }

        var wrapper: Object = ["root": value]
        let normalizedPath: String
        if trimmedChildKeypath.hasPrefix("[") || trimmedChildKeypath.hasPrefix(".") {
            normalizedPath = "root\(trimmedChildKeypath)"
        } else {
            normalizedPath = "root.\(trimmedChildKeypath)"
        }
        return try wrapper.get(keypath: normalizedPath)
    }
    
    open func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? {
        
        
        var response: ValueType?
        
        CellBase.defaultCellResolver?.logAction(context: ConnectContext(source: nil, target: self, identity: requester), action: "set", param: keypath)
            
            let resolvedKeyPath = keypath // will look for substitutions later?
            
            let keypathArray = resolvedKeyPath.split(separator: ".")
            let contextKey = String(keypathArray[0]) // TODO:Errors here must be handeled
            let childKeypath = String(resolvedKeyPath.dropFirst("\(keypathArray[0]).".count))
            
            var foundKey = false
            switch contextKey {
            case "removeMember":
                await self.removeMember(uuid: childKeypath, requester: requester)
//                setValuePublisher.send(completion: .finished)
                foundKey = true
                
            case "members":
                print("Key members not implemented")
                
                
                
            default: ()
                
            }
            
            if !foundKey {
                if let connectedCell = await self.getEmitterWithLabel(contextKey, requester: requester),
                let keypathLookup =  connectedCell as? Meddle {
                    response = try await keypathLookup.set(keypath: childKeypath, value: value, requester: requester)
                    
                  
                } else if await self.validateAccess("-w--", at: contextKey, for: requester) { // We need to look at this...
                            if let intercept = await self.intercepts.loadInterceptSet(keypath: keypath) {
                                response = try await intercept(keypath, value, requester)
                            } else if let intercept = await self.intercepts.loadInterceptSetValueForKey(key: contextKey) {
                                await intercept(value, requester) // Should this throw so we can send failure?
                            } else {
                                throw KeyValueErrors.notFound
                            }
                        
                        
                    } else {
                        
                        throw KeyValueErrors.denied
                    }
                
            }
        
        return response
    }
    
    
    public func isMember(identity: Identity, requester: Identity) async -> Bool {
        return await isMember(uuid: identity.uuid, requester: requester)
    }
    
    public func isMember(uuid: String, requester: Identity) async -> Bool {
        var isMember = false
        if await validateAccess("r---", at: "isMember", for: requester) {
            
            isMember = await auditor.loadMembers().contains(where: { $0.uuid == uuid })
            CellBase.diagnosticLog("isMember uuid=\(uuid) result=\(isMember)", domain: .flow)
        } else {
            pushFlowElement(FlowElement(title: "201", content: .string("insufficient access for isMember"), properties: FlowElement.Properties( type: .alert, contentType: .string)), requester: requester)
        }
        return isMember
    }
    
    public func removeMember(member: Identity, requester: Identity) async {
        if await validateAccess("-w--", at: "members", for: requester) {
            await self.auditor.removeMember(member)
        } else {
            pushFlowElement(FlowElement(title: "201", content: .string("insufficient access (w) for member"), properties: FlowElement.Properties( type: .alert, contentType: .string)), requester: requester)
        }
    }

    public func removeMember(uuid: String, requester: Identity) async {
        if await validateAccess("-w--", at: "members", for: requester) {
            await self.auditor.removeMember(uuid)
        } else {
            pushFlowElement(FlowElement(title: "201", content: .string("insufficient access (w) for member"), properties: FlowElement.Properties( type: .alert, contentType: .string)), requester: requester)
        }
    }
    
    // Utility methods
    open func validateAccess(_ requestedAccess: String, at keypath: String, for identity: Identity) async -> Bool {
        if CellBase.debugValidateAccessForEverything {
            return true
        }
        var accessGranted = false
        let grant = Grant(keypath: keypath, permission: requestedAccess)
        if identitiesReferenceSame(owner, identity) {
            let ownerCheck = await checkIdentityOrigin(identity, against: owner)
            if ownerCheck {
                return true
            } else {
                print("General. Got owner identity but it failed to prove ownership!")
                return false
            }
            
        }
        let contracts = await contractsForIdentity(identity)
        for currentContract in contracts { // usually only one contract
            if currentContract.checkGrant(requestedGrant: grant) {
                accessGranted = true
                break
            }
        }
        if accessGranted {
            return true
        }
        return await validateCellSpecificAccess(requestedAccess, at: keypath, for: identity)
    }

    open func validateCellSpecificAccess(_ requestedAccess: String, at keypath: String, for identity: Identity) async -> Bool {
        false
    }
    
    func contractsForIdentity(_ identity: Identity) async -> [Agreement] {
        var relevantContracts = [Agreement]()
        for currentContract in await auditor.loadContracts() {
            guard
                let trustedSignatory = currentContract.signatories.first(where: { identitiesReferenceSame($0, identity) }),
                await checkIdentityOrigin(identity, against: trustedSignatory)
            else {
                continue
            }
            if currentContract.signatories.contains(where: { identitiesReferenceSame($0, trustedSignatory) }) {
                relevantContracts.append(currentContract)
            }
        }
        return relevantContracts
    }
    
    func determineIdentityState(identity: Identity) async -> IdentityState {
        var identityState = IdentityState.other
        if identitiesReferenceSame(owner, identity),
           await checkIdentityOrigin(identity, against: owner) {
            identityState = IdentityState.owner
        } else {
            
            let contained = await auditor.loadMembers().contains { subMemberIdentity in
                return identitiesReferenceSame(subMemberIdentity, identity)
            }
            if contained,
               let trustedMember = await auditor.loadMembers().first(where: { identitiesReferenceSame($0, identity) }),
               await checkIdentityOrigin(identity, against: trustedMember) {
                identityState = .member
            }
        }
        return identityState
    }
    
    func checkIdentityOrigin(_ identity: Identity) async -> Bool {
        await checkIdentityOrigin(identity, against: identity)
    }

    func checkIdentityOrigin(_ identity: Identity, against trustedIdentity: Identity) async -> Bool {
        if CellBase.debugValidateAccessForEverything {return true}
        guard let identityVault = identity.identityVault else {
            print("Identity: \(identity.uuid) had no identity vault!")
            return false
        }
        guard trustedIdentity.publicSecureKey?.compressedKey?.isEmpty == false else {
            print("Trusted identity: \(trustedIdentity.uuid) had no public signing key!")
            return false
        }
        guard let signData = await identityVault.randomBytes64() else {
            print("Get random bytes failed")
            return false
        }
        
        guard let signedData = try? await identity.sign(data: signData) else {
            print("Got no signed data!")
            return false
        }
        guard let verificationVault = trustedIdentity.identityVault ?? identity.identityVault ?? CellBase.defaultIdentityVault else {
            print("No vault available to verify identity: \(trustedIdentity.uuid)")
            return false
        }
        return (try? await verificationVault.verifySignature(signature: signedData, messageData: signData, for: trustedIdentity)) ?? false
    }

    func identitiesReferenceSame(_ trustedIdentity: Identity, _ presentedIdentity: Identity) -> Bool {
        if let trustedPublicKey = trustedIdentity.publicSecureKey?.compressedKey,
           trustedPublicKey.isEmpty == false,
           let presentedPublicKey = presentedIdentity.publicSecureKey?.compressedKey,
           presentedPublicKey.isEmpty == false,
           trustedIdentity.publicSecureKey?.algorithm == presentedIdentity.publicSecureKey?.algorithm,
           trustedIdentity.publicSecureKey?.curveType == presentedIdentity.publicSecureKey?.curveType {
            return trustedPublicKey == presentedPublicKey
        }
        return trustedIdentity.uuid == presentedIdentity.uuid
    }
    
    func defaultIdentity() async throws -> Identity {
        guard let identity = await (CellBase.defaultIdentityVault?.identity(for: identityDomain, makeNewIfNotFound: true)) else {
            throw IdentityVaultError.noVaultIdentity
        }
        return identity
    }
    
    public func addIntercept(requester: Identity, intercept: @escaping FlowElementIntercept) async {
        if await isAllowedToSetupIntercepts(requester: requester) {
            await self.intercepts.storeFeedIntercept(intercept)
        }
    }
    
    
    @available(*, deprecated)
    public func setInterceptSetValueForKey(requester: Identity, key: String, setValueForKeyIntercept: @escaping SetValueForKeyIntercept) async {
        if await isAllowedToSetupIntercepts(requester: requester) {
            await self.intercepts.storeInterceptSetValueForKey(key: key, intercept: setValueForKeyIntercept)
        }
    }
    
    private func isAllowedToSetupIntercepts(requester: Identity) async -> Bool { // TODO: change permission chack to something more meaningful
        guard identitiesReferenceSame(owner, requester) else {
            return false
        }
        return await checkIdentityOrigin(requester, against: owner)
    }
    
    
    @available(*, deprecated)
    public func setInterceptValueForKey(requester: Identity, key: String, setValueForKeyIntercept: @escaping ValueForKeyIntercept) async {
        if await isAllowedToSetupIntercepts(requester: requester) {
            await self.intercepts.storeInterceptValueForKey(key: key, intercept: setValueForKeyIntercept)
        }
    }

    private enum ExploreContractRegistrationDecision {
        case useExisting
        case registerDefault
        case reject
    }

    private func exploreContractRegistrationDecision(
        for key: String,
        method: ExploreContractMethod
    ) -> ExploreContractRegistrationDecision {
        if schemaDict[key] != nil {
            return .useExisting
        }

        switch CellBase.exploreContractEnforcementMode {
        case .permissive:
            return .registerDefault
        case .warn:
            CellBase.diagnosticLog(
                "Implicit Explore contract registration for `\(key)` (\(method.rawValue)) fell back to defaultContract. Register an explicit contract first to keep Explore machine-readable.",
                domain: .contracts
            )
            return .registerDefault
        case .strict:
            CellBase.diagnosticLog(
                "Rejected implicit Explore contract registration for `\(key)` (\(method.rawValue)). Register an explicit Explore contract before adding the intercept.",
                domain: .contracts
            )
            return .reject
        }
    }
    
    //Meddle
    public func addInterceptForGet(requester: Identity, key: String, getValueIntercept: @escaping GetValueIntercept) async {
        if await isAllowedToSetupIntercepts(requester: requester) {
            switch exploreContractRegistrationDecision(for: key, method: .get) {
            case .useExisting:
                break
            case .registerDefault:
                self.register(
                    key: key,
                    schema: ExploreContract.defaultContract(for: key, method: .get),
                    description: .string("*")
                )
            case .reject:
                return
            }
            await self.intercepts.storeInterceptGet(keypath: key, intercept: getValueIntercept)
        }
    }
    
    
    public func addInterceptForSet(requester: Identity, key: String, setValueIntercept: @escaping SetValueIntercept) async {
        if await isAllowedToSetupIntercepts(requester: requester) {
            switch exploreContractRegistrationDecision(for: key, method: .set) {
            case .useExisting:
                break
            case .registerDefault:
                self.register(
                    key: key,
                    schema: ExploreContract.defaultContract(for: key, method: .set),
                    description: .string("*")
                )
            case .reject:
                return
            }
            await self.intercepts.storeInterceptSet(keypath: key, intercept: setValueIntercept)
        }
    }
    
    
    public func detach(label: String, requester: Identity) {
        dropFlow(label: label, requester: requester)
        Task { [weak auditor] in
            guard let auditor = auditor else { return }
        if let resolver = CellBase.defaultCellResolver,
           let connectedCS = await auditor.loadConnectedCellEmitterForLabel(label)
           
        {
            await resolver.unregisterEmitCell(uuid: connectedCS.uuid) // Just testing
            connectedCS.close(requester: requester)
            await auditor.storeConnectedCellEmitterForLabel(label: label, emitter: nil)
        }
            let auditorState = await auditor.auditorState()
            CellBase.diagnosticLog("detach label=\(label) auditorState=\(auditorState)", domain: .flow)
        }
    }
    
    public func dropFlow(label: String, requester: Identity)  {
        Task {[weak auditor] in
            guard let auditor = auditor else { return }
            if (await auditor.loadConnectedCellEmitterForLabel(label)) != nil { // Don't need uuid any more
                await auditor.storeSubscribedFeedForLabel(label: label, subscribedFeed: nil)
                await auditor.storeFeedCancellablesForLabel(label: label, feedCancellable: nil)
            }
            let auditorState = await auditor.auditorState()
            CellBase.diagnosticLog("dropFlow label=\(label) auditorState=\(auditorState)", domain: .flow)
        }
        
    }
    
    public func dropAllFlows(requester: Identity) {
        Task { [weak auditor] in
            guard let auditor = auditor else { return }
            for key in await auditor.connectedLabels() {
                dropFlow(label: key, requester: requester)
            }
        }
    }
    
    public func detachAll(requester: Identity) {
        Task {[weak auditor] in
            guard let auditor = auditor else { return }
            let connectedLabels = await auditor.connectedLabels()
            CellBase.diagnosticLog("detachAll connectedLabels=\(connectedLabels.count)", domain: .flow)
            for key in connectedLabels {
                detach(label: key, requester: requester)
            }
        }
    }
    
    public func pushFlowElement(_ flowElement: FlowElement, requester: Identity) { // This should probably be async?
        Task { [weak self] in
            guard let self = self else { return }
            if await validateAccess("-w--", at: "feed", for: requester) {
                self.feedPublisher.send(flowElement)
            }
        }
    }
    public func getEmitterWithUUID(_ uuid: String, requester: Identity) async -> Emit? {
        if let emit = await auditor.connectedEmitter(for: uuid) {
            return emit
        }
        print("Did not find emit for uuid: \(uuid)")
        return nil
    }
    
    
    public func getEmitterWithLabel(_ label: String, requester: Identity) async -> Emit? {
        if await validateAccess("-w--", at: label, for: requester) {
            return await auditor.loadConnectedCellEmitterForLabel(label)
        }
        return nil
    }
    
    public func attachedStatus(for label: String, requester: Identity) async throws -> ConnectionStatus {
        guard (await getEmitterWithLabel(label, requester: requester)) != nil else {
            return ConnectionStatus(name: label, connected: false, active: false)
        }
        guard (await auditor.loadSubscribedFeedsForLabel(label)) != nil else {
            return ConnectionStatus(name: label, connected: true, active: false)
        }
        
        return ConnectionStatus(name: label, connected: true, active: true)
    }
    
    public func attachedStatuses(requester: Identity) async throws -> [ConnectionStatus] {
        let attachedLabels = await self.connectedLabels(requester: requester)
        var attachedStatuses = [ConnectionStatus]()
        for currentLabel in attachedLabels {
            if let currentAbsorb = await getEmitterWithLabel(currentLabel, requester: requester) as? Absorb {
                let childStatuses = try await currentAbsorb.attachedStatuses(requester: requester)
                for currentChildStatus in childStatuses {
                    let childStatus = ConnectionStatus(name: "\(currentLabel).\(currentChildStatus.name)", connected: currentChildStatus.connected, active: currentChildStatus.active)
                    attachedStatuses.append(childStatus)
                }
                let status = try await attachedStatus(for: currentLabel, requester: requester)
                attachedStatuses.append(status)
            }
        }
        return attachedStatuses
    }
    
    private func register(key: String, schema: ValueType, description: ValueType) {
        self.schemaDict[key] = ExploreContract.normalizeSchema(
            key: key,
            schema: schema,
            description: description
        )
        self.schemaDescriptionDict[key] = description
    }
}
