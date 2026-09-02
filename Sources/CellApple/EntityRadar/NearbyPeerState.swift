import Foundation

public enum NearbyPeerState: String, Codable, CaseIterable, Sendable {
    case discovered
    case beaconMatched
    case probing
    case probed
    case contactRequested
    case contactAccepted
    case connected
    case agreementPending
    case agreementSigned
    case lost
    case rejected
    case expired
}

public struct NearbyPeerStateMachine: Codable, Equatable, Sendable {
    public private(set) var state: NearbyPeerState

    public init(state: NearbyPeerState = .discovered) {
        self.state = state
    }

    public mutating func transition(to next: NearbyPeerState) throws {
        guard Self.allowedTransitions[state, default: []].contains(next) else {
            throw TransitionError.illegal(from: state, to: next)
        }
        state = next
    }

    private static let terminalStates: Set<NearbyPeerState> = [.lost, .rejected, .expired]
    private static let allowedTransitions: [NearbyPeerState: Set<NearbyPeerState>] = {
        var transitions: [NearbyPeerState: Set<NearbyPeerState>] = [
            .discovered: [.beaconMatched, .contactRequested],
            .beaconMatched: [.probing, .contactRequested],
            .probing: [.probed, .beaconMatched],
            .probed: [.contactRequested, .probing],
            .contactRequested: [.contactAccepted],
            .contactAccepted: [.connected],
            .connected: [.agreementPending],
            .agreementPending: [.agreementSigned]
        ]
        for state in NearbyPeerState.allCases where !terminalStates.contains(state) {
            transitions[state, default: []].formUnion(terminalStates)
        }
        return transitions
    }()

    public enum TransitionError: Error, Equatable {
        case unknownPeer(remoteUUID: String)
        case illegal(from: NearbyPeerState, to: NearbyPeerState)
    }
}
