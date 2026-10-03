// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

/// Unit tests below the wire handshake still need an actual verified admission.
/// This helper signs a fresh challenge using synthetic fixture keys; production
/// has no pre-authenticated/ready-only constructor or testing bypass.
func authenticateBridgeFixture(_ bridge: BridgeBase, principal: Identity, signer: IdentityVaultProtocol? = nil, activate: Bool = true) async throws {
    let session = try await authenticatedSessionFixture(principal: principal, signer: signer, activate: activate)
    let underlying = try XCTUnwrap(bridge.transport)
    let transport = AuthenticatedFixtureTransport(underlying: underlying, channelSession: session)
    let connection: BridgeBase.Connection = bridge.publisherUuid.map { .inbound(publisherUuid: $0) } ?? .outbound
    try await bridge.setTransport(transport, connection: connection)
    if activate { try bridge.activateAuthenticatedChannel() }
}

func authenticatedSessionFixture(principal: Identity, signer: IdentityVaultProtocol? = nil, activate: Bool = true, limits: BridgeChannelLimits? = nil) async throws -> BridgeChannelSession {
    let vault = signer ?? principal.identityVault ?? CellBase.defaultIdentityVault ?? MockIdentityVault()
    if principal.publicSecureKey == nil {
        if let stored = await vault.identity(forUUID: principal.uuid) { principal.publicSecureKey = stored.publicSecureKey }
        var fixtureIdentity = principal
        await vault.addIdentity(identity: &fixtureIdentity, for: "fixture-" + principal.uuid)
        XCTAssertNotNil(principal.publicSecureKey, "Fixture key creation must precede admission")
    }
    let descriptor = principal.publicIdentitySnapshot()
    let endpoint = try BridgeChannelAuthentication.Endpoint(url: URL(string: "wss://fixture.example/bridgehead/cell/test")!, domain: "bridge")
    let session = try BridgeChannelSession(endpoint: endpoint, limits: limits)
    let hello = BridgeChannelAuthentication.Hello(identity: try .init(descriptor))
    let challenge = try session.issueChallenge(hello)
    let signature = try await vault.signMessageForIdentity(messageData: challenge.signingData, identity: descriptor)
    try session.reserveOpen(.init(sessionID: challenge.transcript.sessionID, generation: challenge.transcript.generation, signature: signature))
    if activate { _ = try session.activate() }
    return session
}

private struct AuthenticatedFixtureTransport: BridgeTransportProtocol {
    let underlying: BridgeTransportProtocol
    let channelSession: BridgeChannelSession?
    static func new() -> BridgeTransportProtocol { fatalError("Fixture requires verified session") }
    func setDelegate(_ delegate: BridgeDelegateProtocol) { underlying.setDelegate(delegate) }
    func setup(_ endpointURL: URL, identity: Identity) async throws { try await underlying.setup(endpointURL, identity: identity) }
    func sendData(_ data: Data) async throws { try channelSession?.check(); try await underlying.sendData(data) }
    func close() async { channelSession?.close(); await underlying.close() }
    func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
}

/// Test servers that model resolver routing use the same server state machine.
/// They are not allowed to answer a new client with an old ready frame.
final class ResolverHandshakeFixture {
    private let uuid = UUID().uuidString
    private var session: BridgeChannelSession?
    func configure(_ url: URL) throws {
        session = try BridgeChannelSession(endpoint: .init(url: url, domain: "bridge", allowInsecureLoopback: true))
    }
    func consume(_ command: BridgeCommand, delegate: BridgeDelegateProtocol?) async throws -> Bool {
        if command.command == .description, command.channelID == nil, let identity = command.identity, let session {
            try session.check(identity: identity, requiresIdentity: true)
            let description = AnyCell(uuid: uuid, name: "fixture", contractTemplate: Agreement(owner: identity),
                owner: identity, experiences: nil, feedEndpoint: nil, feedProperties: nil, identityDomain: "bridge")
            let reply = BridgeCommand(cmd: "response", payload: .description(description), cid: command.cid)
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000)
                try? await delegate?.consumeResponse(command: reply)
            }
            return true
        }
        guard command.cmd.hasPrefix("channelAuth"), case let .string(json) = command.payload,
              let session else { return false }
        let bytes = Data(json.utf8)
        let response: BridgeCommand
        switch command.cmd {
        case "channelAuthHello":
            let challenge = try session.issueChallenge(BridgeChannelAuthentication.decode(BridgeChannelAuthentication.Hello.self, from: bytes))
            response = .init(cmd: "channelAuthChallenge", payload: .string(String(decoding: try BridgeChannelAuthentication.encode(challenge), as: UTF8.self)), cid: 0)
        case "channelAuthProof":
            try session.reserveOpen(BridgeChannelAuthentication.decode(BridgeChannelAuthentication.Proof.self, from: bytes))
            let acknowledgement = try session.activate()
            response = .init(cmd: "channelAuthAccepted", payload: .string(String(decoding: try BridgeChannelAuthentication.encode(acknowledgement), as: UTF8.self)), cid: 0)
        default: throw BridgeChannelAuthentication.Failure.unexpectedMessage
        }
        try await delegate?.consumeCommand(command: response)
        return true
    }
}
