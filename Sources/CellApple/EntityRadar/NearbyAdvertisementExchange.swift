import Foundation
import MultipeerConnectivity
import CellBase

/// Short-lived excerpt sessions. No Cell bridge or UWB pairing is installed.
@MainActor
final class NearbyAdvertisementExchange {
    private var publication: NearbyAdvertisement?
    private var sessions: [UUID: AdvertisementSession] = [:]
    private var lastRequestByPeer: [MCPeerID: Date] = [:]
    private var outgoingID: UUID?
    private var proofSessions: [UUID: AdvertisementProofSession] = [:]
    private var outgoingProofID: UUID?
    var authorizeProof: AdvertisementProofSession.Authorization?

    var currentPublication: NearbyAdvertisement? {
        guard let publication, (try? publication.validate()) != nil else { return nil }
        return publication
    }

    func publish(_ value: NearbyAdvertisement?) throws {
        if let value {
            try value.validate()
        }
        publication = value
        cancelSessions()
    }

    func stop() { publication = nil; cancelSessions(); lastRequestByPeer.removeAll() }

    private func cancelSessions() {
        let active = Array(sessions.values)
        sessions.removeAll(); outgoingID = nil
        active.forEach { $0.finish(nil) }
        let proofs = Array(proofSessions.values)
        proofSessions.removeAll(); outgoingProofID = nil
        proofs.forEach { $0.finish(.unavailable) }
    }

    func accept(context: Data, peer: MCPeerID, localPeer: MCPeerID,
                reply: @escaping (Bool, MCSession?) -> Void,
                localSessionID: String? = nil, remoteSessionID: String? = nil) -> Bool {
        if context.count <= 256,
           let request = try? JSONDecoder().decode(NearbyAdvertisementV2Envelope.self, from: context),
           request.protocolName == NearbyAdvertisementV2Envelope.protocolName {
            guard request.challenge == nil, request.proof == nil, request.advertisement == nil, request.denied == nil,
                  let localSessionID, let remoteSessionID, currentPublication != nil,
                  sessions.count + proofSessions.count < 3,
                  Date().timeIntervalSince(lastRequestByPeer[peer] ?? .distantPast) >= 2 else { reply(false, nil); return true }
            if lastRequestByPeer.count >= 256 { lastRequestByPeer = lastRequestByPeer.filter { Date().timeIntervalSince($0.value) < 10 } }
            guard lastRequestByPeer.count < 256 else { reply(false, nil); return true }
            lastRequestByPeer[peer] = Date()
            let id = UUID()
            let channel = AdvertisementProofSession(localPeer: localPeer, peer: peer,
                localID: localSessionID, remoteID: remoteSessionID, requestID: request.requestID,
                publication: { [weak self] in self?.currentPublication }, authorize: authorizeProof) { [weak self] _ in
                    self?.proofSessions[id] = nil
                }
            proofSessions[id] = channel; reply(true, channel.session); return true
        }
        guard context.count <= 256,
              let request = try? JSONDecoder().decode(NearbyAdvertisementEnvelope.self, from: context),
              request.protocolName == NearbyAdvertisementEnvelope.protocolName else { return false }
        guard request.advertisement == nil, let publication = currentPublication,
              publication.scope == .nearby, sessions.count + proofSessions.count < 3,
              Date().timeIntervalSince(lastRequestByPeer[peer] ?? .distantPast) >= 2 else {
            reply(false, nil); return true
        }
        if lastRequestByPeer.count >= 256 { lastRequestByPeer = lastRequestByPeer.filter { Date().timeIntervalSince($0.value) < 10 } }
        guard lastRequestByPeer.count < 256 else { reply(false, nil); return true }
        lastRequestByPeer[peer] = Date()
        let id = UUID()
        let envelope = NearbyAdvertisementEnvelope(requestID: request.requestID, advertisement: publication)
        let session = AdvertisementSession(localPeer: localPeer, remotePeer: peer, requestID: request.requestID,
                                           response: envelope) { [weak self] _ in self?.sessions[id] = nil }
        sessions[id] = session
        reply(true, session.session)
        return true
    }

    func read(peer: MCPeerID, localPeer: MCPeerID, browser: MCNearbyServiceBrowser) async -> NearbyAdvertisement? {
        if let outgoingID { sessions.removeValue(forKey: outgoingID)?.finish(nil) }
        if let outgoingProofID { proofSessions.removeValue(forKey: outgoingProofID)?.finish(.unavailable) }
        guard sessions.count + proofSessions.count < 3 else { return nil }
        let id = UUID(); outgoingID = id
        return await withCheckedContinuation { continuation in
            let request = NearbyAdvertisementEnvelope(requestID: id)
            let session = AdvertisementSession(localPeer: localPeer, remotePeer: peer, requestID: id,
                                               response: nil) { [weak self] result in
                self?.sessions[id] = nil
                if self?.outgoingID == id { self?.outgoingID = nil }
                continuation.resume(returning: result)
            }
            sessions[id] = session
            browser.invitePeer(peer, to: session.session, withContext: try? JSONEncoder().encode(request), timeout: 6)
        }
    }

    func readWithProof(peer: MCPeerID, localPeer: MCPeerID, localID: String, remoteID: String,
                       browser: MCNearbyServiceBrowser, reader: Identity,
                       evidence: NearbyAccessEvidence? = nil, consentedPolicy: String? = nil) async -> NearbyAdvertisementReadResult {
        if let outgoingID { sessions.removeValue(forKey: outgoingID)?.finish(nil) }
        if let outgoingProofID { proofSessions.removeValue(forKey: outgoingProofID)?.finish(.unavailable) }
        guard sessions.count + proofSessions.count < 3 else { return .unavailable }
        let id = UUID(); outgoingProofID = id
        return await withCheckedContinuation { continuation in
            let channel = AdvertisementProofSession(localPeer: localPeer, peer: peer,
                localID: localID, remoteID: remoteID, requestID: id, reader: reader,
                evidence: evidence, consentedPolicy: consentedPolicy) { [weak self] result in
                    self?.proofSessions[id] = nil
                    if self?.outgoingProofID == id { self?.outgoingProofID = nil }
                    continuation.resume(returning: result)
                }
            proofSessions[id] = channel
            browser.invitePeer(peer, to: channel.session,
                withContext: try? JSONEncoder().encode(NearbyAdvertisementV2Envelope(requestID: id)), timeout: 6)
        }
    }
}

@MainActor
final class AdvertisementSession: NSObject, MCSessionDelegate {
    let session: MCSession
    private let remotePeer: MCPeerID
    private let requestID: UUID
    private let response: NearbyAdvertisementEnvelope?
    private var completion: ((NearbyAdvertisement?) -> Void)?
    private var timeout: Task<Void, Never>?

    init(localPeer: MCPeerID, remotePeer: MCPeerID, requestID: UUID, response: NearbyAdvertisementEnvelope?,
         completion: @escaping (NearbyAdvertisement?) -> Void) {
        session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        self.remotePeer = remotePeer; self.requestID = requestID; self.response = response; self.completion = completion
        super.init()
        session.delegate = self
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }; self?.finish(nil)
        }
    }

    func finish(_ advertisement: NearbyAdvertisement?) {
        guard let completion else { return }
        self.completion = nil; timeout?.cancel(); timeout = nil
        session.disconnect(); completion(advertisement)
    }

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self, completion != nil, peerID == remotePeer else { return }
            if state == .connected, let response {
                guard let advertisement = response.advertisement, (try? advertisement.validate()) != nil,
                      let data = try? JSONEncoder().encode(response) else { finish(nil); return }
                do { try session.send(data, toPeers: [remotePeer], with: .reliable) } catch { finish(nil) }
            } else if state == .notConnected { finish(nil) }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= NearbyAdvertisement.maximumWireBytes + 512 else { return }
        Task { @MainActor [weak self] in
            guard let self, response == nil, peerID == remotePeer,
                  let envelope = try? JSONDecoder().decode(NearbyAdvertisementEnvelope.self, from: data),
                  envelope.protocolName == NearbyAdvertisementEnvelope.protocolName,
                  envelope.requestID == requestID,
                  let advertisement = envelope.advertisement, advertisement.scope == .nearby,
                  (try? advertisement.validate()) != nil else { return }
            finish(advertisement)
        }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
