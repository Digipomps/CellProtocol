import XCTest
@testable import CellApple

final class NearbyPeerStateMachineTests: XCTestCase {
    func testEveryForwardTransitionIsLegal() throws {
        var machine = NearbyPeerStateMachine()
        for state in [
            NearbyPeerState.beaconMatched,
            .probing,
            .probed,
            .contactRequested,
            .contactAccepted,
            .connected,
            .agreementPending,
            .agreementSigned
        ] {
            try machine.transition(to: state)
            XCTAssertEqual(machine.state, state)
        }
    }

    func testTerminalTransitionsAreLegalFromEveryNonTerminalState() throws {
        let nonTerminalStates = NearbyPeerState.allCases.filter {
            ![NearbyPeerState.lost, .rejected, .expired].contains($0)
        }
        for start in nonTerminalStates {
            for terminal in [NearbyPeerState.lost, .rejected, .expired] {
                var machine = NearbyPeerStateMachine(state: start)
                try machine.transition(to: terminal)
                XCTAssertEqual(machine.state, terminal)
            }
        }
    }

    func testProbedCanTransitionBackToProbing() throws {
        var machine = NearbyPeerStateMachine(state: .probed)
        try machine.transition(to: .probing)
        XCTAssertEqual(machine.state, .probing)
    }

    func testProbingCanTransitionBackToBeaconMatched() throws {
        var machine = NearbyPeerStateMachine(state: .probing)
        try machine.transition(to: .beaconMatched)
        XCTAssertEqual(machine.state, .beaconMatched)
    }

    func testEveryUnspecifiedTransitionThrows() {
        let legalPairs: Set<String> = [
            "discovered>beaconMatched", "discovered>contactRequested",
            "beaconMatched>probing", "beaconMatched>contactRequested",
            "probing>probed", "probing>beaconMatched",
            "probed>contactRequested", "probed>probing",
            "contactRequested>contactAccepted", "contactAccepted>connected",
            "connected>agreementPending", "agreementPending>agreementSigned"
        ]
        let terminals = Set([NearbyPeerState.lost, .rejected, .expired])

        for start in NearbyPeerState.allCases {
            for end in NearbyPeerState.allCases where start != end {
                let key = "\(start.rawValue)>\(end.rawValue)"
                let shouldBeLegal = !terminals.contains(start) && (terminals.contains(end) || legalPairs.contains(key))
                guard !shouldBeLegal else { continue }
                var machine = NearbyPeerStateMachine(state: start)
                XCTAssertThrowsError(try machine.transition(to: end), "Expected \(key) to throw")
            }
        }
    }
}
