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

    func foundDevicesChanged(manager: ScannerService, foundDevice: MCPeerID, remoteUUID: String)
    func lostDeviceChanged(manager: ScannerService, lostDevice: MCPeerID, remoteUUID: String)
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
}

// Consider different name
class ScannerService :  NSObject, ObservableObject {

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
    
    var owner: Identity
    
    var foundPeersDict = Dictionary<String, MCPeerID>()
    var reversedFoundPeersDict = Dictionary<MCPeerID, String>()
    
    // Test
    var connectedPeersDict = Dictionary<MCPeerID, Identity>()
    var reversedConnectedPeersDict = Dictionary<String, MCPeerID>() // Identity.uuid, PeerID
    
    // Service type must be a unique string, at most 15 characters long
    // and can contain only ASCII lowercase letters, numbers and hyphens.
    private let HavenServiceType = "haven-radar"

    
    private let myPeerId: MCPeerID
    private let serviceAdvertiser : MCNearbyServiceAdvertiser
    private let serviceBrowser : MCNearbyServiceBrowser

    private var isInviting = false
    var radarDelegate : ConnectServiceDelegate?
    var bridgeDelegate: BridgeDelegateProtocol?

    let mySessionUUID = UUID().uuidString

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
    var connectedPeer: MCPeerID?
    var connectedRemoteUUID: String?
    
    lazy var mcSession : MCSession = {
        let session = MCSession(peer: self.myPeerId, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }()

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
        guard let peerID = foundPeersDict[normalizedUUID] else {
            print("Could not invite peer. Unknown remote UUID: \(normalizedUUID)")
            return
        }
        self.isInviting = true
        print("Inviting peer with remote UUID: \(normalizedUUID)")
        self.serviceBrowser.invitePeer(peerID, to: self.mcSession, withContext: nil, timeout: 10)
    }

    func sendScannerFlowElement(_ flowElement: FlowElement, remoteUUID: String? = nil) async throws {
        let bridgeCommand = BridgeCommand(cmd: "response", payload: .flowElement(flowElement), cid: -2)
        let encodedElement = try JSONEncoder().encode(bridgeCommand)
        try sendMultipeerData(encodedElement, remoteUUID: remoteUUID)
    }

    private func sendMultipeerData(_ data: Data, remoteUUID: String? = nil) throws {
        if let remoteUUID {
            guard let peerID = foundPeersDict[remoteUUID], mcSession.connectedPeers.contains(peerID) else {
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

    init(owner: Identity, serviceDicoveryInfoDict: [String : String] = ["interest" : "*"]) {
        myPeerId = MCPeerID(displayName: owner.displayName)
        
        self.owner = owner
        
        var serviceDicoveryInfo = serviceDicoveryInfoDict
        serviceDicoveryInfo["uuid"] = mySessionUUID
        
        self.serviceAdvertiser = MCNearbyServiceAdvertiser(peer: myPeerId, discoveryInfo: serviceDicoveryInfo, serviceType: HavenServiceType)
        self.serviceBrowser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: HavenServiceType)

        super.init()

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
        mcSession.disconnect()
        bridgeReady = false
        isInviting = false
        connectedRemoteUUID = nil
        radarDelegate?.scannerStatusChanged(manager: self, status: "stopped", remoteUUID: nil)
    }

    
    var bridgeReady = false
    
    func setupBridge(remoteUUID: String, peerID: MCPeerID) async throws {
        if bridgeReady == false {
            print("********* Setting up bridge ")
            bridgeReady = true
            guard let resolver = CellBase.defaultCellResolver else {
                throw CellBaseError.noResolver
            }
            let config = BridgeBase.Config(owner: owner, identityDomain: remoteUUID, transport: self)
            let cellBridge =  try await BridgeBase(config)
            
            self.bridgeDelegate = cellBridge
            self.connectedPeersDict[peerID] = owner
            
            if self.isInviting {
                try await cellBridge.setTransport(self, connection: .inbound(publisherUuid: "Lobby")) // For now there can be only one
                let readyCommand = BridgeCommand(cmd: "ready", payload: .string("shouldProbablyBePublicKey"), cid: 0)
                let readyJsonData = try JSONEncoder().encode(readyCommand)
                try await self.sendData(readyJsonData) // Just testing
                
                try await self.attachLobbyToEntityScanner(requester: owner)
                
            } else {
                try await cellBridge.retrieveProxyRepresentation(for: owner)
                let connectRadarCell = try await resolver.cellAtEndpoint(endpoint: "cell:///ConnectRadar", requester: owner)
                
                if let connectRadarCell = connectRadarCell as? CellProtocol {
                    let connectState = try await connectRadarCell.attach(emitter: cellBridge, label: "lobby", requester: owner)
                    if connectState != .connected {
                        print("Could not attach cellBridge to ConnectRadar!!!!")
                    }
                    
                    try await connectRadarCell.absorbFlow(label: "lobby", requester: owner)
                }
            }
            
            try await resolver.registerNamedEmitCell(name: remoteUUID, emitCell: cellBridge, scope: .scaffoldUnique, identity: owner)
            print("********* Finished setting up bridge ")
            print("WebSocket must be connected before this!")
            
        }
    }
    
    func updateInformationLabel(description: String) {
        print("Information label: \(description)")
    }

    private func isVerifiedLocalOwnerIdentity(_ identity: Identity) -> Bool {
        guard identity.uuid == owner.uuid else {
            return false
        }
        guard
            let ownerKey = owner.publicSecureKey?.compressedKey,
            let incomingKey = identity.publicSecureKey?.compressedKey
        else {
            return false
        }
        return ownerKey == incomingKey
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
        guard reversedFoundPeersDict[peerID] != nil else {
            print("Rejecting invitation from unknown peer: \(peerID.displayName)")
            invitationHandler(false, nil)
            return
        }
        invitationHandler(true, self.mcSession)
        
        // Setup bridge
    }

}

extension ScannerService : MCNearbyServiceBrowserDelegate {

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        NSLog("%@", "didNotStartBrowsingForPeers: \(error)")
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        NSLog("%@", "foundPeer: \(peerID) info: \(String(describing: info))")
//        NSLog("%@", "invitePeer: \(peerID)")
        guard let remoteUUID = info?["uuid"] else {
            print("Did not find remote uuid in info!")
            return
        }
        guard remoteUUID != mySessionUUID else {
            return
        }
        // if discovery info is interessting add peer
        foundPeersDict[remoteUUID] = peerID
        reversedFoundPeersDict[peerID] = remoteUUID
        
        self.discoveredDevices = Array(foundPeersDict.values.map{$0.displayName})
        print("Discovered devices: \(String(describing: self.discoveredDevices))")
        self.radarDelegate?.foundDevicesChanged(manager: self, foundDevice: peerID, remoteUUID: remoteUUID)
        self.radarDelegate?.scannerStatusChanged(manager: self, status: "peerFound", remoteUUID: remoteUUID)
        

        

        
        
//        browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        NSLog("%@", "lostPeer: \(peerID)")
        // remove from connected too?
        
        if let remoteUUID = reversedFoundPeersDict.removeValue(forKey: peerID) {
            self.foundPeersDict.removeValue(forKey: remoteUUID)
            self.radarDelegate?.lostDeviceChanged(manager: self, lostDevice: peerID, remoteUUID: remoteUUID)
            self.radarDelegate?.scannerStatusChanged(manager: self, status: "peerLost", remoteUUID: remoteUUID)
        }
        self.discoveredDevices = Array(foundPeersDict.values.map { $0.displayName })
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
                if let remoteUUID = self.reversedFoundPeersDict.removeValue(forKey: peerID) {
                    self.foundPeersDict.removeValue(forKey: remoteUUID)
                    self.radarDelegate?.lostDeviceChanged(manager: self, lostDevice: peerID, remoteUUID: remoteUUID)
                    self.radarDelegate?.scannerStatusChanged(manager: self, status: "disconnected", remoteUUID: remoteUUID)
                }
                if self.connectedPeer == peerID {
                    self.connectedPeer = nil
                }
                self.connectedRemoteUUID = nil
            case .connecting:
                print("***************** .connecting for \(peerID.displayName)")
                if let remoteUUID = self.reversedFoundPeersDict[peerID] {
                    self.radarDelegate?.scannerStatusChanged(manager: self, status: "connecting", remoteUUID: remoteUUID)
                    Task {
                        do {
                            try await self.setupBridge(remoteUUID: remoteUUID, peerID: peerID)
                        } catch {
                            print("Bridge setup failed with error: \(error)")
                        }
                        
                    }
                } else {
                    print("Did not find remoteUUID for peerID: \(peerID)")
                }
            case .connected:
                self.connectedPublisher.send(true)
                self.connectedPeerIdDisplayname = peerID.displayName
                print("***************** .connected for \(peerID.displayName)")
                self.connectedPeer = peerID
                if let remoteUUID = self.reversedFoundPeersDict[peerID] {
                    self.connectedRemoteUUID = remoteUUID
                    self.radarDelegate?.scannerStatusChanged(manager: self, status: "connected", remoteUUID: remoteUUID)
                } else {
                    self.radarDelegate?.scannerStatusChanged(manager: self, status: "connected", remoteUUID: nil)
                }
                self.startup()
               
                
                
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
        NSLog("%@", "didReceiveData: \(data)")
        Task { [weak self] in
            guard let self = self else { return }
            do {
                // Maybe wait for .connected state instead?
                if let remoteUUID = reversedFoundPeersDict[peerID] {
                    try await setupBridge(remoteUUID: remoteUUID, peerID: peerID)
                }
                try await self.extractCommandFromData(data, from: peerID)
            } catch {
                print("Failed to extract command. Error: \(error)")
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
extension ScannerService : BridgeTransportProtocol {
    // BridgeTransportProtocol methods
    func setDelegateSource(_ source: (() async throws -> (any BridgeDelegateProtocol)?)?) { // probably not in use
        print("RadarService setDelegateSource (not used?)")
    }
    
    func setDelegate(_ delegate: any BridgeDelegateProtocol) {
        print("RadarService setDelegate")
        self.bridgeDelegate = delegate
    }
    
    func setup(_ endpointURL: URL, identity: Identity) async throws {
        print("RadarService setup")
    }
    
    func sendData(_ data: Data) async throws {
        print("RadarService sendData")
        do {
            try sendMultipeerData(data)
        } catch let error {
            NSLog("%@", "Error for sending: \(error)")
            throw error
        }
    }
    
    func identityVault(for identity: Identity?) async -> any IdentityVaultProtocol {
        if let identity, isVerifiedLocalOwnerIdentity(identity) {
            if let vault = CellBase.defaultIdentityVault {
                return vault
            }
        }
        let bridge = bridgeDelegate as? BridgeProtocol
        return BridgeIdentityVault(cloudBridge: bridge)
    }
    
    static func new() -> any BridgeTransportProtocol { // Is this used?
        print("Should this be used at all?")
        return ScannerService(owner: Identity())
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
    // BridgeDelegateProtocol
    private func  extractCommandFromData(_ data: Data, from peerID: MCPeerID? = nil) async throws {
        print("extract command: \(String(describing: String(data: data, encoding: .utf8)))")
//        try await connected()
        let decoder = JSONDecoder()
        do {
            let bridgeCommand = try decoder.decode(BridgeCommand.self, from: data)
            if bridgeCommand.cid < 0 {
                if case let .flowElement(flowElement) = bridgeCommand.payload {
                    let remoteUUID = peerID.flatMap { self.reversedFoundPeersDict[$0] } ?? self.connectedRemoteUUID
                    handleOutOfBandFlowElement(flowElement, remoteUUID: remoteUUID)
                }
                return
            }
            if let delegate = bridgeDelegate {
                let currentCommand = Command(rawValue:  bridgeCommand.cmd)!
                
                switch currentCommand {
                case .response:
                    try await delegate.consumeResponse(command: bridgeCommand)
                default:
                    try await delegate.consumeCommand(command: bridgeCommand)
                }
            } else {
                print("Extract command failed!")
            }
        } catch {
            print("Decoding bridge command in RadarService failed with error: \(error)")
        }
    }
    
    // This is called if this is the inviting device - which invites into the lobby
    func attachLobbyToEntityScanner(requester: Identity) async throws {
        
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        
        
        let connectRadarCell = try await resolver.cellAtEndpoint(endpoint: "cell:///EntityScanner", requester: requester)
        let lobbyCell = try await resolver.cellAtEndpoint(endpoint: "cell:///Lobby", requester: requester)
        
        if let connectRadarCell = connectRadarCell as? CellProtocol,
           let  lobbyCell = lobbyCell as? CellProtocol {
            let connectState = try await connectRadarCell.attach(emitter: lobbyCell, label: "lobby", requester: requester)
            if connectState != .connected {
                print("Could not attach cellBridge to EntityScanner!!!!")
            }
            
            try await connectRadarCell.absorbFlow(label: "lobby", requester: requester	)
            let startResponse = try await lobbyCell.get(keypath: "start", requester: requester)
            print("startResponse: \(startResponse)")
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
