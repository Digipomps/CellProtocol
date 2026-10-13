// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class BridgeConnectLifetimeTests: XCTestCase {
    typealias A = BridgeChannelAuthentication
    private func fixture(before: ConnectTestBarrier? = nil, after: ConnectTestBarrier? = nil,
                         clock: ConnectTestClock = ConnectTestClock()) async throws -> (SynchronousConnectVault, BridgeChannelClientOperation, A.Challenge) {
        let endpoint = try A.Endpoint(url: XCTUnwrap(URL(string: "wss://bridge.example/connect")), domain: "bridge")
        let holder = BridgeConnectHolderCapability()
        let vault = SynchronousConnectVault(holder: holder, endpoint: endpoint, before: before, after: after)
        let identity = await vault.holderIdentity()
        let operation = try BridgeChannelClientOperation(owner: identity, endpoint: endpoint,
            wallClock: { clock.now }, monotonic: { clock.uptime })
        let server = try BridgeChannelSession(endpoint: endpoint, wallClock: { clock.now })
        return (vault, operation, try server.issueChallenge(operation.hello))
    }

    func testCancelBeforeAdmissionMakesZeroPrivateKeyCalls() async throws {
        let before = ConnectTestBarrier()
        let (vault, operation, challenge) = try await fixture(before: before)
        let task = Task { try await operation.sign(challenge) }
        await before.waitForEntry()
        await operation.cancel()
        await before.release()
        do { _ = try await task.value; XCTFail("Cancelled proof") } catch {}
        let calls = await vault.calls
        XCTAssertEqual(calls, 0)
        await assertReplayDenied(vault, challenge: challenge)
    }

    func testTaskCancellationBeforeAdmissionMakesZeroPrivateKeyCalls() async throws {
        let before = ConnectTestBarrier()
        let (vault, operation, challenge) = try await fixture(before: before)
        let task = Task { try await operation.sign(challenge) }
        await before.waitForEntry()
        task.cancel()
        await before.release()
        do { _ = try await task.value; XCTFail("Cancelled proof") } catch {}
        let calls = await vault.calls
        XCTAssertEqual(calls, 0)
    }

    func testMonotonicExpiryWithBackwardWallClockMakesZeroPrivateKeyCalls() async throws {
        let before = ConnectTestBarrier(), clock = ConnectTestClock()
        let (vault, operation, challenge) = try await fixture(before: before, clock: clock)
        let task = Task { try await operation.sign(challenge) }
        await before.waitForEntry()
        clock.expireWithBackwardWallClock()
        await before.release()
        do { _ = try await task.value; XCTFail("Expired proof") } catch {}
        let calls = await vault.calls
        XCTAssertEqual(calls, 0)
    }

    func testAdmissionBeforeCancelSignsOnceButDeliversNoProof() async throws {
        let after = ConnectTestBarrier()
        let (vault, operation, challenge) = try await fixture(after: after)
        let task = Task { try await operation.sign(challenge) }
        await after.waitForEntry()
        let admitted = await vault.calls
        XCTAssertEqual(admitted, 1)
        await operation.cancel()
        await after.release()
        do { _ = try await task.value; XCTFail("Proof after cancel") } catch {}
        await assertReplayDenied(vault, challenge: challenge)
        let calls = await vault.calls
        XCTAssertEqual(calls, 1)
    }

    func testCapturedContextHasExactBindingAndParallelOneShotAdmission() async throws {
        let before = ConnectTestBarrier()
        let (vault, operation, challenge) = try await fixture(before: before)
        let task = Task { try await operation.sign(challenge) }
        await before.waitForEntry()
        let captured = await vault.context
        let context = try XCTUnwrap(captured)
        let identity = await vault.holderIdentity()
        let token = await vault.holder
        let endpoint = await vault.endpoint
        let changed = identity.publicIdentitySnapshot()
        changed.publicSecureKey = nil
        XCTAssertThrowsError(try context.consume(messageData: challenge.signingData, identity: changed))
        let otherData = try IdentitySigningChallenge.signingData(for: identity, trustedIdentity: identity,
            domain: "bridge", resource: "different-valid-resource", action: A.action,
            audience: endpoint.audience, nonce: Data(repeating: 7, count: 32))
        XCTAssertThrowsError(try context.consume(messageData: otherData, identity: identity))
        let otherIdentity = Identity("00000000-0000-0000-0000-000000000197", displayName: "other", identityVault: nil)
        otherIdentity.publicSecureKey = identity.publicSecureKey
        XCTAssertThrowsError(try context.consume(messageData: challenge.signingData, identity: otherIdentity))
        XCTAssertThrowsError(try context.validate(holder: BridgeConnectHolderCapability(), messageData: challenge.signingData, identity: identity, endpoint: endpoint))
        let wrongEndpoint = try A.Endpoint(url: XCTUnwrap(URL(string: "wss://other.example/connect")), domain: "bridge")
        XCTAssertThrowsError(try context.validate(holder: token, messageData: challenge.signingData, identity: identity, endpoint: wrongEndpoint))
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 {
                group.addTask { (try? context.consume(messageData: challenge.signingData, identity: identity)) != nil }
            }
            var winners = 0
            for await accepted in group { if accepted { winners += 1 } }
            return winners
        }
        XCTAssertEqual(winners, 1)
        await before.release()
        do { _ = try await task.value; XCTFail("Already consumed context") } catch {}
        let calls = await vault.calls
        XCTAssertEqual(calls, 0)
    }

    func testFailedSigningConsumesAuthorityAndOperationCannotRetry() async throws {
        let (vault, operation, challenge) = try await fixture()
        await vault.failSigningForTesting()
        do { _ = try await operation.sign(challenge); XCTFail("Expected signing failure") } catch {}
        await assertReplayDenied(vault, challenge: challenge)
        do { _ = try await operation.sign(challenge); XCTFail("Retry must not mint authority") } catch {}
        let calls = await vault.calls
        XCTAssertEqual(calls, 1)
    }

    func testTransportCloseAndRenewRevokeBeforeAdmissionAndWithholdPostAdmissionProof() async throws {
        for renewal in [false, true] {
            for admitted in [false, true] {
                let endpoint = try A.Endpoint(url: XCTUnwrap(URL(string: "wss://bridge.example/connect")), domain: "bridge")
                let barrier = ConnectTestBarrier()
                let vault = SynchronousConnectVault(holder: BridgeConnectHolderCapability(), endpoint: endpoint,
                    before: admitted ? nil : barrier, after: admitted ? barrier : nil)
                let identity = await vault.holderIdentity()
                let wire = ConnectTestWire()
                let sent = expectation(description: "hello")
                wire.onHello = { sent.fulfill() }
                let gate = try BridgeChannelTransport(underlying: wire, endpoint: endpoint)
                let setup = Task { try await gate.setup(URL(string: endpoint.audience)!, identity: identity) }
                await fulfillment(of: [sent], timeout: 2)
                guard let command = wire.snapshot.first, case let .string(bytes) = command.payload else {
                    await gate.close(); _ = try? await setup.value
                    return XCTFail("No hello")
                }
                let hello = try A.decode(A.Hello.self, from: Data(bytes.utf8))
                let server = try BridgeChannelSession(endpoint: endpoint)
                let challenge = try server.issueChallenge(hello)
                let frame = try A.encode(BridgeCommand(cmd: "channelAuthChallenge",
                    payload: .string(String(decoding: try A.encode(challenge), as: UTF8.self)), cid: 0))
                let delivery = Task { try await wire.deliver(frame) }
                await barrier.waitForEntry()
                if renewal {
                    let replacement = try await gate.replacementForRenewal()
                    await replacement.close()
                } else { await gate.close() }
                let beforeRelease = await vault.calls
                XCTAssertEqual(beforeRelease, admitted ? 1 : 0)
                await barrier.release()
                do { _ = try await delivery.value; XCTFail("Retired transport delivered proof") } catch {}
                _ = try? await setup.value
                let calls = await vault.calls
                XCTAssertEqual(calls, admitted ? 1 : 0)
                XCTAssertEqual(gate.session.state, .closed)
                XCTAssertFalse(wire.snapshot.contains { $0.cmd == "channelAuthProof" })
                await assertReplayDenied(vault, challenge: challenge)
                server.close()
            }
        }
    }

    private func assertReplayDenied(_ vault: SynchronousConnectVault, challenge: A.Challenge) async {
        guard let context = await vault.context else { return XCTFail("No captured context") }
        let identity = await vault.holderIdentity()
        XCTAssertThrowsError(try context.consume(messageData: challenge.signingData, identity: identity))
    }
}

private final class ConnectTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    private var date = Date()
    var now: Date { lock.withLock { date } }
    var uptime: TimeInterval { lock.withLock { time } }
    func expireWithBackwardWallClock() { lock.withLock { time += 11; date.addTimeInterval(-1) } }
}

private actor ConnectTestBarrier {
    private var entered = false
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        observers.forEach { $0.resume() }; observers.removeAll()
        if !released { await withCheckedContinuation { waiting = $0 } }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; waiting?.resume(); waiting = nil }
}

private actor SynchronousConnectVault: IdentityVaultProtocol {
    let holder: BridgeConnectHolderCapability
    let endpoint: BridgeChannelAuthentication.Endpoint
    private let key = Curve25519.Signing.PrivateKey()
    private let before: ConnectTestBarrier?
    private let after: ConnectTestBarrier?
    private(set) var calls = 0
    private var failSigning = false
    func failSigningForTesting() { failSigning = true }
    private(set) var context: BridgeConnectSigningContext?
    init(holder: BridgeConnectHolderCapability, endpoint: BridgeChannelAuthentication.Endpoint,
         before: ConnectTestBarrier?, after: ConnectTestBarrier?) {
        self.holder = holder; self.endpoint = endpoint; self.before = before; self.after = after
    }
    func holderIdentity() -> Identity {
        let identity = Identity("00000000-0000-0000-0000-000000000196", displayName: "synthetic", identityVault: self)
        identity.homeVaultReference = "synthetic-vault"
        identity.publicSecureKey = SecureKey(date: Date(), privateKey: false, use: .signature,
            algorithm: .EdDSA, size: 32, curveType: .Curve25519, x: nil, y: nil,
            compressedKey: key.publicKey.rawRepresentation)
        return holder.holderIdentity(identity)
    }
    func initialize() async -> IdentityVaultProtocol { self }
    func addIdentity(identity: inout Identity, for identityContext: String) async {}
    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? { nil }
    func identityExistInVault(_ identity: Identity) async -> Bool { identity.referencesSameSigningIdentity(as: holderIdentity()) }
    func saveIdentity(_ identity: Identity) async {}
    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data { throw IdentityVaultError.signingFailed }
    func signMessageForIdentity(messageData: Data, identity: Identity, bridgeConnectContext: BridgeConnectSigningContext) async throws -> Data {
        context = bridgeConnectContext
        try bridgeConnectContext.validate(holder: holder, messageData: messageData, identity: identity, endpoint: endpoint)
        await before?.wait()
        try bridgeConnectContext.consume(messageData: messageData, identity: identity)
        calls += 1
        let signature = try key.signature(for: messageData)
        if failSigning { throw IdentityVaultError.signingFailed }
        await after?.wait()
        return signature
    }
    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool { false }
    func randomBytes64() async -> Data? { nil }
    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) { throw IdentityVaultError.noKey }
}

private final class ConnectTestWire: BridgeTransportProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var delegate: BridgeDelegateProtocol?
    private var commands: [BridgeCommand] = []
    var onHello: (() -> Void)?
    var snapshot: [BridgeCommand] { lock.withLock { commands } }
    static func new() -> BridgeTransportProtocol { ConnectTestWire() }
    func setDelegate(_ delegate: BridgeDelegateProtocol) { lock.withLock { self.delegate = delegate } }
    func setup(_ endpointURL: URL, identity: Identity) async throws {}
    func sendData(_ data: Data) async throws {
        let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
        lock.withLock { commands.append(command) }
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
