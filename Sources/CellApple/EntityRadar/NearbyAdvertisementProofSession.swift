import Foundation
import MultipeerConnectivity
import CellBase

public struct NearbyAccessChallenge: Codable, Equatable {
    public var requestID: UUID
    public var nonce: UUID
    public var publisherSessionID: String
    public var readerSessionID: String
    public var policy: NearbyAccessAgreement
    public var expiresAt: TimeInterval
}

struct NearbyProofPresentation: Codable {
    var challenge: NearbyAccessChallenge
    var reader: Identity
    var evidence: NearbyAccessEvidence
    var signature: Data

    private struct SigningPayload: Codable {
        let purpose = "haven-nearby-advertisement-proof-v2"
        var challenge: NearbyAccessChallenge
        var readerDID: String
        var evidenceHash: String
    }
    func signingData() throws -> Data {
        try NearbyAccessAgreement.canonical(SigningPayload(challenge: challenge, readerDID: reader.did(),
            evidenceHash: FlowHasher.sha256Hex(NearbyAccessAgreement.canonical(evidence))))
    }
    static func signed(challenge: NearbyAccessChallenge, evidence: NearbyAccessEvidence, reader: Identity) async throws -> Self {
        var proof = Self(challenge: challenge, reader: reader.publicIdentitySnapshot(), evidence: evidence, signature: Data())
        guard let signature = try await reader.sign(data: proof.signingData()) else { throw NearbyAccessAgreement.AccessError.invalidProof }
        proof.signature = signature; return proof
    }
    func verifies(challenge expected: NearbyAccessChallenge, now: Date = Date()) -> Bool {
        guard challenge == expected, expected.expiresAt.isFinite,
              expected.expiresAt > now.timeIntervalSince1970, expected.expiresAt <= now.timeIntervalSince1970 + 10,
              let bytes = try? signingData() else { return false }
        return IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: bytes, identity: reader)
    }
}

struct NearbyAdvertisementReadResult {
    var advertisement: NearbyAdvertisement?
    var challenge: NearbyAccessChallenge?
    var message: String
    static let unavailable = Self(message: "Ingen tilgjengelige annonserte detaljer.")
}

struct NearbyAdvertisementV2Envelope: Codable {
    static let protocolName = "haven-advertisement-v2"
    var protocolName = Self.protocolName
    var requestID: UUID
    var challenge: NearbyAccessChallenge?
    var proof: NearbyProofPresentation?
    var advertisement: NearbyAdvertisement?
    var denied: Bool?
}

/// A bounded request / challenge / proof / response channel. Authorization is
/// provided by EntityScannerCell; no Agreement is installed by this transport.
@MainActor
final class AdvertisementProofSession: NSObject, MCSessionDelegate {
    typealias Authorization = (NearbyAccessEvidence, NearbyAccessAgreement, Identity) async -> Bool
    let session: MCSession
    private let peer: MCPeerID
    private let requestID: UUID
    private let localID: String
    private let remoteID: String
    private let publication: (() -> NearbyAdvertisement?)?
    private let authorize: Authorization?
    private let reader: Identity?
    private let evidence: NearbyAccessEvidence?
    private let consentedPolicy: String?
    private var issuedChallenge: NearbyAccessChallenge?
    private var completion: ((NearbyAdvertisementReadResult) -> Void)?
    private var timeout: Task<Void, Never>?
    private var proofProcessing = false

    init(localPeer: MCPeerID, peer: MCPeerID, localID: String, remoteID: String, requestID: UUID,
         publication: (() -> NearbyAdvertisement?)? = nil, authorize: Authorization? = nil,
         reader: Identity? = nil, evidence: NearbyAccessEvidence? = nil, consentedPolicy: String? = nil,
         completion: @escaping (NearbyAdvertisementReadResult) -> Void) {
        session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        self.peer = peer; self.localID = localID; self.remoteID = remoteID; self.requestID = requestID
        self.publication = publication; self.authorize = authorize; self.reader = reader
        self.evidence = evidence; self.consentedPolicy = consentedPolicy; self.completion = completion
        super.init(); session.delegate = self
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }; self?.finish(.unavailable)
        }
    }
    func finish(_ result: NearbyAdvertisementReadResult) {
        guard let completion else { return }
        self.completion = nil; timeout?.cancel(); timeout = nil
        session.disconnect(); completion(result)
    }
    private func send(_ envelope: NearbyAdvertisementV2Envelope) {
        guard completion != nil, let data = try? JSONEncoder().encode(envelope), data.count <= 262_144 else { finish(.unavailable); return }
        do { try session.send(data, toPeers: [peer], with: .reliable) } catch { finish(.unavailable) }
    }
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self, completion != nil, peerID == peer else { return }
            if state == .notConnected { finish(.unavailable); return }
            guard state == .connected, let publication else { return }
            guard let ad = publication(), (try? ad.validate()) != nil else { send(.init(requestID: requestID, denied: true)); return }
            if ad.scope == .nearby { send(.init(requestID: requestID, advertisement: ad)); return }
            guard let policy = ad.accessAgreement else { send(.init(requestID: requestID, denied: true)); return }
            let challenge = NearbyAccessChallenge(requestID: requestID, nonce: UUID(), publisherSessionID: localID,
                readerSessionID: remoteID, policy: policy, expiresAt: Date().timeIntervalSince1970 + 8)
            issuedChallenge = challenge
            send(.init(requestID: requestID, challenge: challenge))
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= 262_144 else { return }
        Task { @MainActor [weak self] in
            guard let self, completion != nil, peerID == peer,
                  let envelope = try? JSONDecoder().decode(NearbyAdvertisementV2Envelope.self, from: data),
                  envelope.protocolName == NearbyAdvertisementV2Envelope.protocolName, envelope.requestID == requestID else { return }
            if publication != nil {
                guard !proofProcessing, let proof = envelope.proof, let issuedChallenge,
                      proof.verifies(challenge: issuedChallenge), let authorize else { return }
                proofProcessing = true
                let allowed = await authorize(proof.evidence, issuedChallenge.policy, proof.reader)
                guard completion != nil else { return }
                guard allowed, issuedChallenge.expiresAt > Date().timeIntervalSince1970,
                      let ad = publication?(), ad.accessAgreement?.digest == issuedChallenge.policy.digest,
                      (try? ad.validate()) != nil else { send(.init(requestID: requestID, denied: true)); return }
                send(.init(requestID: requestID, advertisement: ad))
            } else if let challenge = envelope.challenge {
                guard !proofProcessing else { return }
                guard challenge.requestID == requestID, challenge.publisherSessionID == remoteID,
                      challenge.readerSessionID == localID, challenge.expiresAt.isFinite,
                      challenge.expiresAt > Date().timeIntervalSince1970,
                      challenge.expiresAt <= Date().timeIntervalSince1970 + 10,
                      (try? challenge.policy.validate()) != nil else { finish(.unavailable); return }
                guard let evidence, let reader, consentedPolicy == challenge.policy.digest else {
                    finish(.init(challenge: challenge, message: "Dette utdraget krever bevis. Alle vilkårene må være oppfylt.")); return
                }
                proofProcessing = true
                do {
                    let proof = try await NearbyProofPresentation.signed(challenge: challenge, evidence: evidence, reader: reader)
                    send(.init(requestID: requestID, proof: proof))
                } catch { finish(.init(challenge: challenge, message: "Kunne ikke signere bevispresentasjonen.")) }
            } else if let ad = envelope.advertisement, (try? ad.validate()) != nil {
                guard ad.scope == .nearby || (evidence != nil && ad.accessAgreement?.digest == consentedPolicy) else { finish(.unavailable); return }
                finish(.init(advertisement: ad, message: "Annonserte detaljer mottatt."))
            } else if envelope.denied == true {
                finish(.init(message: "Beviset ble ikke godkjent, er utløpt eller vilkårene er endret."))
            }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
