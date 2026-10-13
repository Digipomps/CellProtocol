// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import XCTest
import Foundation
@testable import CellBase

final class BridgeChannelSequenceTests: XCTestCase {
    typealias A = BridgeChannelAuthentication
    private func endpoint() throws -> A.Endpoint { try .init(url: URL(string: "wss://sequence.example/bridgehead/Protected/client")!, domain: "bridge") }
    private func frame(_ name: String, _ value: some Encodable) throws -> Data {
        try A.encode(BridgeCommand(cmd: name, payload: .string(String(decoding: try A.encode(value), as: UTF8.self)), cid: 0))
    }
    private func payload<T: Codable>(_ type: T.Type, _ command: BridgeCommand) throws -> T {
        guard case let .string(value) = command.payload else { throw A.Failure.malformed }
        return try A.decode(type, from: Data(value.utf8))
    }
    func testServerRejectsWellFormedWrongOrderRepeatedAndUnknownAuthenticationFrames() async throws {
        let old = CellBase.defaultCellResolver; defer { CellBase.defaultCellResolver = old }
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        for scenario in ["proof-first", "accepted-first", "challenge-first", "unknown", "hello-twice", "proof-twice", "unknown-profile"] {
            let owner = await MockIdentityVault().identity(for: scenario, makeNewIfNotFound: true)!
            let wire = SequenceWire(), target = try endpoint(), counter = SequenceCount()
            let server = try BridgeChannelTransport(underlying: wire, endpoint: target, limits: BridgeChannelLimits(), source: scenario) { transport, _ in
                counter.increment()
                let bridge = BridgeBase(owner: owner)
                try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Protected"))
                return bridge
            }
            let client = try BridgeChannelClientOperation(owner: owner, endpoint: target)
            let foreignServer = try BridgeChannelSession(endpoint: target)
            let challenge = try foreignServer.issueChallenge(client.hello)
            let proof = try await client.sign(challenge)
            try foreignServer.reserveOpen(proof); let accepted = try foreignServer.activate()
            var rejected: Data
            switch scenario {
            case "proof-first": rejected = try frame("channelAuthProof", proof)
            case "accepted-first": rejected = try frame("channelAuthAccepted", accepted)
            case "challenge-first": rejected = try frame("channelAuthChallenge", challenge)
            case "unknown": rejected = try frame("channelAuthUnknown", client.hello)
            case "unknown-profile":
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: A.encode(client.hello)) as? [String: Any])
                object["profile"] = "legacy-ready"
                let changed = try JSONDecoder().decode(A.Hello.self, from: JSONSerialization.data(withJSONObject: object))
                rejected = try frame("channelAuthHello", changed)
            default:
                let localClient = try BridgeChannelClientOperation(owner: owner, endpoint: target)
                let hello = try frame("channelAuthHello", localClient.hello)
                try await wire.deliver(hello)
                if scenario == "hello-twice" { rejected = hello }
                else {
                    let actual = try payload(A.Challenge.self, XCTUnwrap(wire.snapshot.last))
                    rejected = try frame("channelAuthProof", await localClient.sign(actual))
                    try await wire.deliver(rejected)
                    XCTAssertEqual(server.session.state, .authenticated)
                    XCTAssertEqual(counter.value, 1)
                }
            }
            do { try await wire.deliver(rejected); XCTFail("Accepted \(scenario)") } catch {}
            XCTAssertEqual(server.session.state, .closed, scenario)
            XCTAssertEqual(counter.value, scenario == "proof-twice" ? 1 : 0, scenario)
            XCTAssertEqual(resolver.lookupCountSnapshot(), 0, "Auth-only traffic must not look up cells")
            await server.close(); foreignServer.close()
        }
    }

    func testClientRejectsWellFormedWrongOrderRepeatedAndUnknownAuthenticationFrames() async throws {
        let old = CellBase.defaultCellResolver; defer { CellBase.defaultCellResolver = old }
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        for scenario in ["hello", "proof", "accepted-before-challenge", "unknown", "challenge-twice", "accepted-twice"] {
            let owner = await MockIdentityVault().identity(for: scenario, makeNewIfNotFound: true)!
            let target = try endpoint(), wire = SequenceWire(), helloSent = expectation(description: scenario)
            wire.onHello = { helloSent.fulfill() }
            let client = try BridgeChannelTransport(underlying: wire, endpoint: target)
            let setup = Task { try await client.setup(URL(string: target.audience)!, identity: owner) }
            await fulfillment(of: [helloSent], timeout: 2)
            let hello = try payload(A.Hello.self, XCTUnwrap(wire.snapshot.first))
            let server = try BridgeChannelSession(endpoint: target)
            let challenge = try server.issueChallenge(hello)
            let signature = try await owner.identityVault!.signMessageForIdentity(messageData: challenge.signingData, identity: owner)
            let proof = A.Proof(sessionID: challenge.transcript.sessionID, generation: challenge.transcript.generation, signature: signature)
            try server.reserveOpen(proof); let accepted = try server.activate()
            let rejected: Data
            switch scenario {
            case "hello": rejected = try frame("channelAuthHello", hello)
            case "proof": rejected = try frame("channelAuthProof", proof)
            case "accepted-before-challenge": rejected = try frame("channelAuthAccepted", accepted)
            case "unknown": rejected = try frame("channelAuthUnknown", hello)
            default:
                try await wire.deliver(frame("channelAuthChallenge", challenge))
                if scenario == "challenge-twice" { rejected = try frame("channelAuthChallenge", challenge) }
                else {
                    try await wire.deliver(frame("channelAuthAccepted", accepted))
                    try await setup.value
                    rejected = try frame("channelAuthAccepted", accepted)
                }
            }
            do { try await wire.deliver(rejected); XCTFail("Accepted \(scenario)") } catch {}
            _ = try? await setup.value
            XCTAssertEqual(client.session.state, .closed, scenario)
            XCTAssertEqual(resolver.lookupCountSnapshot(), 0)
            await client.close(); server.close()
        }
    }
}

private final class SequenceWire: BridgeTransportProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var delegate: BridgeDelegateProtocol?
    private var sent: [BridgeCommand] = []
    var onHello: (() -> Void)?
    var snapshot: [BridgeCommand] { lock.withLock { sent } }
    static func new() -> BridgeTransportProtocol { SequenceWire() }
    func setDelegate(_ delegate: BridgeDelegateProtocol) { lock.withLock { self.delegate = delegate } }
    func setup(_ endpointURL: URL, identity: Identity) async throws {}
    func sendData(_ data: Data) async throws {
        let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
        lock.withLock { sent.append(command) }
        if command.cmd == "channelAuthHello" { onHello?() }
    }
    func deliver(_ data: Data) async throws {
        let target = try XCTUnwrap(lock.withLock { delegate })
        try target.validateInboundPayload(data)
        try await target.consumeCommand(command: JSONDecoder().decode(BridgeCommand.self, from: data))
    }
    func close() async {}
    func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
}
private final class SequenceCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
