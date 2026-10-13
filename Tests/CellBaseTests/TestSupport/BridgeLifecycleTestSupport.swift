// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import XCTest
@testable import CellBase

/// Non-cooperative barrier: cancellation cannot silently remove the race window.
actor BridgeLifecycleBarrier {
    let entered = XCTestExpectation(description: "lifecycle boundary")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold() async {
        entered.fulfill()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

final class BridgeLifecycleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wall = Date()
    private var ticks: TimeInterval = 100
    var now: Date { lock.withLock { wall } }
    var monotonic: TimeInterval { lock.withLock { ticks } }
    func advance(wall seconds: TimeInterval = 0, monotonic: TimeInterval = 0) {
        lock.withLock { wall.addTimeInterval(seconds); ticks += monotonic }
    }
}

final class BridgeLifecycleWire: BridgeTransportProtocol, @unchecked Sendable {
    var channelSession: BridgeChannelSession?
    weak var delegate: BridgeDelegateProtocol?
    var beforeAccept: (@Sendable (BridgeCommand) async throws -> Void)?
    var accepted: (@Sendable (BridgeCommand) -> Void)?
    private let lock = NSLock()
    private var sent: [BridgeCommand] = []
    var commands: [BridgeCommand] { lock.withLock { sent } }
    static func new() -> BridgeTransportProtocol { BridgeLifecycleWire() }
    func setDelegate(_ delegate: BridgeDelegateProtocol) { self.delegate = delegate }
    func setup(_ endpointURL: URL, identity: Identity) async throws {}
    func sendData(_ data: Data) async throws {
        let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
        try await beforeAccept?(command)
        lock.withLock { sent.append(command) }
        accepted?(command)
    }
    func close() async { channelSession?.close(); delegate = nil }
    func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
}

actor BridgeLifecycleVault: IdentityVaultProtocol {
    let underlying: MockIdentityVault
    var existenceBarrier: BridgeLifecycleBarrier?
    var signingBarrier: BridgeLifecycleBarrier?
    private(set) var signCount = 0
    init(_ underlying: MockIdentityVault) { self.underlying = underlying }
    func holdExistence(_ barrier: BridgeLifecycleBarrier?) { existenceBarrier = barrier }
    func holdSigning(_ barrier: BridgeLifecycleBarrier?) { signingBarrier = barrier }
    func initialize() async -> IdentityVaultProtocol { self }
    func addIdentity(identity: inout Identity, for identityContext: String) async {}
    func saveIdentity(_ identity: Identity) async {}
    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? {
        await underlying.identity(for: identityContext, makeNewIfNotFound: makeNewIfNotFound)
    }
    func identityExistInVault(_ identity: Identity) async -> Bool {
        await existenceBarrier?.hold()
        return await underlying.identityExistInVault(identity)
    }
    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        signCount += 1
        await signingBarrier?.hold()
        return try await underlying.signMessageForIdentity(messageData: messageData, identity: identity)
    }
    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool { false }
    func randomBytes64() async -> Data? { nil }
    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) { throw BridgeChannelAuthentication.Failure.unavailable }
}
