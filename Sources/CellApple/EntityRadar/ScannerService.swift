// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  ConnectService.swift
//  AbbottTesting
//
//  Created by Kjetil Hustveit on 13/10/2020.
//

import Foundation
import MultipeerConnectivity
#if os(iOS)
import NearbyInteraction
#endif

#if canImport(UIKit)
import UIKit
#endif

//#if canImport(Combine)
//import Combine
//#else
//import OpenCombine
//#endif
#if os(Linux)
import OpenCombine
#else
import Combine
#endif
import CellBase

protocol ConnectServiceDelegate {

    func connectedDevicesChanged(manager : ScannerService, connectedDevices: [String])
//    func colorChanged(manager : ConnectService, colorString: String)
//    func foundDevicesChanged(manager: RadarService, foundDevices: [String])

    func foundDevicesChanged(
        manager: ScannerService,
        foundDevice: MCPeerID,
        remoteUUID: String,
        discoveryInfo: [String: String]?
    )
    func lostDeviceChanged(manager: ScannerService, lostDevice: MCPeerID, remoteUUID: String)
    func invitationReceived(manager: ScannerService, peerID: MCPeerID, remoteUUID: String)
    func scannerStatusChanged(manager: ScannerService, status: String, remoteUUID: String?)
    func proximityChanged(
        manager: ScannerService,
        remoteUUID: String,
        distanceMeters: Float?,
        directionX: Float?,
        directionY: Float?,
        directionZ: Float?
    )
    func scannerFlowReceived(manager: ScannerService, flowElement: FlowElement, remoteUUID: String?)
}

private enum ScannerServiceError: Error {
    case peerNotConnected(String)
    case noConnectedPeers
    case invalidCommand(String)
}

final class ScannerPeerTransport: BridgeTransportProtocol {
    private weak var service: ScannerService?
    private let remoteUUID: String
    fileprivate let setupID: UUID
    private weak var delegate: BridgeDelegateProtocol?
    var gate: BridgeChannelTransport!
    var bridge: BridgeBase?
    var channelSession: BridgeChannelSession? { gate?.session }

    init(service: ScannerService, remoteUUID: String, setupID: UUID) {
        self.service = service
        self.remoteUUID = remoteUUID
        self.setupID = setupID
    }

    func setDelegate(_ delegate: BridgeDelegateProtocol) {
        self.delegate = delegate
        service?.setBridgeDelegate(delegate, for: remoteUUID, setupID: setupID)
    }

    func setup(_ endpointURL: URL, identity: Identity) async throws {}

    func sendData(_ data: Data) async throws {
        guard let service else { throw ScannerServiceError.peerNotConnected(remoteUUID) }
        try service.sendPeerData(data, remoteUUID: remoteUUID, setupID: setupID)
    }

    func identityVault(for identity: Identity?) async -> any IdentityVaultProtocol {
        guard let service else { return BridgeIdentityVault(cloudBridge: delegate as? BridgeProtocol) }
        return await service.identityVault(for: identity, bridgeDelegate: delegate)
    }

    func close() async { service?.peerChannelClosed(remoteUUID: remoteUUID, setupID: setupID) }

    static func new() -> any BridgeTransportProtocol {
        preconditionFailure("Radar transport must be obtained from a running ScannerService, not constructed.")
    }
}

// Consider different name
class ScannerService :  NSObject, ObservableObject {

    @MainActor var advertisementExchange: NearbyAdvertisementExchange?
    private var advertisementPeers: Set<String> = [] // Accessed on stateQueue.
    private var advertisementProofPeers: Set<String> = []

    func readAdvertisement(remoteUUID: String) async -> NearbyAdvertisement? {
        guard let peer = withState({ advertisementPeers.contains(remoteUUID) ? _foundPeersDict[remoteUUID] : nil }) else { return nil }
        return await advertisementExchange?.read(peer: peer, localPeer: myPeerId, browser: serviceBrowser)
    }

    func readAdvertisementResult(remoteUUID: String, evidence: NearbyAccessEvidence? = nil,
                                 consentedPolicy: String? = nil) async -> NearbyAdvertisementReadResult {
        guard let peer = withState({ advertisementPeers.contains(remoteUUID) ? _foundPeersDict[remoteUUID] : nil }) else { return .unavailable }
        if withState({ advertisementProofPeers.contains(remoteUUID) }) {
            return await advertisementExchange?.readWithProof(peer: peer, localPeer: myPeerId,
                localID: mySessionUUID, remoteID: remoteUUID, browser: serviceBrowser,
                reader: owner, evidence: evidence, consentedPolicy: consentedPolicy) ?? .unavailable
        }
        guard evidence == nil else { return .unavailable }
        return .init(advertisement: await readAdvertisement(remoteUUID: remoteUUID), message: "Ingen tilgjengelige annonserte detaljer.")
    }

    private struct PendingInvitation {
        let id: UUID
        let handler: (Bool, MCSession?) -> Void
        let timeout: DispatchWorkItem
        let endpoint: BridgePeerChannelAuthentication.Endpoint?
    }

    private final class BridgeSetupOperation {
        let id: UUID
        let task: Task<Void, Error>

        init(id: UUID, task: Task<Void, Error>) {
            self.id = id
            self.task = task
        }
    }

    private static let maximumPeerDisplayNameUTF8Bytes = 63

    /// `MCPeerID` raises an Objective-C exception, rather than returning an
    /// error, when its display name is empty or exceeds 63 UTF-8 bytes. Keep
    /// arbitrary identity profile names outside that crash boundary. An empty
    /// profile name uses a non-identifying product label; session discovery
    /// metadata remains responsible for transport correlation.
    static func peerDisplayName(displayName: String) -> String {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmedDisplayName.isEmpty ? "HAVEN" : trimmedDisplayName

        var normalized = ""
        var utf8ByteCount = 0
        for character in candidate {
            let characterByteCount = String(character).utf8.count
            guard utf8ByteCount + characterByteCount <= maximumPeerDisplayNameUTF8Bytes else {
                break
            }
            normalized.append(character)
            utf8ByteCount += characterByteCount
        }

        return normalized.isEmpty ? "HAVEN" : normalized
    }

    /// Multipeer peer names are visible on the local network before a HAVEN
    /// identity has been verified. Use a rotating, session-scoped label rather
    /// than the owner's profile name. The session UUID remains transport
    /// correlation only and never grants authority.
    static func privatePeerDisplayName(sessionUUID: String) -> String {
        let suffix = sessionUUID
            .filter { $0.isLetter || $0.isNumber }
            .prefix(8)
            .lowercased()
        guard suffix.isEmpty == false else {
            return "HAVEN"
        }
        return peerDisplayName(displayName: "HAVEN-\(suffix)")
    }

    static func validateInboundBridgeData(_ data: Data) throws {
        try BridgeInboundPayloadValidator().validate(data)
    }

    static var platformSupportsNearbyPrecision: Bool {
#if os(iOS)
        NISession.isSupported
#else
        false
#endif
    }

    
    @Published var connectedPeerIdDisplayname: String? = nil
    @Published var connectedDevices: [String]? = nil
    @Published var discoveredDevices: [String]? = nil
//    @Published var rolename: String = "N/A"
//    @Published var entity: Entity?
    
    @Published var remoteRolename: String = "N/A"
    @Published var remoteEntity: Entity?
        
    
    private var connectedPublisher = PassthroughSubject<Bool, Error>()
    private var connected = false

    private let stateQueue = DispatchQueue(label: "haven.scanner.state")
    private let stateQueueKey = DispatchSpecificKey<Void>()
    
    var owner: Identity
    
    private var _foundPeersDict = Dictionary<String, MCPeerID>()
    private var _reversedFoundPeersDict = Dictionary<MCPeerID, String>()

    var foundPeersDict: [String: MCPeerID] {
        get { withState { _foundPeersDict } }
        set { withState { _foundPeersDict = newValue } }
    }

    var reversedFoundPeersDict: [MCPeerID: String] {
        get { withState { _reversedFoundPeersDict } }
        set { withState { _reversedFoundPeersDict = newValue } }
    }
    
    // Test
    private var _connectedPeersDict = Dictionary<MCPeerID, Identity>()
    private var _reversedConnectedPeersDict = Dictionary<String, MCPeerID>() // Identity.uuid, PeerID

    var connectedPeersDict: [MCPeerID: Identity] {
        get { withState { _connectedPeersDict } }
        set { withState { _connectedPeersDict = newValue } }
    }

    var reversedConnectedPeersDict: [String: MCPeerID] {
        get { withState { _reversedConnectedPeersDict } }
        set { withState { _reversedConnectedPeersDict = newValue } }
    }
    
    // Service type must be a unique string, at most 15 characters long
    // and can contain only ASCII lowercase letters, numbers and hyphens.
    private let HavenServiceType = "haven-radar"

    
    private let myPeerId: MCPeerID
    private let serviceAdvertiser : MCNearbyServiceAdvertiser
    private let serviceBrowser : MCNearbyServiceBrowser

    private var invitedRemoteUUIDs = Set<String>()
    private var invitationEndpoints = [String: BridgePeerChannelAuthentication.Endpoint]()
    private static let peerLimits = BridgeChannelLimits()
    var channelLimits = ScannerService.peerLimits
    // Internal adapter seam: production always uses MCSession reliable delivery.
    var peerSend: ((Data, String) throws -> Void)?
    var radarDelegate : ConnectServiceDelegate?
    private var bridgeDelegatesByRemoteUUID = [String: BridgeDelegateProtocol]()
    private var bridgeTransportsByRemoteUUID = [String: ScannerPeerTransport]()
    private var registeredBridgeUUIDsByRemoteUUID = [String: String]()
    private var bridgeSetupTasks = [String: BridgeSetupOperation]()
    private var pendingInvitations = [MCPeerID: PendingInvitation]()
    private let invitationTimeout: TimeInterval

    let mySessionUUID: String

    var transportMode: String {
        "multipeerconnectivity"
    }

    var supportsNearbyPrecision: Bool {
        Self.platformSupportsNearbyPrecision
    }

    var precisionMode: String {
        supportsNearbyPrecision ? "uwb" : "multipeer-only"
    }

    var precisionDescription: String {
        if supportsNearbyPrecision {
            return "NearbyInteraction precision is available for this peer session"
        }
        return "Fallback to Multipeer Connectivity; discovery and signed contact exchange still work without UWB"
    }
    
#if os(iOS)
    var niSession: NISession?
    var peerDiscoveryToken: NIDiscoveryToken?
    var sharedTokenWithPeer = false
#else
    // NearbyInteraction unavailable on this platform
    var niSession: Any? = nil
    var peerDiscoveryToken: Any? = nil
    var sharedTokenWithPeer = false
#endif
    
#if canImport(UIKit)
    let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
#else
    // UIKit haptics unavailable on this platform
    let impactGenerator: Any? = nil
#endif

//    var currentDistanceDirectionState: DistanceDirectionState = .unknown
//    var mpc: MPCSession?
    private var _connectedPeer: MCPeerID?
    private var _connectedRemoteUUID: String?

    var connectedPeer: MCPeerID? {
        get { withState { _connectedPeer } }
        set { withState { _connectedPeer = newValue } }
    }

    var connectedRemoteUUID: String? {
        get { withState { _connectedRemoteUUID } }
        set { withState { _connectedRemoteUUID = newValue } }
    }
    
    private var storedMCSession: MCSession?
    var mcSession: MCSession {
        withState {
            if let session = storedMCSession { return session }
            let session = MCSession(peer: myPeerId, securityIdentity: nil, encryptionPreference: .required)
            session.delegate = self
            storedMCSession = session
            return session
        }
    }

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return try body()
        }
        return try stateQueue.sync(execute: body)
    }

    func capabilitySnapshot() -> Object {
        [
            "transportMode": .string(transportMode),
            "supportsMultipeerConnectivity": .bool(true),
            "supportsNearbyPrecision": .bool(supportsNearbyPrecision),
            "precisionMode": .string(precisionMode),
            "description": .string(precisionDescription),
            "sessionUUID": .string(mySessionUUID)
        ]
    }

    func invitePeer(_ remoteUUID: String) {
        let normalizedUUID = remoteUUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let peerID = withState({ () -> MCPeerID? in
            guard let peerID = _foundPeersDict[normalizedUUID] else { return nil }
            return peerID
        }) else {
            print("Could not invite peer. Unknown remote UUID: \(normalizedUUID)")
            return
        }
        print("Inviting peer with remote UUID: \(normalizedUUID)")
        do {
            let endpoint = try makeInvitation(remoteUUID: normalizedUUID)
            self.serviceBrowser.invitePeer(peerID, to: self.mcSession, withContext: try BridgeChannelAuthentication.encode(endpoint), timeout: 10)
        } catch { reportBridgeFailure(error, remoteUUID: normalizedUUID) }
    }

    func makeInvitation(remoteUUID: String) throws -> BridgePeerChannelAuthentication.Endpoint {
        let endpoint = try BridgePeerChannelAuthentication.Endpoint(initiator: mySessionUUID, responder: remoteUUID,
            setupID: UUID().uuidString, domain: "nearby")
        try withState {
            guard _foundPeersDict[remoteUUID] != nil, bridgeTransportsByRemoteUUID[remoteUUID] == nil else { throw BridgeChannelAuthentication.Failure.unexpectedMessage }
            invitedRemoteUUIDs.insert(remoteUUID)
            invitationEndpoints[remoteUUID] = endpoint
        }
        return endpoint
    }

    func isConnected(remoteUUID: String) -> Bool {
        guard let peerID = withState({ _foundPeersDict[remoteUUID] }) else { return false }
        return mcSession.connectedPeers.contains(peerID)
    }

    func sendScannerFlowElement(_ flowElement: FlowElement, remoteUUID: String? = nil) async throws {
        let bridgeCommand = BridgeCommand(cmd: "response", payload: .flowElement(flowElement), cid: -2)
        let encodedElement = try JSONEncoder().encode(bridgeCommand)
        let transports = withState { remoteUUID.map { bridgeTransportsByRemoteUUID[$0].map { [$0] } ?? [] } ?? Array(bridgeTransportsByRemoteUUID.values) }
        guard !transports.isEmpty else { throw ScannerServiceError.noConnectedPeers }
        for transport in transports { try await transport.gate.sendData(encodedElement) }
    }

    fileprivate func sendPeerData(_ data: Data, remoteUUID: String, setupID: UUID) throws {
        try withState {
            guard bridgeTransportsByRemoteUUID[remoteUUID]?.setupID == setupID else { throw CancellationError() }
            if let peerSend { try peerSend(data, remoteUUID) }
            else { try sendMultipeerData(data, remoteUUID: remoteUUID) }
        }
    }
    fileprivate func peerChannelClosed(remoteUUID: String, setupID: UUID) {
        guard withState({ bridgeTransportsByRemoteUUID[remoteUUID]?.setupID == setupID }) else { return }
        removeBridge(for: remoteUUID)
        reportBridgeFailure(BridgeChannelAuthentication.Failure.closed, remoteUUID: remoteUUID)
    }
    private func reportBridgeFailure(_ error: Error, remoteUUID: String?) {
        radarDelegate?.scannerStatusChanged(manager: self, status: "bridgeFailed:\(error)", remoteUUID: remoteUUID)
    }
    fileprivate func sendMultipeerData(_ data: Data, remoteUUID: String? = nil) throws {
        if let remoteUUID {
            guard let peerID = withState({ _foundPeersDict[remoteUUID] }),
                  mcSession.connectedPeers.contains(peerID) else {
                throw ScannerServiceError.peerNotConnected(remoteUUID)
            }
            try mcSession.send(data, toPeers: [peerID], with: .reliable)
            return
        }
        guard mcSession.connectedPeers.isEmpty == false else {
            throw ScannerServiceError.noConnectedPeers
        }
        try mcSession.send(data, toPeers: mcSession.connectedPeers, with: .reliable)
    }

    func disconnect() {
        mcSession.disconnect()
        // cleanup
    }

    init(
        owner: Identity,
        serviceDicoveryInfoDict: [String: String] = ["v": NearbyBeacon.currentVersion, "k": "u"],
        invitationTimeout: TimeInterval = 30,
        sessionUUID: String? = nil
    ) {
        let resolvedSessionUUID = sessionUUID ?? UUID().uuidString
        mySessionUUID = resolvedSessionUUID
        myPeerId = MCPeerID(displayName: Self.privatePeerDisplayName(sessionUUID: resolvedSessionUUID))
        
        self.owner = owner
        self.invitationTimeout = invitationTimeout
        
        var serviceDicoveryInfo = serviceDicoveryInfoDict
        serviceDicoveryInfo["uuid"] = mySessionUUID
        serviceDicoveryInfo["ad"] = "1" // Preserve public-read discovery for older clients.
        serviceDicoveryInfo["adp"] = "2" // Proof capability only; no chosen details in discovery metadata.
        
        self.serviceAdvertiser = MCNearbyServiceAdvertiser(peer: myPeerId, discoveryInfo: serviceDicoveryInfo, serviceType: HavenServiceType)
        self.serviceBrowser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: HavenServiceType)

        super.init()

        stateQueue.setSpecific(key: stateQueueKey, value: ())

        self.serviceAdvertiser.delegate = self
        self.serviceBrowser.delegate = self
        print("Inited radar service with peerId: \(myPeerId)")
    }

    deinit {
        stop()
    }

    func start() {
        print("@@@@@ start")
        self.serviceAdvertiser.startAdvertisingPeer()
        self.serviceBrowser.startBrowsingForPeers()
        radarDelegate?.scannerStatusChanged(manager: self, status: "started", remoteUUID: nil)
//       startup()
    }
    
    
    func stop() {
        self.serviceAdvertiser.stopAdvertisingPeer()
        self.serviceBrowser.stopBrowsingForPeers()
        // Deinitializing an unstarted service must not create a session whose
        // weak delegate is already in deinit.
        withState { storedMCSession }?.disconnect()
        rejectAllPendingInvitations()
        connectedRemoteUUID = nil
        connectedPeer = nil
        let remotes = withState { Set(bridgeTransportsByRemoteUUID.keys).union(bridgeSetupTasks.keys).union(registeredBridgeUUIDsByRemoteUUID.keys) }
        for remote in remotes { removeBridge(for: remote) }
        withState {
            invitedRemoteUUIDs.removeAll(); invitationEndpoints.removeAll()
            _foundPeersDict.removeAll(); _reversedFoundPeersDict.removeAll()
            advertisementPeers.removeAll(); advertisementProofPeers.removeAll()
            _connectedPeersDict.removeAll(); _reversedConnectedPeersDict.removeAll()
        }
        radarDelegate?.scannerStatusChanged(manager: self, status: "stopped", remoteUUID: nil)
    }

    var pendingInvitationCount: Int { withState { pendingInvitations.count } }

    /// Number of per-peer bridge delegates currently held. There is no global
    /// bridge delegate any more: each peer owns its own, so the vault can never
    /// be derived from another peer's bridge.
    var bridgeDelegateCount: Int { withState { bridgeDelegatesByRemoteUUID.count } }

    @discardableResult
    func respondToInvitation(remoteUUID: String, accept: Bool) -> Bool {
        guard let pending = withState({ () -> PendingInvitation? in
            guard let peerID = _foundPeersDict[remoteUUID] else { return nil }
            return pendingInvitations.removeValue(forKey: peerID)
        }) else {
            return false
        }
        pending.timeout.cancel()
        if accept, let endpoint = pending.endpoint { withState { invitationEndpoints[remoteUUID] = endpoint } }
        pending.handler(accept, accept ? mcSession : nil)
        if !accept {
            radarDelegate?.scannerStatusChanged(manager: self, status: "invitationRejected", remoteUUID: remoteUUID)
        }
        return true
    }

    private func queueInvitation(
        from peerID: MCPeerID,
        remoteUUID: String,
        endpoint: BridgePeerChannelAuthentication.Endpoint?,
        handler: @escaping (Bool, MCSession?) -> Void
    ) {
        let invitationID = UUID()
        let timeout = DispatchWorkItem { [weak self, weak peerID] in
            guard let self, let peerID else { return }
            self.expireInvitation(id: invitationID, from: peerID, remoteUUID: remoteUUID)
        }
        let existing = withState {
            let existing = pendingInvitations.removeValue(forKey: peerID)
            pendingInvitations[peerID] = PendingInvitation(
                id: invitationID,
                handler: handler,
                timeout: timeout,
                endpoint: endpoint
            )
            return existing
        }
        if let existing {
            existing.timeout.cancel()
            existing.handler(false, nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + invitationTimeout, execute: timeout)
        radarDelegate?.invitationReceived(manager: self, peerID: peerID, remoteUUID: remoteUUID)
    }

    private func expireInvitation(id: UUID, from peerID: MCPeerID, remoteUUID: String) {
        guard let expired = withState({ () -> PendingInvitation? in
            guard pendingInvitations[peerID]?.id == id else { return nil }
            return pendingInvitations.removeValue(forKey: peerID)
        }) else {
            return
        }
        expired.handler(false, nil)
        radarDelegate?.scannerStatusChanged(
            manager: self,
            status: "invitationExpired",
            remoteUUID: remoteUUID
        )
    }

    private func rejectAllPendingInvitations() {
        let invitations = withState { () -> [PendingInvitation] in
            let invitations = Array(pendingInvitations.values)
            pendingInvitations.removeAll()
            return invitations
        }
        for invitation in invitations {
            invitation.timeout.cancel()
            invitation.handler(false, nil)
        }
    }

    func receiveInvitation(
        from peerID: MCPeerID,
        endpoint: BridgePeerChannelAuthentication.Endpoint? = nil,
        handler: @escaping (Bool, MCSession?) -> Void
    ) {
        guard let remoteUUID = withState({ _reversedFoundPeersDict[peerID] }) else {
            print("Rejecting invitation from unknown peer: \(peerID.displayName)")
            handler(false, nil)
            return
        }
        if let endpoint {
            guard withState({ bridgeTransportsByRemoteUUID[remoteUUID] == nil }) else { handler(false, nil); return }
            guard endpoint.initiator == remoteUUID, endpoint.responder == mySessionUUID, endpoint.domain == "nearby" else {
                handler(false, nil); return
            }
            // Resolve crossed invitations deterministically without creating two channels.
            let keepOutgoing = withState { invitationEndpoints[remoteUUID] != nil && mySessionUUID < remoteUUID }
            if keepOutgoing { handler(false, nil); return }
            withState { invitedRemoteUUIDs.remove(remoteUUID); invitationEndpoints[remoteUUID] = nil }
        }
        queueInvitation(from: peerID, remoteUUID: remoteUUID, endpoint: endpoint, handler: handler)
    }
    
    @discardableResult
    func prepareBridge(remoteUUID: String, peerID: MCPeerID) throws -> ScannerPeerTransport {
        try withState {
            guard _foundPeersDict[remoteUUID] == peerID, _reversedFoundPeersDict[peerID] == remoteUUID,
                  let endpoint = invitationEndpoints[remoteUUID] else { throw BridgeChannelAuthentication.Failure.unavailable }
            if let current = bridgeTransportsByRemoteUUID[remoteUUID] { return current }
            let physical = ScannerPeerTransport(service: self, remoteUUID: remoteUUID, setupID: UUID())
            bridgeTransportsByRemoteUUID[remoteUUID] = physical
            do {
                physical.gate = try BridgeChannelTransport(underlying: physical, peerEndpoint: endpoint,
                    role: endpoint.initiator == mySessionUUID ? .initiator : .responder,
                    owner: owner, limits: channelLimits, source: remoteUUID) { [weak self, weak physical] transport, _ in
                        guard let self, let physical else { throw CancellationError() }
                        try self.checkCurrent(physical, remoteUUID: remoteUUID)
                        let config = BridgeBase.Config(owner: self.owner, identityDomain: "nearby", transport: transport)
                        let bridge = try await BridgeBase(config)
                        try await bridge.setTransport(transport, connection: endpoint.initiator == self.mySessionUUID ? .inbound(publisherUuid: "Lobby") : .outbound)
                        try self.checkCurrent(physical, remoteUUID: remoteUUID)
                        physical.bridge = bridge
                        return bridge
                    }
                return physical
            } catch { bridgeTransportsByRemoteUUID[remoteUUID] = nil; bridgeDelegatesByRemoteUUID[remoteUUID] = nil; throw error }
        }
    }
    private func checkCurrent(_ transport: ScannerPeerTransport, remoteUUID: String) throws {
        try Task.checkCancellation()
        try withState {
            guard bridgeTransportsByRemoteUUID[remoteUUID] === transport else { throw CancellationError() }
        }
        try transport.gate.session.check()
    }
    func setupBridge(remoteUUID: String, peerID: MCPeerID) async throws {
        let physical = try prepareBridge(remoteUUID: remoteUUID, peerID: peerID)
        // A prior setup/registration must finish its cleanup before the same
        // remote cell UUID can be registered by a new generation.
        while let previous = withState({ bridgeSetupTasks[remoteUUID] }), previous.id != physical.setupID {
            _ = try? await previous.task.value
            withState { if bridgeSetupTasks[remoteUUID] === previous { bridgeSetupTasks[remoteUUID] = nil } }
            try Task.checkCancellation()
            guard withState({ bridgeTransportsByRemoteUUID[remoteUUID] === physical }) else { throw CancellationError() }
        }
        let operation = withState { () -> BridgeSetupOperation? in
            if let existingOperation = bridgeSetupTasks[remoteUUID] {
                return existingOperation
            }
            if registeredBridgeUUIDsByRemoteUUID[remoteUUID] != nil {
                return nil
            }

            let setupID = physical.setupID
            let task = Task { [weak self] in
                guard let self else { return }
                try await self.performBridgeSetup(
                    remoteUUID: remoteUUID,
                    peerID: peerID,
                    setupID: setupID
                )
            }
            let operation = BridgeSetupOperation(id: setupID, task: task)
            bridgeSetupTasks[remoteUUID] = operation
            return operation
        }
        guard let operation else { return }

        defer {
            withState {
                if bridgeSetupTasks[remoteUUID] === operation {
                    bridgeSetupTasks[remoteUUID] = nil
                }
            }
        }
        do {
            try await withTaskCancellationHandler(operation: { try await operation.task.value }, onCancel: {
                operation.task.cancel()
                Task { await physical.gate.close() }
            })
        }
        catch { await physical.gate.close(); reportBridgeFailure(error, remoteUUID: remoteUUID); throw error }
    }

    private func performBridgeSetup(remoteUUID: String, peerID: MCPeerID, setupID: UUID) async throws {
        guard let peerTransport = withState({ bridgeTransportsByRemoteUUID[remoteUUID] }), peerTransport.setupID == setupID else { throw CancellationError() }
        try await peerTransport.gate.startPeer()
        try checkCurrent(peerTransport, remoteUUID: remoteUUID)
        try await peerTransport.gate.withAuthenticatedWork {
            guard let resolver = CellBase.defaultCellResolver else { throw CellBaseError.noResolver }
            guard let cellBridge = peerTransport.bridge else { throw BridgeChannelAuthentication.Failure.unavailable }
            let wasInvited = self.withState {
                self._connectedPeersDict[peerID] = peerTransport.gate.session.publicIdentity?.makeIdentity()
                self._reversedConnectedPeersDict[remoteUUID] = peerID
                return self.invitedRemoteUUIDs.contains(remoteUUID)
            }

            var registeredUUID: String?
            do {
                if wasInvited {
                    try await self.attachLobbyToEntityScanner(requester: self.owner)
                } else {
                    try await cellBridge.retrieveProxyRepresentation(for: self.owner)
                    let connectRadarCell = try await resolver.cellAtEndpoint(
                        endpoint: "cell:///ConnectRadar",
                        requester: self.owner
                    )

                    guard let connectRadarCell = connectRadarCell as? CellProtocol else { throw CellBaseError.noTargetCell }
                    do {
                        let connectState = try await connectRadarCell.attach(
                            emitter: cellBridge,
                            label: "lobby",
                            requester: self.owner
                        )
                        if connectState != .connected {
                            throw StreamState.denied
                        }
                        try await connectRadarCell.absorbFlow(label: "lobby", requester: self.owner)
                    }
                }

                try self.checkCurrent(peerTransport, remoteUUID: remoteUUID)
                try await resolver.registerNamedEmitCell(
                    name: remoteUUID,
                    emitCell: cellBridge,
                    scope: .scaffoldUnique,
                    identity: self.owner
                )
                let resolvedRegisteredUUID = await resolver.cellUUID(for: remoteUUID) ?? cellBridge.uuid
                registeredUUID = resolvedRegisteredUUID
                try self.checkCurrent(peerTransport, remoteUUID: remoteUUID)
                self.withState {
                    guard self.bridgeTransportsByRemoteUUID[remoteUUID] === peerTransport else { return }
                    self.registeredBridgeUUIDsByRemoteUUID[remoteUUID] = resolvedRegisteredUUID
                }
                print("********* Finished setting up bridge for \(remoteUUID)")
            } catch {
                if let registeredUUID {
                    await resolver.unregisterEmitCell(uuid: registeredUUID)
                }
                self.withState {
                    guard self.bridgeTransportsByRemoteUUID[remoteUUID] === peerTransport else { return }
                    self.bridgeDelegatesByRemoteUUID[remoteUUID] = nil
                    self.bridgeTransportsByRemoteUUID[remoteUUID] = nil
                    self._connectedPeersDict[peerID] = nil
                    self._reversedConnectedPeersDict[remoteUUID] = nil
                }
                throw error
            }
        }
    }

    fileprivate func setBridgeDelegate(
        _ delegate: BridgeDelegateProtocol,
        for remoteUUID: String,
        setupID: UUID
    ) {
        withState {
            let isCurrentSetup = bridgeSetupTasks[remoteUUID]?.id == setupID
            let isCurrentTransport = bridgeTransportsByRemoteUUID[remoteUUID]?.setupID == setupID
            guard isCurrentSetup || isCurrentTransport else {
                return
            }
            bridgeDelegatesByRemoteUUID[remoteUUID] = delegate
        }
    }

    private func removeBridge(for remoteUUID: String, peerID: MCPeerID? = nil) {
        withState {
            let operation = bridgeSetupTasks[remoteUUID]
            let transport = bridgeTransportsByRemoteUUID.removeValue(forKey: remoteUUID)
            let registeredUUID = registeredBridgeUUIDsByRemoteUUID.removeValue(forKey: remoteUUID)
            guard transport != nil || registeredUUID != nil else { operation?.task.cancel(); return }
            bridgeDelegatesByRemoteUUID[remoteUUID] = nil
            invitationEndpoints[remoteUUID] = nil; invitedRemoteUUIDs.remove(remoteUUID)
            if let peer = peerID ?? _reversedConnectedPeersDict[remoteUUID] { _connectedPeersDict[peer] = nil }
            _reversedConnectedPeersDict[remoteUUID] = nil
            operation?.task.cancel()
            let retirementID = UUID(), resolver = CellBase.defaultCellResolver
            let cleanup = Task<Void, Error> { [weak self] in
                await transport?.gate.close()
                _ = try? await operation?.task.value
                if let registeredUUID { await resolver?.unregisterEmitCell(uuid: registeredUUID) }
                self?.withState {
                    if self?.bridgeSetupTasks[remoteUUID]?.id == retirementID { self?.bridgeSetupTasks[remoteUUID] = nil }
                }
            }
            bridgeSetupTasks[remoteUUID] = BridgeSetupOperation(id: retirementID, task: cleanup)
        }
    }

    func updateInformationLabel(description: String) {
        print("Information label: \(description)")
    }


    
#if os(iOS)
    func shareMyDiscoveryToken(token: NIDiscoveryToken) {
        guard let encodedData = try?  NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
            print("Unexpectedly failed to encode discovery token.")
            return
        }
        
        let contentObject: Object = ["token" : .data(encodedData), "userUuid" : .string(owner.uuid)]
        let flowElement = FlowElement(title: "DiscoveryToken", content: .object(contentObject), properties: FlowElement.Properties(type: .event, contentType: .object))
        
        let bridgeCommand = BridgeCommand(cmd: "response", payload: .flowElement(flowElement), cid: -1)
        
        guard let encodedElement = try? JSONEncoder().encode(bridgeCommand) else {
            print("Unexpectedly failed to encode flow element in bridge command")
            return
        }
        do {
            try mcSession.send(encodedElement, toPeers: mcSession.connectedPeers, with: .reliable)
            sharedTokenWithPeer = true
            print("Did share token with peers")
        } catch {
            print("Sending ni discovery tokens failed with error: \(error)")
        }
    }
#endif
    
#if os(iOS)
    func peerDidShareDiscoveryToken(tokenData: Data, userUuid: String) {
        guard let discoveryToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: tokenData) else {
            print("Unexpectedly failed to decode discovery token.")
            return
        }
        
        // evaluate userId here?
        peerDiscoveryToken = discoveryToken

        let config = NINearbyPeerConfiguration(peerToken: discoveryToken)

        // Run the session.
        print("")
        niSession?.run(config)
        print("Got shared token and running niSession")
    }
#endif

//    func peerDidShareDiscoveryToken(peer: MCPeerID, token: NIDiscoveryToken) {
//        if connectedPeer != peer {
//            fatalError("Received token from unexpected peer.")
//        }
//        // Create a configuration.
//        peerDiscoveryToken = token
//
//        let config = NINearbyPeerConfiguration(peerToken: token)
//
//        // Run the session.
//        niSession?.run(config)
//    }
//    
    func startup() {
        print("****** Starting up NISession *****")
#if os(iOS)
        guard supportsNearbyPrecision else {
            updateInformationLabel(description: "Nearby precision unavailable. Using Multipeer Connectivity only")
            radarDelegate?.scannerStatusChanged(manager: self, status: "precisionUnavailable", remoteUUID: connectedRemoteUUID)
            return
        }
        niSession = NISession()
        niSession?.delegate = self
        sharedTokenWithPeer = false
        if connectedPeer != nil {
            if let myToken = niSession?.discoveryToken {
                updateInformationLabel(description: "Initializing ...")
                if !sharedTokenWithPeer {
                    shareMyDiscoveryToken(token: myToken)
                }
                guard let peerToken = peerDiscoveryToken else {
                    print("****** no peer dicovery token *****")
                    return
                }
                let config = NINearbyPeerConfiguration(peerToken: peerToken)
                print("Just before ni session run in startup() config: \(config)")
                niSession?.run(config)
            } else {
                print("Unable to get self discovery token, is this session invalidated?")
            }
        } else {
            updateInformationLabel(description: "Discovering Peer ...")
        }
#else
        // NearbyInteraction not available
        updateInformationLabel(description: "NearbyInteraction not available on this platform")
#endif
    }
    
    func startupMPC() {
//        if mpc == nil {
//            // Prevent Simulator from finding devices.
//            #if targetEnvironment(simulator)
//            mpc = MPCSession(service: "nisample", identity: "com.example.apple-samplecode.simulator.peekaboo-nearbyinteraction", maxPeers: 1)
//            #else
//            mpc = MPCSession(service: "nisample", identity: "com.example.apple-samplecode.peekaboo-nearbyinteraction", maxPeers: 1)
//            #endif
//            mpc?.peerConnectedHandler = connectedToPeer
//            mpc?.peerDataHandler = dataReceivedHandler
//            mpc?.peerDisconnectedHandler = disconnectedFromPeer
//        }
//        mpc?.invalidate()
//        mpc?.start()
    }
}

extension ScannerService : MCNearbyServiceAdvertiserDelegate {

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NSLog("%@", "didNotStartAdvertisingPeer: \(error)")
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        NSLog("%@", "didReceiveInvitationFromPeer \(peerID)")
        if let context, let endpoint = try? BridgeChannelAuthentication.decode(BridgePeerChannelAuthentication.Endpoint.self, from: context) {
            receiveInvitation(from: peerID, endpoint: endpoint, handler: invitationHandler)
        } else if let context {
            Task { @MainActor [weak self] in
                guard let self, let remoteID = self.withState({ self._reversedFoundPeersDict[peerID] }) else {
                    invitationHandler(false, nil); return
                }
                if self.advertisementExchange?.accept(context: context, peer: peerID,
                    localPeer: self.myPeerId, reply: invitationHandler,
                    localSessionID: self.mySessionUUID, remoteSessionID: remoteID) == true { return }
                // Unrecognized contexts never widen the ordinary bridge invitation policy.
                self.receiveInvitation(from: peerID, handler: invitationHandler)
            }
        } else {
            receiveInvitation(from: peerID, handler: invitationHandler)
        }
    }

}

extension ScannerService : MCNearbyServiceBrowserDelegate {

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        NSLog("%@", "didNotStartBrowsingForPeers: \(error)")
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        NSLog("%@", "foundPeer discovered")
//        NSLog("%@", "invitePeer: \(peerID)")
        guard let remoteUUID = info?["uuid"] else {
            print("Did not find remote uuid in info!")
            return
        }
        guard remoteUUID != mySessionUUID else {
            return
        }
        let discoveredPeerNames = withState {
            _foundPeersDict[remoteUUID] = peerID
            _reversedFoundPeersDict[peerID] = remoteUUID
            if info?["ad"] == "1" { advertisementPeers.insert(remoteUUID) }
            else { advertisementPeers.remove(remoteUUID) }
            if info?["ad"] == "1", info?["adp"] == "2" { advertisementProofPeers.insert(remoteUUID) }
            else { advertisementProofPeers.remove(remoteUUID) }
            return _foundPeersDict.values.map(\.displayName)
        }

        self.discoveredDevices = discoveredPeerNames
        print("Discovered devices: \(String(describing: self.discoveredDevices))")
        self.radarDelegate?.foundDevicesChanged(
            manager: self,
            foundDevice: peerID,
            remoteUUID: remoteUUID,
            discoveryInfo: info
        )
        self.radarDelegate?.scannerStatusChanged(manager: self, status: "peerFound", remoteUUID: remoteUUID)
        

        

        
        
//        browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        NSLog("%@", "lostPeer: \(peerID)")
        // remove from connected too?
        
        let remoteUUID = withState { () -> String? in
            guard let remoteUUID = _reversedFoundPeersDict.removeValue(forKey: peerID) else {
                return nil
            }
            _foundPeersDict.removeValue(forKey: remoteUUID)
            advertisementPeers.remove(remoteUUID)
            advertisementProofPeers.remove(remoteUUID)
            return remoteUUID
        }
        if let remoteUUID {
            self.removeBridge(for: remoteUUID, peerID: peerID)
            self.radarDelegate?.lostDeviceChanged(manager: self, lostDevice: peerID, remoteUUID: remoteUUID)
            self.radarDelegate?.scannerStatusChanged(manager: self, status: "peerLost", remoteUUID: remoteUUID)
        }
        self.discoveredDevices = withState { _foundPeersDict.values.map(\.displayName) }
        print("Discovered devices2: \(String(describing: self.discoveredDevices))")
    }
    
    


}

extension ScannerService : MCSessionDelegate {
    
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
            NSLog("%@", "peer \(peerID) didChangeState: \(state.rawValue)")
        self.radarDelegate?.connectedDevicesChanged(manager: self, connectedDevices:
                                                        session.connectedPeers.map{$0.displayName})
        
        DispatchQueue.main.async {
            switch state {
            case .notConnected:
                print("***************** .notConnected  for \(peerID.displayName)")
                if self.connectedPeerIdDisplayname == peerID.displayName {
                    self.connectedPeerIdDisplayname = nil
                }
                let remoteUUID = self.withState { () -> String? in
                    guard let remoteUUID = self._reversedFoundPeersDict.removeValue(forKey: peerID) else {
                        return nil
                    }
                    self._foundPeersDict.removeValue(forKey: remoteUUID)
                    return remoteUUID
                }
                if let remoteUUID {
                    self.removeBridge(for: remoteUUID, peerID: peerID)
                    self.radarDelegate?.lostDeviceChanged(manager: self, lostDevice: peerID, remoteUUID: remoteUUID)
                    self.radarDelegate?.scannerStatusChanged(manager: self, status: "disconnected", remoteUUID: remoteUUID)
                }
                if self.connectedPeer == peerID {
                    self.connectedPeer = nil
                }
                self.connectedRemoteUUID = nil
            case .connecting:
                print("***************** .connecting for \(peerID.displayName)")
                if let remoteUUID = self.withState({ self._reversedFoundPeersDict[peerID] }) {
                    self.radarDelegate?.scannerStatusChanged(manager: self, status: "connecting", remoteUUID: remoteUUID)
                } else {
                    print("Did not find remoteUUID for peerID: \(peerID)")
                }
            case .connected:
                self.connectedPublisher.send(true)
                self.connectedPeerIdDisplayname = peerID.displayName
                print("***************** .connected for \(peerID.displayName)")
                self.connectedPeer = peerID
                if let remoteUUID = self.withState({ self._reversedFoundPeersDict[peerID] }) {
                    self.connectedRemoteUUID = remoteUUID
                    self.radarDelegate?.scannerStatusChanged(manager: self, status: "authenticating", remoteUUID: remoteUUID)
                    Task {
                        do {
                            try await self.setupBridge(remoteUUID: remoteUUID, peerID: peerID)
                            self.radarDelegate?.scannerStatusChanged(manager: self, status: "connected", remoteUUID: remoteUUID)
                            self.startup()
                        } catch {
                            self.reportBridgeFailure(error, remoteUUID: remoteUUID)
                        }
                    }
                } else {
                    self.reportBridgeFailure(BridgeChannelAuthentication.Failure.unavailable, remoteUUID: nil)
                }
               
                
                
            @unknown default:
                print("Unknown ")
            }
            
            
            //
            self.connectedDevices = session.connectedPeers.map{$0.displayName}
            
            print("Found peers dict: \(self.foundPeersDict)")
            print("connected devices: \(String(describing: self.connectedDevices))")
            print("self.discoveredDevices: \(String(describing: self.discoveredDevices))")
        }
        
    }
    
    public func connected() async throws {
        if self.connected == false {
            self.connected = try await self.connectedPublisher.getOneWithTimeout(1)
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        NSLog("%@", "didReceiveData bytes=\(data.count)")
        Task { [weak self] in
            guard let self = self else { return }
            do {
                // Maybe wait for .connected state instead?
                if let remoteUUID = self.withState({ self._reversedFoundPeersDict[peerID] }) {
                    try self.prepareBridge(remoteUUID: remoteUUID, peerID: peerID)
                    Task { try? await self.setupBridge(remoteUUID: remoteUUID, peerID: peerID) }
                }
                try await self.extractCommandFromData(data, from: peerID)
            } catch {
                let remote = self.withState { self._reversedFoundPeersDict[peerID] }
                self.reportBridgeFailure(error, remoteUUID: remote)
                if let remote { self.removeBridge(for: remote, peerID: peerID) }
            }
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        NSLog("%@", "didReceiveStream")
    }
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        NSLog("%@", "didStartReceivingResourceWithName")
    }
    
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        NSLog("%@", "didFinishReceivingResourceWithName")
    }
}
extension ScannerService {
    func identityVault(
        for identity: Identity?,
        bridgeDelegate: BridgeDelegateProtocol?
    ) async -> any IdentityVaultProtocol {
        let bridge = bridgeDelegate as? BridgeProtocol
        return BridgeIdentityVault(cloudBridge: bridge)
    }
    
    func handleOutOfBandFlowElement(_ flowElement: FlowElement, remoteUUID: String?) {
        guard case let .object(contentObject) = flowElement.content else {
            radarDelegate?.scannerFlowReceived(manager: self, flowElement: flowElement, remoteUUID: remoteUUID)
            return
        }

        if let uuidValue = contentObject["userUuid"],
           case let .string(uuid) = uuidValue,
           let tokenValue = contentObject["token"] {
            let tokenData: Data?
            switch tokenValue {
            case .data(let data):
                tokenData = data
            case .string(let tokenB64String):
                tokenData = Data(base64Encoded: tokenB64String)
            default:
                tokenData = nil
            }
            if let tokenData {
#if os(iOS)
                if supportsNearbyPrecision {
                    self.peerDidShareDiscoveryToken(tokenData: tokenData, userUuid: uuid)
                }
#endif
                return
            }
        }

        radarDelegate?.scannerFlowReceived(manager: self, flowElement: flowElement, remoteUUID: remoteUUID)
    }
    func extractCommandFromData(_ data: Data, from peerID: MCPeerID) async throws {
        guard let route = withState({ () -> (String, ScannerPeerTransport)? in
            guard let remote = _reversedFoundPeersDict[peerID], _foundPeersDict[remote] == peerID,
                  let physical = bridgeTransportsByRemoteUUID[remote] else { return nil }
            return (remote, physical)
        }) else { throw BridgeChannelAuthentication.Failure.unavailable }
        let gate = route.1.gate!
        do {
            try gate.validateInboundPayload(data)
            let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
            if let identity = command.identity { identity.identityVault = await identityVault(for: identity, bridgeDelegate: route.1.bridge) }
            if command.cmd.hasPrefix("channelAuth") {
                try await gate.consumeCommand(command: command)
                return
            }
            guard Command(rawValue: command.cmd) != nil else { throw ScannerServiceError.invalidCommand(command.cmd) }
            if command.cid < 0 {
                try gate.session.check(identity: command.identity)
                guard command.command == .response, case let .flowElement(flowElement) = command.payload else { throw BridgeChannelAuthentication.Failure.malformed }
                try await gate.withAuthenticatedWork { self.handleOutOfBandFlowElement(flowElement, remoteUUID: route.0) }
            } else if command.command == .response { try await gate.consumeResponse(command: command) }
            else { try await gate.consumeCommand(command: command) }
        } catch {
            await gate.close()
            reportBridgeFailure(error, remoteUUID: route.0)
            throw error
        }
    }

    // This is called if this is the inviting device - which invites into the lobby
    func attachLobbyToEntityScanner(requester: Identity) async throws {
        
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        
        
        let connectRadarCell = try await resolver.cellAtEndpoint(endpoint: "cell:///EntityScanner", requester: requester)
        let lobbyCell = try await resolver.cellAtEndpoint(endpoint: "cell:///Lobby", requester: requester)
        
        guard let connectRadarCell = connectRadarCell as? CellProtocol,
              let lobbyCell = lobbyCell as? CellProtocol else { throw CellBaseError.noTargetCell }
        do {
            let connectState = try await connectRadarCell.attach(emitter: lobbyCell, label: "lobby", requester: requester)
            if connectState != .connected {
                throw StreamState.denied
            }
            
            try await connectRadarCell.absorbFlow(label: "lobby", requester: requester	)
        }
    }
    
    
}
// MARK: - `NISessionDelegate`.
#if os(iOS)
extension ScannerService: NISessionDelegate {
    

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        
        guard let peerToken = peerDiscoveryToken else {
            print("didUpdate called without peer token")
            return
        }

        // Find the right peer.
        let peerObj = nearbyObjects.first { (obj) -> Bool in
            return obj.discoveryToken == peerToken
        }

        guard let nearbyObjectUpdate = peerObj else {
            return
        }
        guard let remoteUUID = connectedRemoteUUID else {
            return
        }
        print("nearbyObjects: \(nearbyObjects.count)")
        let distanceMeters = nearbyObjectUpdate.distance
        let directionX = nearbyObjectUpdate.direction?.x
        let directionY = nearbyObjectUpdate.direction?.y
        let directionZ = nearbyObjectUpdate.direction?.z
        radarDelegate?.proximityChanged(
            manager: self,
            remoteUUID: remoteUUID,
            distanceMeters: distanceMeters,
            directionX: directionX,
            directionY: directionY,
            directionZ: directionZ
        )
        // Update the the state and visualizations.
//        let nextState = getDistanceDirectionState(from: nearbyObjectUpdate)
//        updateVisualization(from: currentDistanceDirectionState, to: nextState, with: nearbyObjectUpdate)
//        currentDistanceDirectionState = nextState
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let peerToken = peerDiscoveryToken else {
            print("didRemove called without peer token")
            return
        }
        // Find the right peer.
        let peerObj = nearbyObjects.first { (obj) -> Bool in
            return obj.discoveryToken == peerToken
        }

        if peerObj == nil {
            return
        }

//        currentDistanceDirectionState = .unknown

        switch reason {
        case .peerEnded:
            // The peer token is no longer valid.
            peerDiscoveryToken = nil
            
            // The peer stopped communicating, so invalidate the session because
            // it's finished.
            session.invalidate()
            
            // Restart the sequence to see if the peer comes back.
//            startup()
            
            // Update the app's display.
            updateInformationLabel(description: "Peer Ended")
        case .timeout:
            
            // The peer timed out, but the session is valid.
            // If the configuration is valid, run the session again.
            if let config = session.configuration {
                session.run(config)
            }
            updateInformationLabel(description: "Peer Timeout")
        default:
            print("Unknown and unhandled NINearbyObject.RemovalReason: \(reason)")
        }
    }

    func sessionWasSuspended(_ session: NISession) {
//        currentDistanceDirectionState = .unknown
        updateInformationLabel(description: "Session suspended")
    }

    func sessionSuspensionEnded(_ session: NISession) {
        // Session suspension ended. The session can now be run again.
        if let config = self.niSession?.configuration {
            print("seesio run in suspension ended")
            session.run(config)
        } else {
            // Create a valid configuration.
            startup()
        }

//        centerInformationLabel.text = peerDisplayName
//        detailDeviceNameLabel.text = peerDisplayName
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
//        currentDistanceDirectionState = .unknown
        print("Ni Session did invalidate with error: \(error)")
        // If the app lacks user approval for Nearby Interaction, present
        // an option to go to Settings where the user can update the access.
        if case NIError.userDidNotAllow = error {
            if #available(iOS 15.0, *) {
#if canImport(UIKit)
                // In iOS 15.0, Settings persists Nearby Interaction access.
                updateInformationLabel(description: "Nearby Interactions access required. You can change access for NIPeekaboo in Settings.")
                // Create an alert that directs the user to Settings.
                let accessAlert = UIAlertController(title: "Access Required",
                                                    message: """
                                                    NIPeekaboo requires access to Nearby Interactions for this sample app.
                                                    Use this string to explain to users which functionality will be enabled if they change
                                                    Nearby Interactions access in Settings.
                                                    """,
                                                    preferredStyle: .alert)
                accessAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
                accessAlert.addAction(UIAlertAction(title: "Go to Settings", style: .default, handler: {_ in
                    // Send the user to the app's Settings to update Nearby Interactions access.
                    if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settingsURL, options: [:], completionHandler: nil)
                    }
                }))

                // Display the alert.
//                present(accessAlert, animated: true, completion: nil)
#endif
            } else {
                // Before iOS 15.0, ask the user to restart the app so the
                // framework can ask for Nearby Interaction access again.
                updateInformationLabel(description: "Nearby Interactions access required. Restart NIPeekaboo to allow access.")
            }

            return
        }

        // Recreate a valid session.
        startup()
    }

    
}
#endif
