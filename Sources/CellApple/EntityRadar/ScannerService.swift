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

    @MainActor func connectedDevicesChanged(manager : ScannerService, connectedDevices: [String])
//    @MainActor func colorChanged(manager : ConnectService, colorString: String)
//    @MainActor func foundDevicesChanged(manager: RadarService, foundDevices: [String])

    @MainActor func foundDevicesChanged(
        manager: ScannerService,
        foundDevice: MCPeerID,
        remoteUUID: String,
        discoveryInfo: [String: String]?
    )
    @MainActor func lostDeviceChanged(manager: ScannerService, lostDevice: MCPeerID, remoteUUID: String)
    @MainActor func invitationReceived(manager: ScannerService, peerID: MCPeerID, remoteUUID: String)
    @MainActor func scannerStatusChanged(manager: ScannerService, status: String, remoteUUID: String?)
    @MainActor func proximityChanged(
        manager: ScannerService,
        remoteUUID: String,
        distanceMeters: Float?,
        directionX: Float?,
        directionY: Float?,
        directionZ: Float?
    )
    @MainActor func scannerFlowReceived(manager: ScannerService, flowElement: FlowElement, context: ScannerConsumerContext) async throws
    @MainActor func scannerChannelRetired(manager: ScannerService, generation: String)
}

extension ConnectServiceDelegate {
    @MainActor func scannerChannelRetired(manager: ScannerService, generation: String) {}
}

private enum ScannerServiceError: Error {
    case peerNotConnected(String)
    case noConnectedPeers
    case invalidCommand(String)
}

final class ScannerPeerTransport: BridgeTransportProtocol {
    private weak var service: ScannerService?
    let remoteUUID: String
    let peerID: MCPeerID
    let mcSession: MCSession
    let role: BridgePeerChannelAuthentication.Role
    let setupID: UUID
    var isInitiator: Bool { role == .initiator }
    private weak var delegate: BridgeDelegateProtocol?
    private let sendLock = NSLock()
    private let receiveLock = NSLock()
    private var receiveTail: Task<Task<Void, Error>, Error>?
    private var dispatchTail: Task<Void, Error>?
    // Deterministic hold after record opening, before consumer dispatch.
    var beforeOrderedDispatch: ((BridgeCommand) async -> Void)?
    private var closeTask: Task<Void, Never>?
    private var receiveRejection: Task<Void, Error>?
    private var queuedReceives = 0
    private var queuedBytes = 0
    var gate: BridgeChannelTransport!
    var bridge: BridgeBase?
    fileprivate var setupScheduled = false // accessed only on service stateQueue
    var channelSession: BridgeChannelSession? { gate?.session }

    init(service: ScannerService, remoteUUID: String, peerID: MCPeerID,
         session: MCSession, endpoint: BridgePeerChannelAuthentication.Endpoint, invitationID: UUID) {
        self.service = service
        self.remoteUUID = remoteUUID
        self.peerID = peerID
        self.mcSession = session
        self.setupID = invitationID
        self.role = endpoint.initiator == service.mySessionUUID ? .initiator : .responder
    }

    func setDelegate(_ delegate: BridgeDelegateProtocol) {
        self.delegate = delegate
    }

    func setup(_ endpointURL: URL, identity: Identity) async throws {}

    func sendData(_ data: Data) async throws {
        guard let service else { throw ScannerServiceError.peerNotConnected(remoteUUID) }
        do {
            // Non-suspending critical section: counter allocation and MC send
            // have the same order, even when several Cell tasks send at once.
            while let revision = try sendLock.withLock({ try service.sendPeerData(data, on: self) }) {
                try await gate.waitForPeerCapacity(after: revision)
            }
        } catch { await gate.close(); throw error }
    }

    func identityVault(for identity: Identity?) async -> any IdentityVaultProtocol {
        guard let service else { return BridgeIdentityVault(cloudBridge: delegate as? BridgeProtocol) }
        return await service.identityVault(for: identity, bridgeDelegate: delegate)
    }

    func receiveData(_ data: Data) async throws { try await enqueueReceive(data).value }

    // Called synchronously by MCSessionDelegate, before creating asynchronous
    // work. Serialize record opening and handshake progression, but let Cell
    // dispatch await later responses (in particular the origin-signature RPC).
    @discardableResult
    func enqueueReceive(_ data: Data) -> Task<Void, Error> {
        receiveLock.withLock {
            if let receiveRejection { return receiveRejection }
            guard data.count <= BridgeChannelTransport.maximumPeerFrameBytes,
                  queuedReceives < 64, data.count <= 4 * 1024 * 1024 - queuedBytes else {
                gate.session.close() // revoke dispatch immediately, before asynchronous cleanup
                let rejection = Task<Void, Error> { await gate.close(); throw BridgeChannelAuthentication.Failure.capacity }
                receiveRejection = rejection
                return rejection
            }
            queuedReceives += 1; queuedBytes += data.count
            let previous = receiveTail
            let preparation = Task<Task<Void, Error>, Error> { [self] in
                _ = try await previous?.value
                guard let service else { throw CancellationError() }
                let plaintext = try gate.openPeerFrame(data)
                if plaintext.isEmpty { return Task {} } // authenticated receipt only
                try gate.validateInboundPayload(plaintext)
                let command = try JSONDecoder().decode(BridgeCommand.self, from: plaintext)
                if command.cmd.hasPrefix("channelAuth") {
                    try await service.extractCommandFromData(plaintext, on: self)
                    return Task {}
                }
                // Bounded admission has already charged the complete frame.
                // Receipt certifies admission, not completion of a Cell effect.
                try sendLock.withLock { try service.sendPeerReceipts(on: self) }
                // Only an origin-sign request or a response to our registered
                // sign RPC may overtake application work. Payload shape alone
                // cannot promote a flow/command to the control lane. All normal
                // gate, session, permit and signature checks still run.
                let control = command.command == .sign || bridge?.isOriginSigningResponse(command) == true
                return receiveLock.withLock {
                    let prior = control ? nil : dispatchTail
                    let dispatch = Task { [self] in
                        _ = try await prior?.value
                        if !control { await beforeOrderedDispatch?(command) }
                        try await service.extractCommandFromData(plaintext, on: self)
                    }
                    if !control { dispatchTail = dispatch }
                    return dispatch
                }
            }
            receiveTail = preparation
            return Task { [self] in
                defer { receiveLock.withLock { queuedReceives -= 1; queuedBytes -= data.count } }
                do {
                    let dispatch = try await preparation.value
                    try await dispatch.value
                } catch {
                    service?.reportBridgeFailure(error, on: self)
                    await gate.close()
                    throw error
                }
            }
        }
    }

    func close() async {
        let task = receiveLock.withLock { () -> Task<Void, Never> in
            if let closeTask { return closeTask }
            let task = Task<Void, Never> { [service] in await service?.peerChannelClosed(self) }
            closeTask = task
            return task
        }
        await task.value
    }

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

    private final class Invitation {
        enum State { case pending, outgoing, accepted }
        let id = UUID()
        let generation: UUID
        let peer: MCPeerID
        let session: MCSession
        let remoteUUID: String
        let endpoint: BridgePeerChannelAuthentication.Endpoint?
        let deadline: TimeInterval
        let admission: ScannerAdmission.Lease
        var state: State
        var handler: ((Bool, MCSession?) -> Void)?

        init(generation: UUID, peer: MCPeerID, session: MCSession, remoteUUID: String,
             endpoint: BridgePeerChannelAuthentication.Endpoint?, deadline: TimeInterval,
             state: State, admission: ScannerAdmission.Lease, handler: ((Bool, MCSession?) -> Void)? = nil) {
            self.generation = generation; self.peer = peer; self.session = session
            self.remoteUUID = remoteUUID; self.endpoint = endpoint; self.deadline = deadline
            self.state = state; self.admission = admission; self.handler = handler
        }
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

    private var invitations = [String: Invitation]()
    let admission: ScannerAdmission
    private var discoveries: [MCPeerID: ScannerAdmission.Lease] = [:]
    private struct PendingEvent {
        let generation: UUID
        let lease: ScannerAdmission.Lease
        let action: @MainActor (ScannerService) -> Void
        let discard: () -> Void
    }
    private var events: [UUID: PendingEvent] = [:]
    private var eventOrder: [UUID] = []
    private var eventDrainScheduled = false
    // A test can hold the one drain without creating Tasks for each peer.
    var deferEventDrainForTesting = false
    private var scheduledSetups: [UUID: (physical: ScannerPeerTransport, lease: ScannerAdmission.Lease)] = [:]
    private var serviceGeneration = UUID()
    private var stopped = false
    private var maintenance: DispatchSourceTimer?
    var invitationClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    // Runs INSIDE the transition lock, at the former remove/install race.
    var duringInvitationAcceptance: (() -> Void)?
    private static let peerLimits = BridgeChannelLimits()
    var channelLimits = ScannerService.peerLimits
    // Internal adapter seam: production always uses MCSession reliable delivery.
    var peerSend: ((Data, MCPeerID, MCSession) throws -> Void)?
    var sideEntranceRejectedForTesting: ((String, Bool) -> Void)?
    private var _radarDelegate: ConnectServiceDelegate?
    var radarDelegate: ConnectServiceDelegate? {
        get { withState { _radarDelegate } }
        set { withState { _radarDelegate = newValue } }
    }
    private var bridgeTransportsByRemoteUUID = [String: ScannerPeerTransport]()
    private var registeredBridgeUUIDsByRemoteUUID = [String: String]()
    private var bridgeSetupTasks = [String: BridgeSetupOperation]()
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
    
    // Each accepted physical peer owns a distinct, never-reused MCSession.
    // A retiring slot retains its admission until MC reports no connected peer.
    private final class PhysicalSlot {
        let peer: MCPeerID
        let session: MCSession
        let lease: ScannerAdmission.Lease
        var retiring = false
        var waiter: CheckedContinuation<Void, Never>?
        init(peer: MCPeerID, session: MCSession, lease: ScannerAdmission.Lease) {
            self.peer = peer; self.session = session; self.lease = lease
        }
    }
    private var physicalSlots: [ObjectIdentifier: PhysicalSlot] = [:]
    private var heldRetirement = false
    var holdPhysicalRetirementForTesting: Bool {
        get { withState { heldRetirement } }
        set { withState { heldRetirement = newValue } }
    }
    var retainedPhysicalCount: Int { withState { physicalSlots.count } }

    func sessionForPeer(_ peer: MCPeerID) throws -> MCSession {
        try withState {
            guard let slot = physicalSlots.values.first(where: { $0.peer == peer && !$0.retiring }) else {
                throw BridgeChannelAuthentication.Failure.unavailable
            }
            return slot.session
        }
    }
    private func newPeerSession(_ peer: MCPeerID) throws -> MCSession {
        guard let lease = admission.reserve(.physical, peer: peer, bytes: 256) else {
            throw BridgeChannelAuthentication.Failure.capacity
        }
        let session = MCSession(peer: myPeerId, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        physicalSlots[ObjectIdentifier(session)] = PhysicalSlot(peer: peer, session: session, lease: lease)
        return session
    }
    private func retirePhysical(_ session: MCSession) {
        withState {
            guard let slot = physicalSlots[ObjectIdentifier(session)], !slot.retiring else { return }
            slot.retiring = true
            session.disconnect()
            reapPhysicalSessions()
        }
    }
    private func reapPhysicalSessions() {
        for (id, slot) in physicalSlots where slot.retiring && slot.session.connectedPeers.isEmpty && !holdPhysicalRetirementForTesting {
            physicalSlots[id] = nil
            slot.lease.release()
            slot.waiter?.resume(); slot.waiter = nil
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
        let remote = remoteUUID.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try withState {
                let endpoint = try makeInvitation(remoteUUID: remote)
                guard let binding = invitations[remote] else { throw CancellationError() }
                serviceBrowser.invitePeer(binding.peer, to: binding.session,
                    withContext: try BridgeChannelAuthentication.encode(endpoint), timeout: min(10, invitationTimeout))
            }
        } catch { reportBridgeFailure(error, remoteUUID: remote) }
    }

    /// One bounded, expiring main-actor queue for discovery UI and context work.
    /// The scheduled task captures only self weakly; expired entries release
    /// their payload even when the main actor has not yet drained the queue.
    @discardableResult
    private func enqueueEvent(peer: MCPeerID, bytes: Int, kind: ScannerAdmission.Kind = .event,
                              discard: @escaping () -> Void = {}, reserved: ScannerAdmission.Lease? = nil, action: @escaping @MainActor (ScannerService) -> Void) -> Bool {
        withState {
            guard !stopped, let lease = reserved ?? admission.reserve(kind, peer: peer, bytes: bytes) else { return false }
            let id = UUID(), generation = serviceGeneration
            events[id] = PendingEvent(generation: generation, lease: lease, action: action, discard: discard)
            eventOrder.append(id)
            if !eventDrainScheduled && !deferEventDrainForTesting {
                eventDrainScheduled = true
                Task { @MainActor [weak self] in self?.drainEvents(generation: generation) }
            }
            return true
        }
    }

    @MainActor func drainEventsForTesting() { drainEvents(generation: withState { serviceGeneration }) }
    @MainActor private func drainEvents(generation: UUID) {
        while let event = withState({ () -> PendingEvent? in
            guard generation == serviceGeneration else { return nil }
            guard !eventOrder.isEmpty else { eventDrainScheduled = false; return nil }
            return events.removeValue(forKey: eventOrder.removeFirst())
        }) {
            withState {
                // Stop/expiry cannot pass the last guard before publication.
                if !stopped, event.generation == serviceGeneration, event.lease.isLive { event.action(self) }
                else { event.discard() }
            }
            event.lease.release()
        }
    }
    var queuedEventCount: Int { withState { events.count } }

    func makeInvitation(remoteUUID: String) throws -> BridgePeerChannelAuthentication.Endpoint {
        try withState {
            expireInvitations()
            guard !stopped, let peer = _foundPeersDict[remoteUUID], invitations[remoteUUID] == nil,
                  bridgeTransportsByRemoteUUID[remoteUUID] == nil else { throw BridgeChannelAuthentication.Failure.unexpectedMessage }
            let endpoint = try BridgePeerChannelAuthentication.Endpoint(initiator: mySessionUUID, responder: remoteUUID,
                setupID: UUID().uuidString, domain: "nearby")
            guard let lease = admission.reserve(.invitation, peer: peer, bytes: try BridgeChannelAuthentication.encode(endpoint).count + 256) else {
                throw BridgeChannelAuthentication.Failure.capacity
            }
            invitations[remoteUUID] = Invitation(generation: serviceGeneration, peer: peer, session: try newPeerSession(peer),
                remoteUUID: remoteUUID, endpoint: endpoint, deadline: invitationClock() + invitationTimeout, state: .outgoing, admission: lease)
            return endpoint
        }
    }

    func isConnected(remoteUUID: String) -> Bool {
        withState {
            if let physical = bridgeTransportsByRemoteUUID[remoteUUID] {
                return physical.mcSession.connectedPeers.contains(physical.peerID)
            }
            guard let peer = _foundPeersDict[remoteUUID] else { return false }
            return (try? sessionForPeer(peer).connectedPeers.contains(peer)) ?? false
        }
    }

    func sendScannerFlowElement(_ flowElement: FlowElement, remoteUUID: String? = nil) async throws {
        let bridgeCommand = BridgeCommand(cmd: "response", payload: .flowElement(flowElement), cid: -2)
        let encodedElement = try JSONEncoder().encode(bridgeCommand)
        let transports = withState { remoteUUID.map { bridgeTransportsByRemoteUUID[$0].map { [$0] } ?? [] } ?? Array(bridgeTransportsByRemoteUUID.values) }
        guard !transports.isEmpty else { throw ScannerServiceError.noConnectedPeers }
        for transport in transports { try await transport.gate.sendData(encodedElement) }
    }

    fileprivate func sendPeerData(_ data: Data, on transport: ScannerPeerTransport) throws -> UInt64? {
        try withState {
            guard bridgeTransportsByRemoteUUID[transport.remoteUUID] === transport else { throw CancellationError() }
            // Lock order: Scanner binding -> gate -> session -> MC submission.
            // Other Scanner state paths read session state in this same order.
            return try transport.gate.submitPeerFrameWhenAvailable(data) { wire in
                if let peerSend { try peerSend(wire, transport.peerID, transport.mcSession) }
                else {
                    guard transport.mcSession.connectedPeers.contains(transport.peerID) else {
                        throw ScannerServiceError.peerNotConnected(transport.remoteUUID)
                    }
                    try transport.mcSession.send(wire, toPeers: [transport.peerID], with: .reliable)
                }
            }
        }
    }
    fileprivate func sendPeerReceipts(on transport: ScannerPeerTransport) throws {
        try withState {
            guard bridgeTransportsByRemoteUUID[transport.remoteUUID] === transport else { throw CancellationError() }
            try transport.gate.submitPeerReceipts { wire in
                if let peerSend { try peerSend(wire, transport.peerID, transport.mcSession) }
                else { try transport.mcSession.send(wire, toPeers: [transport.peerID], with: .reliable) }
            }
        }
    }
    fileprivate func peerChannelClosed(_ transport: ScannerPeerTransport) async {
        withState {
            retirePhysical(transport.mcSession)
            if removeBridge(for: transport.remoteUUID, expected: transport) {
                reportBridgeFailure(BridgeChannelAuthentication.Failure.closed, remoteUUID: transport.remoteUUID)
            }
        }
        await radarDelegate?.scannerChannelRetired(manager: self, generation: transport.gate.session.generation)
        // Keep gate transport/send reservations until the actual session empties.
        // Cancellation is not evidence of physical retirement.
        await withCheckedContinuation { continuation in
            withState {
                if let slot = physicalSlots[ObjectIdentifier(transport.mcSession)] { slot.waiter = continuation }
                else { continuation.resume() }
            }
        }
    }
    fileprivate func reportBridgeFailure(_ error: Error, on transport: ScannerPeerTransport) {
        withState {
            guard bridgeTransportsByRemoteUUID[transport.remoteUUID] === transport else { return }
            reportBridgeFailure(error, remoteUUID: transport.remoteUUID)
        }
    }
    private func reportBridgeFailure(_ error: Error, remoteUUID: String?) {
        let code = (error as? StreamState) == .denied ? "denied" : "channel"
        enqueueEvent(peer: myPeerId, bytes: 256) { service in
            service.radarDelegate?.scannerStatusChanged(manager: service, status: "bridgeFailed:\(code)", remoteUUID: remoteUUID)
        }
    }

    func disconnect() {
        withState { for slot in Array(physicalSlots.values) { retirePhysical(slot.session) } }
    }

    init(
        admission: ScannerAdmission = .shared,
        owner: Identity,
        serviceDicoveryInfoDict: [String: String] = ["v": NearbyBeacon.currentVersion, "k": "u"],
        invitationTimeout: TimeInterval = 30,
        sessionUUID: String? = nil
    ) {
        let resolvedSessionUUID = sessionUUID ?? UUID().uuidString
        mySessionUUID = resolvedSessionUUID
        myPeerId = MCPeerID(displayName: Self.privatePeerDisplayName(sessionUUID: resolvedSessionUUID))
        
        self.owner = owner
        self.admission = admission
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
        // One timer for all discovery/invitation expiry, never one task per peer.
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + min(1, invitationTimeout), repeating: min(1, max(0.01, invitationTimeout)))
        timer.setEventHandler { [weak self] in self?.expireInvitations() }
        maintenance = timer
        timer.resume()
        print("Inited radar service with peerId: \(myPeerId)")
    }

    deinit {
        stop()
    }

    func start() {
        print("@@@@@ start")
        withState { stopped = false }
        self.serviceAdvertiser.startAdvertisingPeer()
        self.serviceBrowser.startBrowsingForPeers()
        enqueueEvent(peer: myPeerId, bytes: 256) { service in service.radarDelegate?.scannerStatusChanged(manager: service, status: "started", remoteUUID: nil) }
//       startup()
    }
    
    
    func stop() {
        self.serviceAdvertiser.stopAdvertisingPeer()
        self.serviceBrowser.stopBrowsingForPeers()
        // Deinitializing an unstarted service must not create a session whose
        // weak delegate is already in deinit.
        disconnect()
        withState {
            stopped = true; serviceGeneration = UUID()
            let pending = Array(invitations.values)
            invitations.removeAll()
            let queued = Array(events.values); events.removeAll(); eventOrder.removeAll(); eventDrainScheduled = false
            for event in queued { event.discard(); event.lease.release() }
            discoveries.removeAll()
            for invitation in pending { invitation.handler?(false, nil); invitation.handler = nil }
        }
        connectedRemoteUUID = nil
        connectedPeer = nil
        let remotes = withState { Set(bridgeTransportsByRemoteUUID.keys).union(bridgeSetupTasks.keys).union(registeredBridgeUUIDsByRemoteUUID.keys) }
        for remote in remotes { removeBridge(for: remote) }
        withState {
            invitations.removeAll()
            _foundPeersDict.removeAll(); _reversedFoundPeersDict.removeAll()
            advertisementPeers.removeAll(); advertisementProofPeers.removeAll()
            _connectedPeersDict.removeAll(); _reversedConnectedPeersDict.removeAll()
        }
        enqueueEvent(peer: myPeerId, bytes: 256) { service in service.radarDelegate?.scannerStatusChanged(manager: service, status: "stopped", remoteUUID: nil) }
    }

    var pendingInvitationCount: Int { withState { invitations.values.filter { $0.state == .pending }.count } }
    var retainedInvitationCount: Int { withState { invitations.count } }

    /// Each retained transport owns exactly one gate/delegate.
    var bridgeDelegateCount: Int { withState { bridgeTransportsByRemoteUUID.count } }

    @discardableResult
    func respondToInvitation(remoteUUID: String, accept: Bool) -> Bool {
        withState {
            expireInvitations()
            guard !stopped, let invitation = invitations[remoteUUID], invitation.state == .pending,
                  invitation.generation == serviceGeneration else { return false }
            let handler = invitation.handler
            invitation.handler = nil
            // Discovery, expiry and stop cannot interleave between taking the
            // handler and installing accepted state. Neither lookup uses discovery.
            duringInvitationAcceptance?()
            if accept { invitation.state = .accepted }
            else { invitations[remoteUUID] = nil; retirePhysical(invitation.session) }
            handler?(accept, accept ? invitation.session : nil)
            if !accept { enqueueEvent(peer: invitation.peer, bytes: 256) { service in
                service.radarDelegate?.scannerStatusChanged(manager: service, status: "invitationRejected", remoteUUID: remoteUUID)
            } }
            return true
        }
    }

    func expireInvitations() {
        withState {
            reapPhysicalSessions()
            let now = invitationClock()
            for setup in scheduledSetups.values where !setup.lease.isLive {
                // Revoke synchronously at expiry, while keeping the worker and
                // its reservation until noncooperative code actually returns.
                setup.physical.gate.session.close()
                bridgeSetupTasks[setup.physical.remoteUUID]?.task.cancel()
            }
            for (peer, lease) in discoveries where !lease.isLive {
                discoveries[peer] = nil
                if let remote = _reversedFoundPeersDict.removeValue(forKey: peer), _foundPeersDict[remote] == peer {
                    _foundPeersDict[remote] = nil; advertisementPeers.remove(remote); advertisementProofPeers.remove(remote)
                    enqueueEvent(peer: peer, bytes: 256) { service in
                        service.discoveredDevices = service.withState { service._foundPeersDict.values.map(\.displayName) }
                        service.radarDelegate?.lostDeviceChanged(manager: service, lostDevice: peer, remoteUUID: remote)
                    }
                }
            }
            for (id, event) in events where !event.lease.isLive {
                events[id] = nil; event.discard(); event.lease.release()
            }
            eventOrder.removeAll { events[$0] == nil }
            let expired = invitations.values.filter { $0.deadline <= now || !$0.admission.isLive }
            for invitation in expired {
                invitations[invitation.remoteUUID] = nil
                let handler = invitation.handler; invitation.handler = nil
                handler?(false, nil)
                retirePhysical(invitation.session)
                let remote = invitation.remoteUUID
                invitation.admission.release()
                enqueueEvent(peer: invitation.peer, bytes: 256) { service in
                    service.radarDelegate?.scannerStatusChanged(manager: service, status: "invitationExpired", remoteUUID: remote)
                }
            }
        }
    }

    func receiveInvitation(
        from peerID: MCPeerID,
        endpoint: BridgePeerChannelAuthentication.Endpoint? = nil,
        handler: @escaping (Bool, MCSession?) -> Void
    ) {
        withState {
            expireInvitations()
            let bound = invitations.values.first { $0.peer == peerID }
            guard !stopped, let remoteUUID = bound?.remoteUUID ?? _reversedFoundPeersDict[peerID],
                  bridgeTransportsByRemoteUUID[remoteUUID] == nil,
                  invitations[remoteUUID].map({ $0.peer == peerID }) ?? true else { handler(false, nil); return }
            if let endpoint {
                guard endpoint.initiator == remoteUUID, endpoint.responder == mySessionUUID, endpoint.domain == "nearby" else {
                    handler(false, nil); return
                }
            }
            if let existing = invitations[remoteUUID] {
                // Exactly one setup wins crossed invitations. Repeated pending
                // invitations never replace a handler or renew its deadline.
                guard existing.state == .outgoing, endpoint != nil, mySessionUUID > remoteUUID else { handler(false, nil); return }
            }
            let bytes = (endpoint.flatMap { try? BridgeChannelAuthentication.encode($0).count } ?? 0) + remoteUUID.utf8.count + 256
            guard let lease = admission.reserve(.invitation, peer: peerID, bytes: bytes, replacing: invitations[remoteUUID]?.admission) else {
                handler(false, nil); return
            }
            if let previous = invitations[remoteUUID] { retirePhysical(previous.session) }
            guard let session = try? newPeerSession(peerID) else { handler(false, nil); return }
            let invitation = Invitation(generation: serviceGeneration, peer: peerID, session: session,
                remoteUUID: remoteUUID, endpoint: endpoint, deadline: invitationClock() + invitationTimeout,
                state: .pending, admission: lease, handler: handler)
            // Reserve the notification before retaining a handler the user could
            // never see. Its delayed action rechecks the exact invitation ID.
            guard enqueueEvent(peer: peerID, bytes: bytes, action: { [weak invitation] service in
                guard let invitation, service.withState({ service.invitations[remoteUUID] === invitation && invitation.state == .pending }) else { return }
                service.radarDelegate?.invitationReceived(manager: service, peerID: peerID, remoteUUID: remoteUUID)
            }) else { invitations[remoteUUID] = nil; retirePhysical(session); handler(false, nil); return }
            invitations[remoteUUID] = invitation
        }
    }

    @discardableResult
    func prepareBridge(remoteUUID: String, peerID: MCPeerID) throws -> ScannerPeerTransport {
        try withState {
            if let current = bridgeTransportsByRemoteUUID[remoteUUID] {
                guard current.peerID == peerID, physicalSlots[ObjectIdentifier(current.mcSession)]?.retiring == false else { throw BridgeChannelAuthentication.Failure.identityMismatch }
                return current
            }
            expireInvitations()
            guard !stopped, let invitation = invitations[remoteUUID], invitation.peer == peerID,
                  physicalSlots[ObjectIdentifier(invitation.session)]?.retiring == false, invitation.generation == serviceGeneration,
                  invitation.state != .pending, let endpoint = invitation.endpoint,
                  !bridgeTransportsByRemoteUUID.values.contains(where: { $0.peerID == peerID }) else { throw BridgeChannelAuthentication.Failure.unavailable }
            let physical = ScannerPeerTransport(service: self, remoteUUID: remoteUUID, peerID: invitation.peer,
                                                session: invitation.session, endpoint: endpoint, invitationID: invitation.id)
            bridgeTransportsByRemoteUUID[remoteUUID] = physical
            do {
                physical.gate = try BridgeChannelTransport(underlying: physical, peerEndpoint: endpoint,
                    role: physical.role,
                    owner: owner, limits: channelLimits, source: invitation.admission.source,
                    disclosurePolicy: .anyProvenIdentity(allowUnauthenticatedInitiator: true)) { [weak self, weak physical] transport, _ in
                        guard let self, let physical else { throw CancellationError() }
                        try self.checkCurrent(physical, remoteUUID: remoteUUID)
                        let config = BridgeBase.Config(owner: self.owner, identityDomain: "nearby", transport: transport)
                        let bridge = try await BridgeBase(config)
                        try await bridge.setTransport(transport, connection: physical.isInitiator ? .inbound(publisherUuid: "Lobby") : .outbound)
                        try self.checkCurrent(physical, remoteUUID: remoteUUID)
                        physical.bridge = bridge
                        return bridge
                    }
                invitations[remoteUUID] = nil // gate now owns the immutable setup
                return physical
            } catch { bridgeTransportsByRemoteUUID[remoteUUID] = nil; invitations[remoteUUID] = nil; retirePhysical(invitation.session); throw error }
        }
    }
    private func checkCurrent(_ transport: ScannerPeerTransport, remoteUUID: String) throws {
        try Task.checkCancellation()
        try withState {
            guard bridgeTransportsByRemoteUUID[remoteUUID] === transport,
                  scheduledSetups[transport.setupID]?.lease.isLive ?? true else { throw CancellationError() }
        }
        try transport.gate.session.check()
    }
    func consumerContext(remoteUUID: String) throws -> ScannerConsumerContext {
        try withState {
            guard let physical = bridgeTransportsByRemoteUUID[remoteUUID] else { throw CancellationError() }
            return try consumerContext(on: physical)
        }
    }
    private func consumerContext(on physical: ScannerPeerTransport) throws -> ScannerConsumerContext {
        try checkCurrent(physical, remoteUUID: physical.remoteUUID)
        return try ScannerConsumerContext(service: self, physical: physical)
    }
    func consumerEffect<T>(on physical: ScannerPeerTransport, _ body: () throws -> T) throws -> T {
        try withState {
            guard !stopped, bridgeTransportsByRemoteUUID[physical.remoteUUID] === physical else { throw CancellationError() }
            return try physical.gate.session.withAuthenticatedEffect(body)
        }
    }
    func sendScannerFlowElement(_ element: FlowElement, context: ScannerConsumerContext) async throws {
        try context.check()
        let command = BridgeCommand(cmd: "response", payload: .flowElement(element), cid: -1)
        try await context.physical.gate.sendData(BridgeChannelAuthentication.encode(command))
        try context.check()
    }

    func setupBridge(remoteUUID: String, peerID: MCPeerID) async throws {
        try await setupBridge(prepareBridge(remoteUUID: remoteUUID, peerID: peerID))
    }
    private func setupBridge(_ physical: ScannerPeerTransport) async throws {
        let remoteUUID = physical.remoteUUID
        // A prior setup/registration must finish its cleanup before the same
        // remote cell UUID can be registered by a new generation.
        while let previous = withState({ bridgeSetupTasks[remoteUUID] }), previous.id != physical.setupID {
            _ = try? await previous.task.value
            withState { if bridgeSetupTasks[remoteUUID] === previous { bridgeSetupTasks[remoteUUID] = nil } }
            try Task.checkCancellation()
            guard withState({ bridgeTransportsByRemoteUUID[remoteUUID] === physical }) else { throw CancellationError() }
        }
        let operation = try withState { () throws -> BridgeSetupOperation? in
            guard bridgeTransportsByRemoteUUID[remoteUUID] === physical else { throw CancellationError() }
            if let existingOperation = bridgeSetupTasks[remoteUUID] {
                return existingOperation
            }
            if registeredBridgeUUIDsByRemoteUUID[remoteUUID] != nil {
                return nil
            }

            let setupID = physical.setupID
            let task = Task { [weak self] in
                guard let self else { return }
                try await self.performBridgeSetup(physical)
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
        catch { reportBridgeFailure(error, on: physical); await physical.gate.close(); throw error }
    }

    private func scheduleBridgeSetup(_ physical: ScannerPeerTransport) {
        withState {
            guard !stopped, bridgeTransportsByRemoteUUID[physical.remoteUUID] === physical,
                  registeredBridgeUUIDsByRemoteUUID[physical.remoteUUID] == nil,
                  !physical.setupScheduled, scheduledSetups[physical.setupID] == nil,
                  let lease = admission.reserve(.task, peer: physical.peerID, bytes: 256) else { return }
            physical.setupScheduled = true
            scheduledSetups[physical.setupID] = (physical, lease)
            Task { [weak self, physical] in
                defer { self?.withState { _ = self?.scheduledSetups.removeValue(forKey: physical.setupID) }; lease.release() }
                guard let self else { return }
                guard lease.isLive else { await physical.gate.close(); return }
                do {
                    try await self.setupBridge(physical)
                    guard lease.isLive else { throw CancellationError() }
                    try self.checkCurrent(physical, remoteUUID: physical.remoteUUID)
                    self.enqueueEvent(peer: physical.peerID, bytes: 256) { service in
                        guard service.withState({ service.bridgeTransportsByRemoteUUID[physical.remoteUUID] === physical }) else { return }
                        service.radarDelegate?.scannerStatusChanged(manager: service, status: "connected", remoteUUID: physical.remoteUUID)
                        service.startup()
                    }
                } catch { self.reportBridgeFailure(error, on: physical); await physical.gate.close() }
            }
        }
    }

    private func performBridgeSetup(_ peerTransport: ScannerPeerTransport) async throws {
        let remoteUUID = peerTransport.remoteUUID, peerID = peerTransport.peerID
        guard withState({ bridgeTransportsByRemoteUUID[remoteUUID] === peerTransport }) else { throw CancellationError() }
        try await peerTransport.gate.startPeer()
        try checkCurrent(peerTransport, remoteUUID: remoteUUID)
        try await peerTransport.gate.withAuthenticatedWork {
            guard let resolver = CellBase.defaultCellResolver else { throw CellBaseError.noResolver }
            guard let cellBridge = peerTransport.bridge else { throw BridgeChannelAuthentication.Failure.unavailable }
            try self.withState {
                guard self.bridgeTransportsByRemoteUUID[remoteUUID] === peerTransport else { throw CancellationError() }
                self._connectedPeersDict[peerID] = peerTransport.gate.session.publicIdentity?.makeIdentity()
                self._reversedConnectedPeersDict[remoteUUID] = peerID
            }

            var registeredUUID: String?
            do {
                if peerTransport.isInitiator {
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
                self.reportBridgeFailure(error, on: peerTransport)
                if let registeredUUID {
                    await resolver.unregisterEmitCell(uuid: registeredUUID)
                }
                self.withState {
                    guard self.bridgeTransportsByRemoteUUID[remoteUUID] === peerTransport else { return }
                    self.bridgeTransportsByRemoteUUID[remoteUUID] = nil
                    self._connectedPeersDict[peerID] = nil
                    self._reversedConnectedPeersDict[remoteUUID] = nil
                }
                throw error
            }
        }
    }

    @discardableResult
    private func removeBridge(for remoteUUID: String, expected: ScannerPeerTransport? = nil) -> Bool {
        withState {
            if let expected, bridgeTransportsByRemoteUUID[remoteUUID] !== expected { return false }
            let operation = bridgeSetupTasks[remoteUUID]
            let transport = bridgeTransportsByRemoteUUID.removeValue(forKey: remoteUUID)
            let registeredUUID = registeredBridgeUUIDsByRemoteUUID.removeValue(forKey: remoteUUID)
            guard transport != nil || registeredUUID != nil else { operation?.task.cancel(); return false }
            invitations[remoteUUID] = nil
            if let peer = transport?.peerID { _connectedPeersDict[peer] = nil }
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
            return true
        }
    }

    func updateInformationLabel(description: String) {
        print("Information label: \(description)")
    }


    
    /// Shared iOS production path; opaque archived bytes allow macOS tests to
    /// exercise selection, quotas and lifecycle without fabricating an NI token.
    @discardableResult
    func shareDiscoveryTokenData(_ encodedData: Data) async throws -> Int {
        let content: Object = ["token": .data(encodedData), "userUuid": .string(owner.uuid)]
        let flow = FlowElement(title: "DiscoveryToken", content: .object(content), properties: .init(type: .event, contentType: .object))
        let data = try JSONEncoder().encode(BridgeCommand(cmd: "response", payload: .flowElement(flow), cid: -1))
        let transports = withState { Array(bridgeTransportsByRemoteUUID.values) }
        var sent = 0
        for transport in transports where transport.gate.canSendPeerData {
            do { try await transport.gate.sendData(data); sent += 1 }
            catch { reportBridgeFailure(error, on: transport) }
        }
        return sent
    }

#if os(iOS)
    func shareMyDiscoveryToken(token: NIDiscoveryToken) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        Task { [weak self] in
            guard let self else { return }
            do { self.sharedTokenWithPeer = try await self.shareDiscoveryTokenData(data) > 0 }
            catch { self.reportBridgeFailure(error, remoteUUID: nil) }
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
            enqueueEvent(peer: myPeerId, bytes: 256) { service in
                service.radarDelegate?.scannerStatusChanged(manager: service, status: "precisionUnavailable", remoteUUID: service.connectedRemoteUUID)
            }
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
        // Bound context before decoding or creating main-actor work. Unknown
        // contexts are never downgraded into a bridge invitation.
        let bytes = (context?.count ?? 0) + 256
        guard bytes <= admission.configuration.invitation.perSourceBytes,
              let ingress = admission.reserve(.task, peer: peerID, bytes: bytes) else { invitationHandler(false, nil); return }
        if let context, let endpoint = try? BridgeChannelAuthentication.decode(BridgePeerChannelAuthentication.Endpoint.self, from: context) {
            receiveInvitation(from: peerID, endpoint: endpoint, handler: invitationHandler)
        } else if let context {
            let queued = enqueueEvent(peer: peerID, bytes: bytes, kind: .task, discard: { invitationHandler(false, nil) }, reserved: ingress) { service in
                guard let remoteID = service.withState({ service._reversedFoundPeersDict[peerID] }) else { invitationHandler(false, nil); return }
                if service.advertisementExchange?.accept(context: context, peer: peerID,
                    localPeer: service.myPeerId, reply: invitationHandler,
                    localSessionID: service.mySessionUUID, remoteSessionID: remoteID) == true { return }
                invitationHandler(false, nil)
            }
            if !queued { invitationHandler(false, nil) }
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
        guard let info, info.count <= 32, let remoteUUID = info["uuid"], !remoteUUID.isEmpty,
              remoteUUID != mySessionUUID, remoteUUID.utf8.count <= 512 else { return }
        // Incremental bounded byte count; never build a full names list or copy
        // the metadata before admission. Dictionary/string allocation by MC is
        // outside this application callback and is not claimed to be bounded.
        var bytes = 256 + peerID.displayName.utf8.count
        for (key, value) in info {
            guard key.utf8.count <= 4096 - bytes, value.utf8.count <= 4096 - bytes - key.utf8.count else { return }
            bytes += key.utf8.count + value.utf8.count
        }
        withState {
            expireInvitations()
            guard !stopped else { return }
            if let bound = bridgeTransportsByRemoteUUID[remoteUUID], bound.peerID != peerID { return }
            if bridgeTransportsByRemoteUUID.values.contains(where: { $0.peerID == peerID && $0.remoteUUID != remoteUUID }) { return }
            if let invitation = invitations[remoteUUID], invitation.peer != peerID { return }
            if invitations.values.contains(where: { $0.peer == peerID && $0.remoteUUID != remoteUUID }) { return }
            guard let lease = admission.reserve(.discovery, peer: peerID, bytes: bytes, replacing: discoveries[peerID]) else { return }
            if let previous = _reversedFoundPeersDict[peerID], previous != remoteUUID {
                _foundPeersDict[previous] = nil; advertisementPeers.remove(previous); advertisementProofPeers.remove(previous)
            }
            if let previous = _foundPeersDict[remoteUUID], previous != peerID {
                _reversedFoundPeersDict[previous] = nil; discoveries[previous] = nil
            }
            discoveries[peerID] = lease
            _foundPeersDict[remoteUUID] = peerID; _reversedFoundPeersDict[peerID] = remoteUUID
            if info["ad"] == "1" { advertisementPeers.insert(remoteUUID) } else { advertisementPeers.remove(remoteUUID) }
            if info["ad"] == "1", info["adp"] == "2" { advertisementProofPeers.insert(remoteUUID) } else { advertisementProofPeers.remove(remoteUUID) }
            enqueueEvent(peer: peerID, bytes: bytes) { [weak lease] service in
                guard let lease, service.withState({ service.discoveries[peerID] === lease && lease.isLive }) else { return }
                service.discoveredDevices = service.withState { service._foundPeersDict.values.map(\.displayName) }
                service.radarDelegate?.foundDevicesChanged(manager: service, foundDevice: peerID, remoteUUID: remoteUUID, discoveryInfo: info)
                service.radarDelegate?.scannerStatusChanged(manager: service, status: "peerFound", remoteUUID: remoteUUID)
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        withState {
            guard let remoteUUID = _reversedFoundPeersDict.removeValue(forKey: peerID), _foundPeersDict[remoteUUID] == peerID else { return }
            _foundPeersDict[remoteUUID] = nil; discoveries[peerID] = nil
            advertisementPeers.remove(remoteUUID); advertisementProofPeers.remove(remoteUUID)
            enqueueEvent(peer: peerID, bytes: 256) { service in
                guard service.withState({ service._foundPeersDict[remoteUUID] == nil }) else { return }
                service.discoveredDevices = service.withState { service._foundPeersDict.values.map(\.displayName) }
                service.radarDelegate?.lostDeviceChanged(manager: service, lostDevice: peerID, remoteUUID: remoteUUID)
                service.radarDelegate?.scannerStatusChanged(manager: service, status: "peerLost", remoteUUID: remoteUUID)
            }
        }
    }
    
    


}

extension ScannerService : MCSessionDelegate {
    
    /// Capture under the state lock, synchronously in the MC callback. No
    /// asynchronous worker may reselect a transport using discovery metadata.
    func capturePeerTransport(session: MCSession, peerID: MCPeerID, prepare: Bool = false) throws -> ScannerPeerTransport {
        try withState {
            guard let slot = physicalSlots[ObjectIdentifier(session)], slot.peer == peerID, !slot.retiring else { throw BridgeChannelAuthentication.Failure.unavailable }
            if let bound = bridgeTransportsByRemoteUUID.values.first(where: { $0.peerID == peerID && $0.mcSession === session }) { return bound }
            guard prepare, let invitation = invitations.values.first(where: { $0.peer == peerID && $0.session === session }) else {
                throw BridgeChannelAuthentication.Failure.unavailable
            }
            return try prepareBridge(remoteUUID: invitation.remoteUUID, peerID: peerID)
        }
    }

    func peerDisconnected(_ physical: ScannerPeerTransport) {
        withState {
            guard removeBridge(for: physical.remoteUUID, expected: physical) else { return }
            if _foundPeersDict[physical.remoteUUID] == physical.peerID { _foundPeersDict[physical.remoteUUID] = nil }
            if _reversedFoundPeersDict[physical.peerID] == physical.remoteUUID { _reversedFoundPeersDict[physical.peerID] = nil }
            if _connectedPeer == physical.peerID {
                _connectedPeer = nil; _connectedRemoteUUID = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.withState({ self._connectedPeer == nil }) else { return }
                    self.connectedPeerIdDisplayname = nil
                }
            }
            enqueueEvent(peer: physical.peerID, bytes: 256) { service in
                guard service.withState({ service.bridgeTransportsByRemoteUUID[physical.remoteUUID] == nil }) else { return }
                service.radarDelegate?.lostDeviceChanged(manager: service, lostDevice: physical.peerID, remoteUUID: physical.remoteUUID)
                service.radarDelegate?.scannerStatusChanged(manager: service, status: "disconnected", remoteUUID: physical.remoteUUID)
            }
        }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .notConnected { withState { reapPhysicalSessions() } }
        let physical = try? capturePeerTransport(session: session, peerID: peerID, prepare: state == .connected)
        // Retire synchronously; an old queued UI callback cannot retire a reconnect.
        if state == .notConnected, let physical { peerDisconnected(physical) }
        // An unbound MC callback carries no invitation instance ID. It may be
        // cancellation of an older timed-out attempt on this shared MCSession;
        // only the captured invitation deadline/explicit response may retire it.
        guard let physical else { return }
        enqueueEvent(peer: peerID, bytes: 256) { [weak physical] service in
            guard let physical else { return }
            service.connectedDevices = session.connectedPeers.map(\.displayName)
            service.radarDelegate?.connectedDevicesChanged(manager: service, connectedDevices: session.connectedPeers.map(\.displayName))
            guard service.withState({ service.bridgeTransportsByRemoteUUID[physical.remoteUUID] === physical }) else { return }
            switch state {
            case .connecting:
                service.radarDelegate?.scannerStatusChanged(manager: service, status: "connecting", remoteUUID: physical.remoteUUID)
            case .connected:
                service.connectedPublisher.send(true)
                service.connectedPeerIdDisplayname = physical.peerID.displayName
                service.connectedPeer = physical.peerID
                service.connectedRemoteUUID = physical.remoteUUID
                service.radarDelegate?.scannerStatusChanged(manager: service, status: "authenticating", remoteUUID: physical.remoteUUID)
                service.scheduleBridgeSetup(physical)
            default: break
            }
        }
    }

    public func connected() async throws {
        if self.connected == false {
            self.connected = try await self.connectedPublisher.getOneWithTimeout(1)
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let physical = try? capturePeerTransport(session: session, peerID: peerID, prepare: true) else { return }
        scheduleBridgeSetup(physical)
        physical.enqueueReceive(data) // preserve callback order before Task scheduling
    }

    private func rejectSideEntrance(session: MCSession, peer: MCPeerID) {
        withState {
            guard let slot = physicalSlots[ObjectIdentifier(session)], slot.peer == peer, !slot.retiring else { return }
            if let physical = try? capturePeerTransport(session: session, peerID: peer) {
                physical.gate.session.close()
            }
            // One synchronous, idempotent physical disconnect; no error fan-out.
            retirePhysical(session)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Always dispose the supplied object, even for a stale session callback.
        // Never select a replacement by discovery UUID or allocate failure Tasks.
        stream.close()
        sideEntranceRejectedForTesting?("stream", [.closed, .notOpen, .error].contains(stream.streamStatus))
        rejectSideEntrance(session: session, peer: peerID)
    }
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
        sideEntranceRejectedForTesting?("resource", progress.isCancelled)
        rejectSideEntrance(session: session, peer: peerID)
    }
    
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // MC owns the temporary URL lifetime. Do not open/move an unsolicited
        // resource or log peer-controlled names, paths, or error descriptions.
        rejectSideEntrance(session: session, peer: peerID)
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
    
    func handleOutOfBandFlowElement(_ flowElement: FlowElement, context: ScannerConsumerContext) async throws {
        try context.check()
        guard case let .object(contentObject) = flowElement.content else {
            try await radarDelegate?.scannerFlowReceived(manager: self, flowElement: flowElement, context: context)
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

        try await radarDelegate?.scannerFlowReceived(manager: self, flowElement: flowElement, context: context)
    }
    func extractCommandFromData(_ data: Data, from peerID: MCPeerID) async throws {
        let physical = try capturePeerTransport(session: sessionForPeer(peerID), peerID: peerID)
        try await physical.receiveData(data)
    }

    fileprivate func extractCommandFromData(_ data: Data, on physical: ScannerPeerTransport) async throws {
        guard withState({ bridgeTransportsByRemoteUUID[physical.remoteUUID] === physical }) else { throw CancellationError() }
        let gate = physical.gate!
        do {
            try gate.validateInboundPayload(data)
            let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
            if let identity = command.identity { identity.identityVault = await identityVault(for: identity, bridgeDelegate: physical.bridge) }
            if command.cmd.hasPrefix("channelAuth") {
                try await gate.consumeCommand(command: command)
                return
            }
            guard Command(rawValue: command.cmd) != nil else { throw ScannerServiceError.invalidCommand(command.cmd) }
            if command.cid < 0 {
                try gate.session.check(identity: command.identity)
                guard command.command == .response, case let .flowElement(flowElement) = command.payload else { throw BridgeChannelAuthentication.Failure.malformed }
                let context = try consumerContext(on: physical)
                try await gate.withAuthenticatedWork { try await self.handleOutOfBandFlowElement(flowElement, context: context) }
            } else if command.command == .response { try await gate.consumeResponse(command: command) }
            else { try await gate.consumeCommand(command: command) }
        } catch {
            reportBridgeFailure(error, on: physical)
            await gate.close()
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
        enqueueEvent(peer: myPeerId, bytes: 256) { service in
            service.radarDelegate?.proximityChanged(manager: service, remoteUUID: remoteUUID,
                distanceMeters: distanceMeters, directionX: directionX, directionY: directionY, directionZ: directionZ)
        }
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
