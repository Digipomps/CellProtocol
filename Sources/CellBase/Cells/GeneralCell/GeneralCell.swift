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
    case flowBufferOverflow
    case noSchemaForKey
}

public enum AgreementAdmissionPolicy: String, Codable, Sendable {
    case ownerApprovalRequired
    case automaticWhenConditionsMet
    case ownerPublishedRead
}

public protocol CellRuntimeReady: AnyObject {
    func ensureRuntimeReady() async throws
}

private actor CellRuntimeReadinessCoordinator {
    private var installed = false
    private var installation: Task<Void, Error>?

    func ensure(_ install: @escaping () async throws -> Void) async throws {
        if installed {
            return
        }
        if let installation {
            return try await installation.value
        }

        let task = Task {
            try await install()
        }
        installation = task
        do {
            try await task.value
            installed = true
            installation = nil
        } catch {
            installation = nil
            throw error
        }
    }
}

private final class CellRuntimeBindingInstallationToken: @unchecked Sendable {
    private let cellIdentifier: ObjectIdentifier
    private let lock = NSLock()
    private var active = true

    init(cell: GeneralCell) {
        cellIdentifier = ObjectIdentifier(cell)
    }

    func authorizes(_ cell: GeneralCell) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && cellIdentifier == ObjectIdentifier(cell)
    }

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

final class FlowBufferOverflowState: @unchecked Sendable {
    private let lock = NSLock()
    private var overflowed = false
    private var invalidated = false
    private var activeForwardReservations = 0
    private var drainWaiters = [CheckedContinuation<Void, Never>]()

    @discardableResult
    func markOverflow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard overflowed == false else {
            return false
        }
        overflowed = true
        invalidated = true
        return true
    }

    func performIfNotOverflowed(_ operation: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard overflowed == false, invalidated == false else {
            return false
        }
        operation()
        return true
    }

    func reserveForwardIfNotOverflowed() -> FlowForwardReservation? {
        lock.lock()
        defer { lock.unlock() }
        guard overflowed == false, invalidated == false else {
            return nil
        }
        activeForwardReservations += 1
        return FlowForwardReservation(state: self)
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    func waitForForwardReservationsToDrain() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard activeForwardReservations > 0 else {
                lock.unlock()
                continuation.resume()
                return
            }
            drainWaiters.append(continuation)
            lock.unlock()
        }
    }

    fileprivate func isForwardReservationValid() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated == false && overflowed == false
    }

    fileprivate func releaseForwardReservation() {
        lock.lock()
        guard activeForwardReservations > 0 else {
            lock.unlock()
            return
        }
        activeForwardReservations -= 1
        let waiters: [CheckedContinuation<Void, Never>]
        if activeForwardReservations == 0 {
            waiters = drainWaiters
            drainWaiters.removeAll()
        } else {
            waiters = []
        }
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func didOverflow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowed
    }
}

final class FlowForwardReservation: @unchecked Sendable {
    private let lock = NSLock()
    private var state: FlowBufferOverflowState?

    fileprivate init(state: FlowBufferOverflowState) {
        self.state = state
    }

    func shouldDeliver() -> Bool {
        lock.lock()
        let state = self.state
        lock.unlock()
        return state?.isForwardReservationValid() == true
    }

    func finish() {
        lock.lock()
        let state = self.state
        self.state = nil
        lock.unlock()
        state?.releaseForwardReservation()
    }

    deinit {
        finish()
    }
}


open class GeneralCell: CellProtocol, OwnerInstantiable, Codable, CellAuthorizationDeciding, CellRuntimeReady {
    static let flowEventBufferLimit = 256
    private static let missingIdentityVaultLogLock = NSLock()
    nonisolated(unsafe) private static var missingIdentityVaultLoggedUUIDs: Set<String> = []
    @TaskLocal private static var isEvaluatingAuthorizationConditions = false
    @TaskLocal private static var runtimeBindingInstallationToken: CellRuntimeBindingInstallationToken?
    @TaskLocal private static var attachedStatusTraversalVisitedCells: Set<ObjectIdentifier> = []

    var ttl = 7776000 // 90 days
    var schemaDict = Object()
    var schemaDescriptionDict = Object()
    private var operationSchemaDict = [String: [ExploreContractMethod: ValueType]]()
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
        try await ensureRuntimeReady()
        // validate permissions
        
        return Array(schemaDict.keys)
    }
    
    public func typeForKey(key: String, requester: Identity) async throws -> ValueType {
        try await ensureRuntimeReady()
        // validate permissions
        guard let schema = schemaDict[key] else {
            throw GeneralCellErrors.noSchemaForKey
        }
                
        return schema
    }

    public func contract(
        for key: String,
        method: ExploreContractMethod,
        requester: Identity
    ) async throws -> ValueType {
        try await ensureRuntimeReady()
        guard let schema = operationSchemaDict[key]?[method] else {
            throw GeneralCellErrors.noSchemaForKey
        }
        return schema
    }

    public func operationContracts(requester: Identity) async throws -> [ValueType] {
        try await ensureRuntimeReady()
        return operationSchemaDict.keys.sorted().flatMap { key in
            operationSchemaDict[key, default: [:]].keys
                .sorted { $0.rawValue < $1.rawValue }
                .compactMap { operationSchemaDict[key]?[$0] }
        }
    }

    public func schemaDescriptionForKey(key: String, requester: Identity) async throws -> ValueType {
        try await ensureRuntimeReady()
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

        if await validateAccess("r---", at: "connectedCellEmitters", for: requester) {
            return  await auditor.connectedLabels()
        }
        return [String]()
    }
    
    public func label(for uuid: String, requester: Identity) async -> String? {
        var label: String?
        if await validateAccess("r---", at: "labelForUuid", for: requester) {
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
    public var agreementAdmissionPolicy: AgreementAdmissionPolicy
    var feedProperties = FeedProperties(endpoint: URL(string: "ws://localhost/dev/null"), type: .continous, mimetype: nil)

    // Publishers and Cancellables
    private var feedPublisher = PassthroughSubject<FlowElement, Error>()
    public var identityDomain: String = "private"
    
//    internal let dispatchQueue = DispatchQueue.init(label: "General Cell dispatch queue")
    private var initialized = false
    
    private var intercepts = Intercepts()
    private var auditor = GeneralAuditor()
    private var persistedContracts = [Contract]()
    private var persistedMembers = [Identity]()
    private var persistedAuthorizationRevision = 0
    private let persistedAuthorizationLock = NSLock()
    private let runtimeReadinessCoordinator = CellRuntimeReadinessCoordinator()
    
    
    
    
    required public init(owner: Identity) async {
        self.owner = owner
        self.agreementTemplate = Agreement(owner: owner)
        self.agreementAdmissionPolicy = .ownerApprovalRequired
        self.cellScopeInternal = .template
        self.persistancy = .ephemeral
        self.name = self.uuid
    }
    
    public func doneInitializing() {
        initialized = true
    }
    
    public func getOwner(requester: Identity) async throws  -> Identity {
        _ = requester
        return owner.publicIdentitySnapshot()
    }

    public var storedOwnerIdentity: Identity {
        owner.publicIdentitySnapshot()
    }

    /// Returns the process-local owner only while its attached vault can still
    /// prove control of the signing key stored in this Cell. Hosts use this
    /// during the second phase of persisted Cell rehydration, after the
    /// resolver has bound a verified requester with
    /// `bindStoredOwnerToRuntimeIdentity(_:)`.
    @_spi(HAVENRuntime)
    public func verifiedRuntimeOwnerIdentity() async -> Identity? {
        guard owner.identityVault != nil,
              await checkIdentityOrigin(owner, against: owner) else {
            return nil
        }
        return owner
    }

    /// Reattaches the persisted owner descriptor to a local runtime vault only
    /// after the candidate proves control of the same signing key.
    @_spi(HAVENRuntime) @discardableResult
    public func bindStoredOwnerToRuntimeIdentity(_ runtimeOwner: Identity) async -> Bool {
        guard identitiesReferenceSame(owner, runtimeOwner),
              runtimeOwner.identityVault != nil,
              await checkIdentityOrigin(runtimeOwner, against: owner) else {
            return false
        }
        owner.identityVault = runtimeOwner.identityVault
        owner.homeVaultReference = runtimeOwner.homeVaultReference
        return true
    }

    /// Returns true only when the requester references the stored owner and
    /// proves control of the corresponding signing key through its home vault.
    public func requesterProvesOwnership(_ requester: Identity) async -> Bool {
        guard identitiesReferenceSame(owner, requester) else {
            return false
        }
        return await checkIdentityOrigin(requester, against: owner)
    }

    /// Compatibility facade for hosts that predate the explicit runtime-binding API.
    /// This retains the same proof requirements as `bindStoredOwnerToRuntimeIdentity`.
    @available(*, deprecated, renamed: "bindStoredOwnerToRuntimeIdentity(_:)")
    @discardableResult
    public func restoreStoredOwnerIdentity(using candidate: Identity) async -> Bool {
        await bindStoredOwnerToRuntimeIdentity(candidate)
    }
    
    public init() async { // This should only be used while we are developing
        
        if let tmpOwner = await (CellBase.defaultIdentityVault?.identity(for: identityDomain, makeNewIfNotFound: true)) {
            self.owner = tmpOwner
        } else {
            owner = Identity()
        }
        self.agreementTemplate = Agreement(owner: owner)
        self.agreementAdmissionPolicy = .ownerApprovalRequired
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
        case agreementAdmissionPolicy
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
        case contracts
        case members
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
        
        agreementTemplate = try values.decode(Agreement.self, forKey: .contractTemplate)
        agreementAdmissionPolicy = try values.decodeIfPresent(
            AgreementAdmissionPolicy.self,
            forKey: .agreementAdmissionPolicy
        ) ?? .ownerApprovalRequired
        
        identityDomain = try values.decode(String.self, forKey: .identityDomain)
        self.cellScopeInternal = try values.decode(CellUsageScope.self, forKey: .cellScope)
        self.persistancy = try values.decode(Persistancy.self, forKey: .persistancy)
        self.persistedContracts = (try? values.decodeIfPresent([Contract].self, forKey: .contracts)) ?? []
        self.persistedMembers = (try? values.decodeIfPresent([Identity].self, forKey: .members)) ?? []
        
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
        try container.encode(agreementAdmissionPolicy, forKey: .agreementAdmissionPolicy)
        
        try? container.encode(feedProperties, forKey: .feedProperties)
        try container.encode(identityDomain, forKey: .identityDomain)
        try container.encode(self.owner, forKey: .owner)
        try container.encode(cellScopeInternal, forKey: .cellScope)
        try container.encode(persistancy, forKey: .persistancy)
        let authorization = persistedAuthorizationSnapshot()
        try container.encode(authorization.contracts, forKey: .contracts)
        try container.encode(authorization.members, forKey: .members)
        
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
        try await requireFlowLifecycleWriteAccess(label: label, requester: requester)
        try await ensureRuntimeReady()
        if let runtimeReadyEmitter = emitter as? CellRuntimeReady {
            try await runtimeReadyEmitter.ensureRuntimeReady()
        }
        let connectContext = ConnectContext(source: self, target: emitter, identity: requester)
        let connectState = await emitter.admit(context: connectContext )
        CellBase.diagnosticLog("attach label=\(label) connectState=\(connectState)", domain: .flow)
        let adjustedConnectState =  try await self.consumeConnectResponseForIdentity(connectState: connectState, label: label, identity: requester, emitCell: emitter)
        return adjustedConnectState
    }

    private func requireFlowLifecycleWriteAccess(
        label: String,
        requester: Identity
    ) async throws {
        let decision = await authorizationDecision(
            requestedAccess: "-w--",
            at: label,
            for: requester
        )
        guard decision.allowed else {
            throw CellAuthorizationError.denied(decision)
        }
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
                guard let requestData = try? JSONEncoder().encode(emitCell.agreementTemplate),
                      let contractRequest = try? JSONDecoder().decode(Agreement.self, from: requestData) else {
                    return .signContract
                }
                let contractState = try await emitCell.addAgreement(contractRequest, for: identity)
                if contractState == .signed {
                    adjustedConnectState = .connected
                    await auditor.removeAdmissionSessionForLabel(label)
                    await self.addEmitter(emitCell, for: label, requester: identity)
                } else if  contractState != .template {
                    adjustedConnectState = .signContract
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
        await auditor.connectEmitter(emitter, for: label)
    }
    
    private func processContractChallenge(context: ConnectContext, agreementTemplate: Agreement) async -> ContractChallengeEvaluation {
        var contractCondition = ContractCondition.unresolved
        var issues = [ContractChallengeIssue]()
        let agreement = agreementTemplate
        if context.identity != nil {
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
        try await requireFlowLifecycleWriteAccess(label: label, requester: requester)
        try await ensureRuntimeReady()
        switch await auditor.beginFlowSubscription(for: label) {
        case .ready(let subscriptionID, let emitCell, let subscriptionFlight):
            do {
                if let runtimeReadyEmitter = emitCell as? CellRuntimeReady {
                    try await runtimeReadyEmitter.ensureRuntimeReady()
                }
                guard await auditor.isFlowSubscriptionCurrent(
                    label: label,
                    id: subscriptionID,
                    emitterUUID: emitCell.uuid
                ) else {
                    throw CancellationError()
                }
                let subscribeFeedPublisher = try await emitCell.flow(requester: requester)
                guard await auditor.isFlowSubscriptionCurrent(
                    label: label,
                    id: subscriptionID,
                    emitterUUID: emitCell.uuid
                ) else {
                    throw CancellationError()
                }
                let (eventStream, eventContinuation) = AsyncStream.makeStream(
                    of: FlowSubscriptionEvent.self,
                    bufferingPolicy: .bufferingOldest(GeneralCell.flowEventBufferLimit)
                )
                let overflowState = FlowBufferOverflowState()
                let subscriptionAuditor = auditor
                let subscriptionIntercepts = intercepts
                let subscriptionFeedPublisher = feedPublisher
                let emitterUUID = emitCell.uuid
                let eventProcessor = Task { [weak subscriptionAuditor] in
                    do {
                        try await subscriptionFlight.wait()
                    } catch {
                        return
                    }
                    for await event in eventStream {
                        guard Task.isCancelled == false,
                              overflowState.didOverflow() == false else {
                            return
                        }
                        switch event {
                        case .value(let flowElement):
                            let transformedFlowElement: FlowElement?
                            if let intercept = await subscriptionIntercepts.loadFeedIntercept() {
                                transformedFlowElement = await intercept(flowElement, requester)
                            } else {
                                transformedFlowElement = flowElement
                            }
                            guard overflowState.didOverflow() == false else {
                                return
                            }
                            guard let transformedFlowElement else { continue }
                            guard let forwardReservation = await GeneralCell.reserveFlowElementForward(
                                auditor: subscriptionAuditor,
                                label: label,
                                id: subscriptionID,
                                emitterUUID: emitterUUID,
                                overflowState: overflowState
                            ) else {
                                return
                            }
                            if forwardReservation.shouldDeliver() {
                                subscriptionFeedPublisher.send(transformedFlowElement)
                            }
                            forwardReservation.finish()
                        case .completion:
                            guard let subscriptionAuditor else { return }
                            await subscriptionAuditor.completeFlowSubscription(
                                for: label,
                                id: subscriptionID,
                                emitterUUID: emitterUUID
                            )
                            return
                        }
                    }
                }
                let handleBufferOverflow: @Sendable () -> Void = { [weak subscriptionAuditor] in
                    guard overflowState.markOverflow() else { return }
                    eventContinuation.finish()
                    CellBase.diagnosticLog(
                        "flow event buffer overflow label=\(label) limit=\(GeneralCell.flowEventBufferLimit)",
                        domain: .flow
                    )
                    Task { [weak subscriptionAuditor] in
                        await subscriptionAuditor?.invalidateFlowSubscriptionAfterOverflow(
                            label: label,
                            id: subscriptionID,
                            emitterUUID: emitterUUID
                        )
                    }
                }
                let feedCancellable = subscribeFeedPublisher
                    .sink(receiveCompletion: { completion in
                        CellBase.diagnosticLog("feed completion label=\(label) completion=\(completion)", domain: .flow)
                        if case .dropped = eventContinuation.yield(.completion) {
                            handleBufferOverflow()
                        } else {
                            eventContinuation.finish()
                        }
                    }, receiveValue: { flowElement in
                        if case .dropped = eventContinuation.yield(.value(flowElement)) {
                            handleBufferOverflow()
                        }
                    })
                let installed = await auditor.installFlowSubscription(
                    for: label,
                    id: subscriptionID,
                    emitterUUID: emitCell.uuid,
                    subscribedFeed: subscribeFeedPublisher,
                    feedCancellable: feedCancellable,
                    eventProcessor: eventProcessor,
                    eventContinuation: eventContinuation,
                    overflowState: overflowState
                )
                guard installed else {
                    try await subscriptionFlight.wait()
                    throw CancellationError()
                }
            } catch {
                await auditor.cancelFlowSubscription(
                    for: label,
                    pendingID: subscriptionID,
                    pendingError: error
                )
                try await subscriptionFlight.wait()
                throw error
            }
        case .pending(let subscriptionFlight):
            try await subscriptionFlight.wait()
        case .active:
            CellBase.diagnosticLog("feed already active for label=\(label)", domain: .flow)
        case .noEmitter:
            CellBase.diagnosticLog("No emitter for label=\(label)", domain: .flow)
            throw GeneralCellErrors.noPublisherForLabel
        }
    }

    private static func reserveFlowElementForward(
        auditor: GeneralAuditor?,
        label: String,
        id: String,
        emitterUUID: String,
        overflowState: FlowBufferOverflowState
    ) async -> FlowForwardReservation? {
        guard let auditor else { return nil }
        return await auditor.reserveFlowElementForwardIfCurrent(
            label: label,
            id: id,
            emitterUUID: emitterUUID,
            overflowState: overflowState
        )
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
        try await ensureRuntimeReady()
        if await validateAccess("r---", at: "feed", for: requester) {
            CellBase.defaultCellResolver?.logAction(context: ConnectContext(source: nil, target: self, identity: requester), action: "feed", param: "nil")
            return feedPublisher.eraseToAnyPublisher()
        }
        throw StreamState.denied
    }
    
    open func admit(context: ConnectContext) async -> ConnectState {
        do {
            try await ensureRuntimeReady()
        } catch {
            CellBase.diagnosticLog(
                "Runtime binding preparation failed before admission: \(error)",
                domain: .lifecycle
            )
            return .denied
        }
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
        await addAgreement(agreement, for: identity, authorizedBy: identity)
    }

    public func addAgreement(
        _ agreement: Agreement,
        for identity: Identity,
        authorizedBy authority: Identity
    ) async -> AgreementState {
        do {
            try await ensureRuntimeReady()
        } catch {
            await recordContractRejected(
                identity: identity,
                reasonCode: "runtime_bindings_unavailable",
                message: "Contract admission requires initialized runtime bindings."
            )
            return .rejected
        }
        let context = ConnectContext(source: nil, target: self, identity: identity)
        guard await checkIdentityOrigin(identity, against: identity) else {
            await recordContractRejected(
                identity: identity,
                reasonCode: "contract_requester_proof_required",
                message: "Contract admission requires proof of the requester's signing key."
            )
            return .rejected
        }
        let authorityReferencesOwner = identitiesReferenceSame(owner, authority)
        let ownerAuthorized = authorityReferencesOwner
            ? await checkIdentityOrigin(authority, against: owner)
            : false
        guard let contractAgreement = agreementDerivedFromTemplate(
            request: agreement,
            subject: identity
        ) else {
            await recordContractRejected(
                identity: identity,
                reasonCode: "contract_request_outside_template",
                message: "Requested contract did not match the cell's current agreement template."
            )
            return .rejected
        }

        guard admissionPolicyAllows(
            contractAgreement,
            ownerAuthorized: ownerAuthorized
        ) else {
            await recordContractRejected(
                identity: identity,
                reasonCode: "contract_owner_approval_or_proof_required",
                message: "Contract admission requires explicit owner approval or an authorization-enforcing publication policy."
            )
            return .rejected
        }

        let conditionsResolved = await Self.$isEvaluatingAuthorizationConditions.withValue(true) {
            await allConditionsResolved(contractAgreement.conditions, context: context)
        }
        if conditionsResolved {
            do {
                let preferredSigningOwner = ownerAuthorized ? authority : owner
                guard let signingOwner = await contractSigningOwner(preferredOwner: preferredSigningOwner) else {
                    throw IdentityVaultError.wrongVault
                }
                contractAgreement.owner = signingOwner
                contractAgreement.signatories = [signingOwner, identity]
                let contract = try await Contract.signed(
                    agreement: contractAgreement,
                    issuer: signingOwner,
                    subject: identity,
                    domain: identityDomain
                )
                let persisted = persistedAuthorizationSnapshot()
                let authorization = await self.auditor.installAuthorization(
                    contract: contract,
                    member: identity,
                    restoring: persisted
                )
                applyPersistedAuthorizationSnapshot(authorization)
                return .signed
            } catch {
                CellBase.diagnosticLog("Signing contract failed: \(error)", domain: .contracts)
                await recordContractRejected(
                    identity: identity,
                    reasonCode: "contract_signing_failed",
                    message: "Contract signing failed."
                )
                return .rejected
            }
        } else {
            await recordContractRejected(
                identity: identity,
                reasonCode: "contract_conditions_unmet",
                message: "Contract conditions were not met."
            )
            return .rejected
        }
    }

    private func admissionPolicyAllows(
        _ agreement: Agreement,
        ownerAuthorized: Bool
    ) -> Bool {
        if ownerAuthorized {
            return true
        }
        switch agreementAdmissionPolicy {
        case .ownerApprovalRequired:
            return false
        case .automaticWhenConditionsMet:
            return agreement.conditions.contains(where: isAuthorizationEnforcingCondition)
        case .ownerPublishedRead:
            return agreement.grants.allSatisfy { $0.permission.fullPermissionString == "r-------" }
        }
    }

    func isAuthorizationEnforcingCondition(_ condition: any Condition) -> Bool {
        if let proved = condition as? ProvedClaimCondition {
            let credentialType = proved.requiredCredentialType?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let claimPath = proved.subjectClaimPath?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Automatic admission requires an explicit credential type and an
            // exact subject claim comparison. A generic trusted signature is
            // not authorization for an unrelated statement.
            return credentialType.isEmpty == false && claimPath.isEmpty == false
        }
        if let lookup = condition as? LookupCondition {
            let keypath = lookup.keypath.trimmingCharacters(in: .whitespacesAndNewlines)
            return keypath.hasPrefix("target.") || keypath.hasPrefix("resolve.")
        }
        return false
    }

    private func agreementDerivedFromTemplate(
        request: Agreement,
        subject: Identity
    ) -> Agreement? {
        guard identitiesReferenceSame(request.owner, owner),
              request.state == .template,
              request.duration > 0,
              request.duration <= agreementTemplate.duration,
              TimeInterval(request.duration) <= Contract.maximumDuration,
              !request.grants.isEmpty,
              request.grants.allSatisfy({ agreementTemplate.checkGrant(requestedGrant: $0) }),
              conditionsMatchTemplate(request.conditions, agreementTemplate.conditions) else {
            return nil
        }

        let derived = Agreement(owner: owner)
        derived.uuid = UUID().uuidString
        derived.name = agreementTemplate.name
        derived.state = .signed
        derived.owner = owner
        derived.signatories = [owner, subject]
        derived.conditions = agreementTemplate.conditions
        derived.grants = request.grants
        derived.duration = request.duration
        return derived
    }

    private func conditionsMatchTemplate(
        _ requested: [any Condition],
        _ template: [any Condition]
    ) -> Bool {
        if requested.isEmpty && template.isEmpty {
            return true
        }
        guard requested.count == template.count,
              let requestedData = canonicalConditionPolicyData(requested),
              let templateData = canonicalConditionPolicyData(template) else {
            return false
        }
        return requestedData == templateData
    }

    private func canonicalConditionPolicyData(_ conditions: [any Condition]) -> Data? {
        let policy = Agreement(owner: owner)
        policy.uuid = "condition-policy"
        policy.name = "condition-policy"
        policy.state = .template
        policy.owner = owner
        policy.signatories = []
        policy.conditions = conditions
        policy.grants = []
        policy.duration = 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(policy),
              var json = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var typedConditions = json["conditions"] as? [[String: Any]] else {
            return nil
        }
        for index in typedConditions.indices {
            guard var condition = typedConditions[index]["condition"] as? [String: Any] else {
                continue
            }
            condition.removeValue(forKey: "uuid")
            if var grant = condition["grant"] as? [String: Any] {
                grant.removeValue(forKey: "uuid")
                if var permission = grant["permission"] as? [String: Any] {
                    permission.removeValue(forKey: "uuid")
                    grant["permission"] = permission
                }
                condition["grant"] = grant
            }
            typedConditions[index]["condition"] = condition
        }
        json["conditions"] = typedConditions
        return try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private func contractSigningOwner(preferredOwner: Identity) async -> Identity? {
        if identitiesReferenceSame(owner, preferredOwner),
           await checkIdentityOrigin(preferredOwner, against: owner) {
            return preferredOwner
        }
        if await checkIdentityOrigin(owner, against: owner) {
            return owner
        }
        if let restoredOwner = await locallyRestoredOwner(),
           await checkIdentityOrigin(restoredOwner, against: owner) {
            return restoredOwner
        }
        return nil
    }

    private func locallyRestoredOwner() async -> Identity? {
        let candidateVaults = [owner.identityVault, CellBase.defaultIdentityVault].compactMap { $0 }
        for vault in candidateVaults {
            guard let candidate = await vault.identity(forUUID: owner.uuid),
                  identitiesReferenceSame(owner, candidate),
                  await vault.identityExistInVault(candidate) else {
                continue
            }
            return candidate
        }
        return nil
    }

    private func recordContractRejected(
        identity: Identity,
        reasonCode: String,
        message: String
    ) async {
        await CellBase.recordSecurityEvent(
            CellSecurityEvent(
                kind: .contractRejected,
                severity: .medium,
                resource: CellSecurityResource(
                    kind: "cell",
                    identifier: uuid,
                    action: "addAgreement"
                ),
                requester: CellSecurityActor(
                    identityUUID: identity.uuid,
                    signingKeyFingerprint: identity.signingPublicKeyFingerprint,
                    domain: identityDomain
                ),
                reasonCode: reasonCode,
                userMessage: message,
                requiredAction: "review_agreement_or_present_required_proof",
                canAutoResolve: false
            )
        )
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
    
    open func advertise(for identity: Identity) async throws -> AnyCell {
        try await ensureRuntimeReady()
        let manifest = try await self.exploreManifest(requester: identity)
        let template = try publicAgreementTemplateSnapshot()
        return AnyCell(
            uuid: self.uuid,
            name: "",
            contractTemplate: template,
            owner: self.owner.publicIdentitySnapshot(),
            experiences: nil,
            feedEndpoint: nil,
            feedProperties: nil,
            identityDomain: self.identityDomain,
            exploreManifest: manifest
        )
    }

    private func publicAgreementTemplateSnapshot() throws -> Agreement {
        try agreementTemplate.publicDescriptorSnapshot()
    }
    
    open func state(requester: Identity) async throws -> ValueType {
        try await ensureRuntimeReady()
        return .string("not implemented")
    }
    
    enum KeyValueErrors: Error {
        case notFound
        case denied
        case otherError
    }
    
    
    open func get(keypath: String, requester: Identity) async throws -> ValueType {
        try await ensureRuntimeReady()
        CellBase.defaultCellResolver?.logAction(context: ConnectContext(source: nil, target: self, identity: requester), action: "get", param: keypath)
        let resolvedKeyPath = keypath // will look for substitutions later?
        let operationAuthorizationDecision = try await explicitMeddleAuthorizationDecision(
            keypath: resolvedKeyPath,
            method: .get,
            requester: requester
        )
        if let operationAuthorizationDecision, !operationAuthorizationDecision.allowed {
            throw CellAuthorizationError.denied(operationAuthorizationDecision)
        }
        
        let keypathArray = resolvedKeyPath.split(separator: ".")
        let contextKey = String(keypathArray[0])
        let childKeypath = String(resolvedKeyPath.dropFirst("\(keypathArray[0]).".count))
        
        switch contextKey {
        case "isMember":
            let result = await isMember(uuid: childKeypath, requester: requester)
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
        
        let exactIntercept = await self.intercepts.loadInterceptGet(keypath: keypath)
        let rootValueIntercept = exactIntercept == nil
            ? await self.intercepts.loadInterceptValueForKey(key: contextKey)
            : nil
        let rootGetIntercept = exactIntercept == nil && rootValueIntercept == nil
            ? await self.intercepts.loadInterceptGet(keypath: contextKey)
            : nil
        let authorizationDecision: CellAuthorizationDecision
        if let operationAuthorizationDecision {
            authorizationDecision = operationAuthorizationDecision
        } else if exactIntercept != nil {
            authorizationDecision = await self.authorizationDecisionForDispatch(
                requestedAccess: "r---",
                exactKeypath: resolvedKeyPath,
                fallbackKeypath: contextKey,
                for: requester
            )
        } else {
            authorizationDecision = await self.authorizationDecision(
                requestedAccess: "r---",
                at: contextKey,
                for: requester
            )
        }
        if authorizationDecision.allowed {
            if let intercept = exactIntercept {
                CellBase.diagnosticLog("get intercept key=\(contextKey) keypath=\(keypath)", domain: .flow)
                return try await intercept(keypath, requester)
            } else if let intercept = rootValueIntercept {
                CellBase.diagnosticLog("get value intercept key=\(contextKey)", domain: .flow)
                return await intercept(requester)
            } else if let intercept = rootGetIntercept {
                CellBase.diagnosticLog("get nested intercept root=\(contextKey) keypath=\(keypath)", domain: .flow)
                let rootValue = try await intercept(contextKey, requester)
                return try resolveNestedValue(rootValue, childKeypath: childKeypath)
            } else {
                throw KeyValueErrors.notFound
            }
            
            
        }
        throw CellAuthorizationError.denied(authorizationDecision)
        
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
        try await ensureRuntimeReady()
        
        
        var response: ValueType?
        
        CellBase.defaultCellResolver?.logAction(context: ConnectContext(source: nil, target: self, identity: requester), action: "set", param: keypath)
            
            let resolvedKeyPath = keypath // will look for substitutions later?
            let operationAuthorizationDecision = try await explicitMeddleAuthorizationDecision(
                keypath: resolvedKeyPath,
                method: .set,
                requester: requester
            )
            if let operationAuthorizationDecision, !operationAuthorizationDecision.allowed {
                throw CellAuthorizationError.denied(operationAuthorizationDecision)
            }
            
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
                    
                  
                } else {
                    let exactIntercept = await self.intercepts.loadInterceptSet(keypath: keypath)
                    let rootSetIntercept = exactIntercept == nil
                        ? await self.intercepts.loadInterceptSet(keypath: contextKey)
                        : nil
                    let rootValueIntercept = exactIntercept == nil && rootSetIntercept == nil
                        ? await self.intercepts.loadInterceptSetValueForKey(key: contextKey)
                        : nil
                    let authorizationDecision: CellAuthorizationDecision
                    if let operationAuthorizationDecision {
                        authorizationDecision = operationAuthorizationDecision
                    } else if exactIntercept != nil {
                        authorizationDecision = await self.authorizationDecisionForDispatch(
                            requestedAccess: "-w--",
                            exactKeypath: resolvedKeyPath,
                            fallbackKeypath: contextKey,
                            for: requester
                        )
                    } else {
                        authorizationDecision = await self.authorizationDecision(
                            requestedAccess: "-w--",
                            at: contextKey,
                            for: requester
                        )
                    }
                    if authorizationDecision.allowed { // We need to look at this...
                            if let intercept = exactIntercept {
                                response = try await intercept(keypath, value, requester)
                            } else if let intercept = rootSetIntercept {
                                response = try await intercept(keypath, value, requester)
                            } else if let intercept = rootValueIntercept {
                                await intercept(value, requester) // Should this throw so we can send failure?
                            } else {
                                throw KeyValueErrors.notFound
                            }
                        
                        
                    } else {
                        
                        throw CellAuthorizationError.denied(authorizationDecision)
                    }
                }
                
            }
        
        return response
    }

    private func explicitMeddleAuthorizationDecision(
        keypath: String,
        method: ExploreContractMethod,
        requester: Identity
    ) async throws -> CellAuthorizationDecision? {
        guard let requirement = try await MeddleOperationAuthorizationRequirementResolver.resolve(
            target: self,
            keypath: keypath,
            method: method,
            requester: requester
        ) else {
            return nil
        }
        return await authorizationDecision(
            requestedAccess: requirement,
            at: keypath,
            for: requester
        )
    }

    public final func ensureRuntimeReady() async throws {
        try await runtimeReadinessCoordinator.ensure { [weak self] in
            guard let self else { return }
            let token = CellRuntimeBindingInstallationToken(cell: self)
            defer { token.invalidate() }
            try await Self.$runtimeBindingInstallationToken.withValue(token) {
                try await self.installCellRuntimeBindingsForAccess()
            }
        }
    }

    /// Subclasses with non-Codable intercepts, schemas, or runtime sources
    /// override this hook. `ensureRuntimeReady()` serializes installation and
    /// guarded Cell entrypoints await it before use.
    open func installCellRuntimeBindingsForAccess() async throws {
    }
    
    
    public func isMember(identity: Identity, requester: Identity) async -> Bool {
        guard await validateAccess("r---", at: "isMember", for: requester) else {
            return false
        }
        guard await authorizationMembers().contains(where: { identitiesReferenceSame($0, identity) }) else {
            return false
        }
        return await contractsForIdentity(identity).isEmpty == false
    }
    
    public func isMember(uuid: String, requester: Identity) async -> Bool {
        guard await validateAccess("r---", at: "isMember", for: requester) else {
            pushFlowElement(FlowElement(title: "201", content: .string("insufficient access for isMember"), properties: FlowElement.Properties( type: .alert, contentType: .string)), requester: requester)
            return false
        }
        guard requester.uuid == uuid else {
            return false
        }
        let isMember = await contractsForIdentity(requester).isEmpty == false
        CellBase.diagnosticLog("isMember uuid=\(uuid) result=\(isMember)", domain: .flow)
        return isMember
    }
    
    public func removeMember(member: Identity, requester: Identity) async {
        if await validateAccess("-w--", at: "members", for: requester) {
            await self.auditor.removeMember(member)
            let authorization = await self.auditor.removeAuthorization(
                subjectUUID: member.uuid,
                restoring: persistedAuthorizationSnapshot()
            )
            applyPersistedAuthorizationSnapshot(authorization)
        } else {
            pushFlowElement(FlowElement(title: "201", content: .string("insufficient access (w) for member"), properties: FlowElement.Properties( type: .alert, contentType: .string)), requester: requester)
        }
    }

    public func removeMember(uuid: String, requester: Identity) async {
        if await validateAccess("-w--", at: "members", for: requester) {
            await self.auditor.removeMember(uuid)
            let authorization = await self.auditor.removeAuthorization(
                subjectUUID: uuid,
                restoring: persistedAuthorizationSnapshot()
            )
            applyPersistedAuthorizationSnapshot(authorization)
        } else {
            pushFlowElement(FlowElement(title: "201", content: .string("insufficient access (w) for member"), properties: FlowElement.Properties( type: .alert, contentType: .string)), requester: requester)
        }
    }
    
    // Utility methods
    open func validateAccess(_ requestedAccess: String, at keypath: String, for identity: Identity) async -> Bool {
        await authorizationDecision(
            requestedAccess: requestedAccess,
            at: keypath,
            for: identity
        ).allowed
    }

    open func authorizationDecision(
        requestedAccess: String,
        at keypath: String,
        for identity: Identity
    ) async -> CellAuthorizationDecision {
        let decision = await authorizationDecisionWithoutRecording(
            requestedAccess: requestedAccess,
            at: keypath,
            for: identity
        )
        await recordSecurityEvent(for: decision)
        return decision
    }

    private func authorizationDecisionForDispatch(
        requestedAccess: String,
        exactKeypath: String,
        fallbackKeypath: String,
        for identity: Identity
    ) async -> CellAuthorizationDecision {
        let evidence = await authorizationEvidence(for: identity)
        let exactDecision = await authorizationDecisionWithoutRecording(
            requestedAccess: requestedAccess,
            at: exactKeypath,
            for: identity,
            evidence: evidence
        )
        if exactDecision.allowed || exactKeypath == fallbackKeypath {
            await recordSecurityEvent(for: exactDecision)
            return exactDecision
        }

        let fallbackDecision = await authorizationDecisionWithoutRecording(
            requestedAccess: requestedAccess,
            at: fallbackKeypath,
            for: identity,
            evidence: evidence
        )
        await recordSecurityEvent(for: fallbackDecision)
        return fallbackDecision
    }

    private func authorizationDecisionWithoutRecording(
        requestedAccess: String,
        at keypath: String,
        for identity: Identity
    ) async -> CellAuthorizationDecision {
        let evidence = await authorizationEvidence(for: identity)
        return await authorizationDecisionWithoutRecording(
            requestedAccess: requestedAccess,
            at: keypath,
            for: identity,
            evidence: evidence
        )
    }

    private struct AuthorizationEvidence {
        var ownerReferenceMatches: Bool
        var ownerProofValid: Bool
        var contracts: [Agreement]
    }

    private func authorizationEvidence(for identity: Identity) async -> AuthorizationEvidence {
        let ownerReferenceMatches = identitiesReferenceSame(owner, identity)
        let ownerProofValid = ownerReferenceMatches
            ? await checkIdentityOrigin(identity, against: owner)
            : false
        if ownerReferenceMatches && !ownerProofValid {
            print("General. Got owner identity but it failed to prove ownership!")
        }
        return AuthorizationEvidence(
            ownerReferenceMatches: ownerReferenceMatches,
            ownerProofValid: ownerProofValid,
            contracts: ownerReferenceMatches ? [] : await contractsForIdentity(identity)
        )
    }

    private func authorizationDecisionWithoutRecording(
        requestedAccess: String,
        at keypath: String,
        for identity: Identity,
        evidence: AuthorizationEvidence
    ) async -> CellAuthorizationDecision {
        let request = CellAuthorizationRequest(
            cellUUID: uuid,
            identityDomain: identityDomain,
            keypath: keypath,
            requestedAccess: requestedAccess,
            requester: identity
        )
        let cellSpecificAllowed = evidence.ownerReferenceMatches
            ? false
            : await validateCellSpecificAccess(requestedAccess, at: keypath, for: identity)

        return CellAuthorizationPolicy.decide(
            request: request,
            ownerReferenceMatches: evidence.ownerReferenceMatches,
            ownerUUIDMatches: owner.uuid == identity.uuid,
            ownerProofValid: evidence.ownerProofValid,
            contracts: evidence.contracts,
            cellSpecificAllowed: cellSpecificAllowed
        )
    }

    private func recordSecurityEvent(for decision: CellAuthorizationDecision) async {
        guard !decision.allowed else { return }
        await CellBase.recordSecurityEvent(.authorizationDenied(decision))
    }

    open func validateCellSpecificAccess(_ requestedAccess: String, at keypath: String, for identity: Identity) async -> Bool {
        false
    }

    private func authorizationContracts() async -> [Contract] {
        (await currentAuthorizationSnapshot()).contracts
    }

    private func currentAuthorizationSnapshot() async -> GeneralAuditor.AuthorizationSnapshot {
        let runtime = await auditor.authorizationSnapshot()
        if runtime.contracts.isEmpty && runtime.members.isEmpty {
            let persisted = persistedAuthorizationSnapshot()
            if persisted.contracts.isEmpty == false || persisted.members.isEmpty == false {
                let restored = await auditor.replaceAuthorization(
                    contracts: persisted.contracts,
                    members: persisted.members,
                    revision: persisted.revision
                )
                applyPersistedAuthorizationSnapshot(restored)
                return restored
            }
        }
        return runtime
    }

    private func persistedAuthorizationSnapshot() -> GeneralAuditor.AuthorizationSnapshot {
        persistedAuthorizationLock.lock()
        defer { persistedAuthorizationLock.unlock() }
        return (persistedAuthorizationRevision, persistedContracts, persistedMembers)
    }

    private func applyPersistedAuthorizationSnapshot(_ snapshot: GeneralAuditor.AuthorizationSnapshot) {
        persistedAuthorizationLock.lock()
        defer { persistedAuthorizationLock.unlock() }
        guard snapshot.revision >= persistedAuthorizationRevision else {
            return
        }
        persistedAuthorizationRevision = snapshot.revision
        persistedContracts = snapshot.contracts
        persistedMembers = snapshot.members
    }

    private func authorizationMembers() async -> [Identity] {
        (await currentAuthorizationSnapshot()).members
    }
    
    func contractsForIdentity(_ identity: Identity) async -> [Agreement] {
        guard !Self.isEvaluatingAuthorizationConditions else {
            return []
        }
        var relevantContracts = [Agreement]()
        for currentContract in await authorizationContracts() {
            guard await currentContract.verifyAuthorizationBinding(
                expectedIssuer: owner,
                expectedSubject: identity,
                expectedDomain: identityDomain
            ) else {
                continue
            }
            guard currentContract.agreement.grants.allSatisfy({ agreementTemplate.checkGrant(requestedGrant: $0) }),
                  conditionsMatchTemplate(currentContract.agreement.conditions, agreementTemplate.conditions),
                  currentContract.agreement.duration > 0,
                  currentContract.agreement.duration <= agreementTemplate.duration,
                  TimeInterval(currentContract.agreement.duration) <= Contract.maximumDuration else {
                continue
            }
            let conditionsResolved = await Self.$isEvaluatingAuthorizationConditions.withValue(true) {
                await allConditionsResolved(
                    currentContract.agreement.conditions,
                    context: ConnectContext(source: nil, target: self, identity: identity)
                )
            }
            guard conditionsResolved,
                  await checkIdentityOrigin(identity, against: currentContract.subject) else {
                continue
            }
            relevantContracts.append(currentContract.agreement)
        }
        return relevantContracts
    }

    /// Resolver admission for a known concrete Cell UUID. This only proves
    /// that the requester is a current Contract subject; operation-level
    /// authorization still evaluates the requested keypath and permission.
    func hasVerifiedAuthorizationContract(for identity: Identity) async -> Bool {
        await contractsForIdentity(identity).isEmpty == false
    }
    
    func determineIdentityState(identity: Identity) async -> IdentityState {
        var identityState = IdentityState.other
        if identitiesReferenceSame(owner, identity),
           await checkIdentityOrigin(identity, against: owner) {
            identityState = IdentityState.owner
        } else {
            
            let members = await authorizationMembers()
            let contained = members.contains { subMemberIdentity in
                return identitiesReferenceSame(subMemberIdentity, identity)
            }
            if contained,
               let trustedMember = members.first(where: { identitiesReferenceSame($0, identity) }),
               await checkIdentityOrigin(identity, against: trustedMember) {
                let activeContracts = await contractsForIdentity(identity)
                if activeContracts.isEmpty == false {
                    identityState = .member
                }
            }
        }
        return identityState
    }
    
    func checkIdentityOrigin(_ identity: Identity) async -> Bool {
        await checkIdentityOrigin(identity, against: identity)
    }

    /// Proves that the presented requester controls the private key matching
    /// its public identity descriptor. This exposes the existing origin check
    /// without exposing the trusted-identity overload to hosted cells.
    public func verifyRequesterIdentityControl(_ identity: Identity) async -> Bool {
        await checkIdentityOrigin(identity, against: identity)
    }

    func checkIdentityOrigin(_ identity: Identity, against trustedIdentity: Identity) async -> Bool {
        if CellBase.debugValidateAccessForEverything {return true}
        guard let identityVault = identity.identityVault else {
            Self.logMissingIdentityVaultOnce(for: identity)
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

        let challengeData: Data
        do {
            challengeData = try IdentitySigningChallenge.signingData(
                for: identity,
                trustedIdentity: trustedIdentity,
                domain: identityDomain,
                resource: uuid,
                action: "checkIdentityOrigin",
                audience: "GeneralCell",
                nonce: signData
            )
        } catch {
            print("Could not create identity signing challenge: \(error)")
            return false
        }

        guard let signedData = try? await identity.sign(data: challengeData) else {
            print("Got no signed data!")
            return false
        }
        return IdentityPublicKeySignatureVerifier.verify(
            signature: signedData,
            messageData: challengeData,
            identity: trustedIdentity
        )
    }

    private static func logMissingIdentityVaultOnce(for identity: Identity) {
        let uuid = identity.uuid
        missingIdentityVaultLogLock.lock()
        let shouldLog = missingIdentityVaultLoggedUUIDs.insert(uuid).inserted
        missingIdentityVaultLogLock.unlock()

        guard shouldLog else { return }
        CellBase.diagnosticLog("Identity \(uuid) had no identity vault", domain: .identity)
    }

    func identitiesReferenceSame(_ trustedIdentity: Identity, _ presentedIdentity: Identity) -> Bool {
        guard
            trustedIdentity.uuid == presentedIdentity.uuid,
            let trustedFingerprint = trustedIdentity.signingPublicKeyFingerprint,
            let presentedFingerprint = presentedIdentity.signingPublicKeyFingerprint
        else {
            return false
        }
        return trustedFingerprint == presentedFingerprint
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
        // Runtime binding installation is authorized by an active, instance-bound
        // token rather than by caller identity. This allows a freshly created Cell
        // with a public/unsigned owner descriptor to install its own handlers while
        // keeping every registration attempt outside that scope proof-gated.
        if Self.runtimeBindingInstallationToken?.authorizes(self) == true {
            return true
        }
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
        if operationSchemaDict[key]?[method] != nil {
            return .useExisting
        }

        let hasMethodlessLegacySchema: Bool
        if let legacyObject = ExploreContract.object(from: schemaDict[key]),
           let rawMethod = ExploreContract.string(from: legacyObject[ExploreContract.Field.method]) {
            hasMethodlessLegacySchema = ExploreContractMethod(rawValue: rawMethod) == nil
        } else {
            hasMethodlessLegacySchema = schemaDict[key] != nil
        }
        if hasMethodlessLegacySchema {
            switch CellBase.exploreContractEnforcementMode {
            case .permissive:
                return .useExisting
            case .warn:
                CellBase.diagnosticLog(
                    "Legacy method-less Explore schema for `\(key)` retained while installing the \(method.rawValue) handler. Migrate it to an explicit method contract before enabling strict mode.",
                    domain: .contracts
                )
                return .useExisting
            case .strict:
                break
            }
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
        Task { [weak self] in
            await self?.detachAndWait(label: label, requester: requester)
        }
    }

    /// Completes only after the connection and any subscribed feed have been
    /// removed from the auditor. Hosts that refresh UI state after disconnect
    /// must use this waitable form instead of racing the legacy fire-and-forget
    /// protocol requirement.
    public func detachAndWait(label: String, requester: Identity) async {
        guard await validateAccess("-w--", at: label, for: requester) else {
            CellBase.diagnosticLog("detach denied label=\(label)", domain: .flow)
            return
        }
        // The connection label is local to this Absorb Cell. The target's
        // resolver and transport lifetime may be shared by other hosts, so
        // detaching here must not unregister or close the target globally.
        await auditor.disconnectEmitter(for: label)
        let auditorState = await auditor.auditorState()
        CellBase.diagnosticLog("detach label=\(label) auditorState=\(auditorState)", domain: .flow)
    }
    
    public func dropFlow(label: String, requester: Identity)  {
        Task { [weak self] in
            await self?.dropFlowAndWait(label: label, requester: requester)
        }
    }

    /// Completes only after the subscription and its cancellable are removed.
    public func dropFlowAndWait(label: String, requester: Identity) async {
        guard await validateAccess("-w--", at: label, for: requester) else {
            CellBase.diagnosticLog("dropFlow denied label=\(label)", domain: .flow)
            return
        }
        await dropFlowLocally(label: label)
        let auditorState = await auditor.auditorState()
        CellBase.diagnosticLog("dropFlow label=\(label) auditorState=\(auditorState)", domain: .flow)
    }

    private func dropFlowLocally(label: String) async {
        await auditor.cancelFlowSubscription(for: label)
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

    /// Creates a synchronous Cell-owned publisher only while this exact Cell is
    /// installing runtime bindings (or when the requester proves owner
    /// control). The returned closure never accepts caller authority, so action
    /// grants remain separate from arbitrary feed-injection grants.
    @_spi(HAVENRuntime)
    public func makeCellOwnedFlowEmitterForRuntimeBinding(
        requester: Identity
    ) async -> ((FlowElement) -> Void)? {
        guard await isAllowedToSetupIntercepts(requester: requester) else {
            return nil
        }
        return { [weak self] flowElement in
            guard let self else { return }
            var ownedElement = flowElement
            ownedElement.origin = self.uuid
            self.feedPublisher.send(ownedElement)
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
        let cellIdentifier = ObjectIdentifier(self)
        let visitedCells = GeneralCell.attachedStatusTraversalVisitedCells
        guard visitedCells.contains(cellIdentifier) == false else {
            return []
        }
        var nextVisitedCells = visitedCells
        nextVisitedCells.insert(cellIdentifier)
        return try await GeneralCell.$attachedStatusTraversalVisitedCells.withValue(nextVisitedCells) {
            try await collectAttachedStatuses(requester: requester)
        }
    }

    private func collectAttachedStatuses(requester: Identity) async throws -> [ConnectionStatus] {
        let attachedLabels = await self.connectedLabels(requester: requester)
        var attachedStatuses = [ConnectionStatus]()
        for currentLabel in attachedLabels {
            if let currentAbsorb = await getEmitterWithLabel(currentLabel, requester: requester) as? Absorb {
                let childStatuses = try await currentAbsorb.attachedStatuses(requester: requester)
                for currentChildStatus in childStatuses {
                    let childStatus = ConnectionStatus(name: "\(currentLabel).\(currentChildStatus.name)", connected: currentChildStatus.connected, active: currentChildStatus.active)
                    attachedStatuses.append(childStatus)
                }
            }
            // Every connected emitter has a local status. Nested Absorb
            // emitters additionally contribute child statuses above, but a
            // leaf Emit must not disappear from host connection UIs.
            let status = try await attachedStatus(for: currentLabel, requester: requester)
            attachedStatuses.append(status)
        }
        return attachedStatuses.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            if lhs.connected != rhs.connected { return lhs.connected == false }
            return lhs.active == false && rhs.active
        }
    }
    
    private func register(key: String, schema: ValueType, description: ValueType) {
        let normalizedSchema = ExploreContract.normalizeSchema(
            key: key,
            schema: schema,
            description: description
        )
        self.schemaDict[key] = normalizedSchema
        self.schemaDescriptionDict[key] = description
        if let object = ExploreContract.object(from: normalizedSchema),
           let rawMethod = ExploreContract.string(from: object[ExploreContract.Field.method]),
           let method = ExploreContractMethod(rawValue: rawMethod) {
            operationSchemaDict[key, default: [:]][method] = normalizedSchema
        }
    }
}

extension GeneralCell: ExploreOperationContractProviding {}
