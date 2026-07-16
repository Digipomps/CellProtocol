// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

final class BridgeTests: XCTestCase {
    private actor RemoteRouteInstallationGate {
        private var installed: (host: String, generation: UInt64)?
        private var arrivalWaiters = [CheckedContinuation<Void, Never>]()
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func arriveAndWait(host: String, generation: UInt64) async {
            installed = (host, generation)
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitForInstallation() async -> (host: String, generation: UInt64) {
            if let installed { return installed }
            await withCheckedContinuation { continuation in
                arrivalWaiters.append(continuation)
            }
            return installed!
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private actor BlockingRouteSetupGate {
        private var setupURLs = [URL]()
        private var setupIdentities = [Identity]()
        private var continuations = [CheckedContinuation<Void, Never>]()

        func recordAndWait(_ url: URL, identity: Identity) async {
            setupURLs.append(url)
            setupIdentities.append(identity)
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func recordedSetupURLs() -> [URL] {
            setupURLs
        }

        func recordedSetupIdentities() -> [Identity] {
            setupIdentities
        }

        func releaseNext() {
            guard continuations.isEmpty == false else { return }
            continuations.removeFirst().resume()
        }

        func reset() {
            let pending = continuations
            continuations.removeAll(keepingCapacity: false)
            setupURLs.removeAll(keepingCapacity: false)
            setupIdentities.removeAll(keepingCapacity: false)
            pending.forEach { $0.resume() }
        }
    }

    private final class BlockingRouteBridgeTransport: BridgeTransportProtocol {
        static let setupGate = BlockingRouteSetupGate()

        static func new() -> BridgeTransportProtocol {
            BlockingRouteBridgeTransport()
        }

        func setDelegate(_ delegate: BridgeDelegateProtocol) {}

        func setup(_ endpointURL: URL, identity: Identity) async throws {
            await Self.setupGate.recordAndWait(endpointURL, identity: identity)
        }

        func sendData(_ data: Data) async throws {}

        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
            CellBase.defaultIdentityVault ?? MockIdentityVault()
        }
    }

    private final class RecordingBridgeTransport: BridgeTransportProtocol {
        static let stateLock = NSLock()
        static var lastSetupURL: URL?
        static var setupURLs = [URL]()

        static func new() -> BridgeTransportProtocol {
            RecordingBridgeTransport()
        }

        static func reset() {
            stateLock.withLock {
                lastSetupURL = nil
                setupURLs.removeAll(keepingCapacity: false)
            }
        }

        static func recordedSetupURL() -> URL? {
            stateLock.withLock {
                lastSetupURL
            }
        }

        static func recordedSetupURLs() -> [URL] {
            stateLock.withLock {
                setupURLs
            }
        }

        func setDelegate(_ delegate: BridgeDelegateProtocol) {}

        func setup(_ endpointURL: URL, identity: Identity) async throws {
            Self.stateLock.withLock {
                Self.lastSetupURL = endpointURL
                Self.setupURLs.append(endpointURL)
            }
        }

        func sendData(_ data: Data) async throws {}

        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
            CellBase.defaultIdentityVault ?? MockIdentityVault()
        }
    }

    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousRemoteWebSocketQueryItemsProvider: (@Sendable (URL) -> [URLQueryItem])?
    private var previousSecurityEventSink: CellSecurityEventSink?
    private var previousSigningChallengeReplayStore: CellSecuritySigningChallengeReplayStore?
    private var previousSecurityContainmentPolicy: CellSecurityContainmentPolicy?
    private var previousSecurityContainmentController: CellSecurityContainmentController?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousRemoteWebSocketQueryItemsProvider = CellBase.remoteWebSocketQueryItemsProvider
        previousSecurityEventSink = CellBase.securityEventSink
        previousSigningChallengeReplayStore = CellBase.signingChallengeReplayStore
        previousSecurityContainmentPolicy = CellBase.securityContainmentPolicy
        previousSecurityContainmentController = CellBase.securityContainmentController
        CellBase.defaultIdentityVault = MockIdentityVault()
        CellBase.remoteWebSocketQueryItemsProvider = nil
        CellBase.securityEventSink = nil
        CellBase.signingChallengeReplayStore = CellSecuritySigningChallengeReplayStore()
        CellBase.securityContainmentPolicy = .monitorOnly
        CellBase.securityContainmentController = CellSecurityContainmentController()
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.remoteWebSocketQueryItemsProvider = previousRemoteWebSocketQueryItemsProvider
        CellBase.securityEventSink = previousSecurityEventSink
        CellBase.signingChallengeReplayStore = previousSigningChallengeReplayStore
        if let previousSecurityContainmentPolicy {
            CellBase.securityContainmentPolicy = previousSecurityContainmentPolicy
        }
        CellBase.securityContainmentController = previousSecurityContainmentController
        super.tearDown()
    }

    func testBridgeCommandRoundTripStringPayload() throws {
        let identity = TestFixtures.makeIdentity(displayName: "tester")
        let command = BridgeCommand(cmd: Command.get.rawValue, identity: identity, payload: .string("hello"), cid: 7)
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(BridgeCommand.self, from: data)

        XCTAssertEqual(decoded.command, .get)
        if case let .string(value) = decoded.payload {
            XCTAssertEqual(value, "hello")
        } else {
            XCTFail("Expected string payload")
        }
    }

    func testBridgeCommandUnknownCommandDecodesAsNoneWithoutLosingRawCommand() throws {
        let data = Data(
            """
            {
              "cmd": "futureCommand",
              "cid": 99,
              "&string": "hello"
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(BridgeCommand.self, from: data)

        XCTAssertEqual(decoded.cmd, "futureCommand")
        XCTAssertEqual(decoded.command, .none)
        XCTAssertEqual(decoded.cid, 99)
        XCTAssertEqual(decoded.payload, .string("hello"))
    }

    func testBridgeCommandPayloadWireKeysStayStable() throws {
        let cases: [(payload: ValueType, key: String)] = [
            (.string("hello"), "&string"),
            (.bool(true), "bool"),
            (.integer(7), "integer"),
            (.number(8), "&number"),
            (.float(1.5), "float"),
            (.data(Data([0x01, 0x02])), "data"),
            (.object(["name": .string("Alice")]), "&object"),
            (.list([.string("first")]), "&list"),
            (.connectState(.connected), "&connectState"),
            (.contractState(.signed), "&agreementState"),
            (.keyValue(KeyValue(key: "state", value: .string("ok"))), "&keyValue"),
            (.setValueState(.ok), "&setValueState"),
            (.setValueResponse(SetValueResponse(state: .ok, value: .string("done"))), "&setValueResponse"),
            (.signData(Data("sign".utf8)), "sign"),
            (.signature(Data("signature".utf8)), "&signature")
        ]

        for testCase in cases {
            let command = BridgeCommand(cmd: Command.response.rawValue, payload: testCase.payload, cid: 1)
            let json = try bridgeCommandJSON(command)
            XCTAssertNotNil(json[testCase.key], "Expected payload key \(testCase.key) for \(testCase.payload)")

            let decoded = try JSONDecoder().decode(BridgeCommand.self, from: JSONEncoder().encode(command))
            XCTAssertEqual(decoded.command, .response)
            XCTAssertNotNil(decoded.payload)
        }
    }

    func testLegacyBridgeConfigInitializerDefaultsToOutboundWithoutDummyPublisher() {
        let transport = MockBridgeTransport()
        let config = BridgeBase.Config(transport: transport)

        switch config.connection {
        case .outbound:
            break
        case .inbound(let publisherUuid):
            XCTFail("Legacy transport-only init should not create dummy inbound publisher: \(publisherUuid)")
        }
    }

    func testBridgeBaseSendCommandIncrementsCid() async throws {
        let transport = MockBridgeTransport()
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)

        await bridge.sendCommand(command: .get, identity: owner, payload: .string("first"))
        await bridge.sendCommand(command: .get, identity: owner, payload: .string("second"))

        XCTAssertEqual(transport.sentData.count, 2)

        let first = try JSONDecoder().decode(BridgeCommand.self, from: transport.sentData[0])
        let second = try JSONDecoder().decode(BridgeCommand.self, from: transport.sentData[1])

        XCTAssertEqual(first.cid, 1)
        XCTAssertEqual(second.cid, 2)
        XCTAssertEqual(first.command, .get)
        XCTAssertEqual(second.command, .get)
    }

    func testBridgeBaseDisconnectCommandsPreserveConnectionLabels() async throws {
        let transport = MockBridgeTransport()
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)

        bridge.detach(label: "remote-source", requester: owner)
        bridge.dropFlow(label: "remote-feed", requester: owner)

        let commands = try await waitUntilTransportHasSent(2, transport: transport)
        let detach = try XCTUnwrap(commands.first(where: { $0.command == .removeConnecion }))
        let drop = try XCTUnwrap(commands.first(where: { $0.command == .dropFlow }))
        XCTAssertEqual(detach.payload, .string("remote-source"))
        XCTAssertEqual(drop.payload, .string("remote-feed"))
    }

    func testBridgeBaseAuditorTakesCommandsAndPurgesExpiredEntries() async throws {
        let auditor = BridgeBaseAuditor(commandRetentionSeconds: 1)
        let identity = TestFixtures.makeIdentity(displayName: "auditor")
        let now = Date(timeIntervalSince1970: 10_000)
        let command = BridgeCommand(
            cmd: Command.get.rawValue,
            identity: identity,
            payload: .string("state"),
            cid: 1
        )

        await auditor.storeBridgeCommand(command, for: 1, now: now)

        let initialPendingCount = await auditor.pendingCommandCount(now: now.addingTimeInterval(0.5))
        let takenCommand = await auditor.takeBridgeCommandForCommandId(1, now: now.addingTimeInterval(0.5))
        let pendingCountAfterTake = await auditor.pendingCommandCount(now: now.addingTimeInterval(0.5))
        XCTAssertEqual(initialPendingCount, 1)
        XCTAssertEqual(takenCommand?.cid, 1)
        XCTAssertEqual(pendingCountAfterTake, 0)

        await auditor.storeBridgeCommand(command, for: 2, now: now)

        let expiredCommand = await auditor.loadBridgeCommandForCommandId(2, now: now.addingTimeInterval(2))
        let pendingCountAfterExpiry = await auditor.pendingCommandCount(now: now.addingTimeInterval(2))
        XCTAssertNil(expiredCommand)
        XCTAssertEqual(pendingCountAfterExpiry, 0)
    }

    func testBridgeBaseConsumeAdmitSendsResponse() async throws {
        let transport = MockBridgeTransport()
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver

        let publisher = TestEmitCell(owner: owner, uuid: "publisher-1")
        try await resolver.registerNamedEmitCell(name: "publisher-1", emitCell: publisher, scope: .scaffoldUnique, identity: owner)

        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .inbound(publisherUuid: "publisher-1"))
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "publisher-1"))

        let command = BridgeCommand(cmd: Command.admit.rawValue, identity: owner, payload: nil, cid: 42)
        try await bridge.consumeCommand(command: command)

        XCTAssertFalse(transport.sentData.isEmpty)
        let response = try JSONDecoder().decode(BridgeCommand.self, from: transport.sentData.last!)
        XCTAssertEqual(response.command, .response)
        if case let .connectState(state) = response.payload {
            XCTAssertEqual(state, .connected)
        } else {
            XCTFail("Expected connectState payload")
        }
    }

    func testInboundBridgeResolvesIdentityScopedPublisherForCommandIdentity() async throws {
        let transport = MockBridgeTransport()
        let bridgeOwner = TestFixtures.makeIdentity(displayName: "bridge-owner")
        let requester = TestFixtures.makeIdentity(displayName: "requester")
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver

        let publisher = TestEmitCell(owner: requester, uuid: "vault-publisher")
        try await resolver.registerNamedEmitCell(
            name: "Vault",
            emitCell: publisher,
            scope: .identityUnique,
            identity: requester
        )

        let config = BridgeBase.Config(owner: bridgeOwner, transport: transport, connection: .inbound(publisherUuid: "Vault"))
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Vault"))

        let command = BridgeCommand(cmd: Command.admit.rawValue, identity: requester, payload: nil, cid: 7)
        try await bridge.consumeCommand(command: command)

        XCTAssertFalse(transport.sentData.isEmpty)
        let response = try JSONDecoder().decode(BridgeCommand.self, from: transport.sentData.last!)
        XCTAssertEqual(response.command, .response)
        if case let .connectState(state) = response.payload {
            XCTAssertEqual(state, .connected)
        } else {
            XCTFail("Expected connectState payload")
        }
    }

    func testInboundBridgeCanPinIdentityScopedPublisherLookupToRouteIdentity() async throws {
        let transport = MockBridgeTransport()
        let routeIdentity = TestFixtures.makeIdentity(displayName: "route-identity", uuid: TestFixtures.fixedUUID1)
        let requester = TestFixtures.makeIdentity(displayName: "requester", uuid: TestFixtures.fixedUUID2)
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver

        let routePublisher = TestEmitCell(owner: routeIdentity, uuid: "route-vault-publisher")
        _ = try await routePublisher.set(keypath: "state.marker", value: .string("route"), requester: routeIdentity)
        try await resolver.registerNamedEmitCell(
            name: "Vault",
            emitCell: routePublisher,
            scope: .identityUnique,
            identity: routeIdentity
        )

        let requesterPublisher = TestEmitCell(owner: requester, uuid: "requester-vault-publisher")
        _ = try await requesterPublisher.set(keypath: "state.marker", value: .string("requester"), requester: requester)
        try await resolver.registerNamedEmitCell(
            name: "Vault",
            emitCell: requesterPublisher,
            scope: .identityUnique,
            identity: requester
        )

        let config = BridgeBase.Config(
            owner: routeIdentity,
            transport: transport,
            connection: .inbound(publisherUuid: "Vault"),
            inboundPublisherLookupIdentity: routeIdentity
        )
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .inbound(publisherUuid: "Vault"))

        let command = BridgeCommand(
            cmd: Command.get.rawValue,
            identity: requester,
            payload: .string("state.marker"),
            cid: 9
        )
        try await bridge.consumeCommand(command: command)

        XCTAssertFalse(transport.sentData.isEmpty)
        let response = try JSONDecoder().decode(BridgeCommand.self, from: transport.sentData.last!)
        XCTAssertEqual(response.command, .response)
        XCTAssertEqual(response.payload, .string("route"))
    }

    func testBridgeBaseSignMessageRoutesResponsesByCommandID() async throws {
        let transport = MockBridgeTransport()
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)
        let firstChallenge = try identityChallengeData(for: owner, nonce: "first")
        let secondChallenge = try identityChallengeData(for: owner, nonce: "second")

        let firstPublisher = bridge.signMessageForIdentity(
            messageData: firstChallenge,
            identity: owner
        )
        let secondPublisher = bridge.signMessageForIdentity(
            messageData: secondChallenge,
            identity: owner
        )

        async let firstSignature = firstPublisher.getOneWithTimeout(1)
        async let secondSignature = secondPublisher.getOneWithTimeout(1)

        let sentCommands = try await waitUntilTransportHasSent(2, transport: transport)
        let firstCommand = try XCTUnwrap(
            sentCommands.first(where: { command in
                if case let .signData(data) = command.payload {
                    return data == firstChallenge
                }
                return false
            })
        )
        let secondCommand = try XCTUnwrap(
            sentCommands.first(where: { command in
                if case let .signData(data) = command.payload {
                    return data == secondChallenge
                }
                return false
            })
        )

        let firstExpected = try await vault.signMessageForIdentity(messageData: firstChallenge, identity: owner)
        let secondExpected = try await vault.signMessageForIdentity(messageData: secondChallenge, identity: owner)

        try await bridge.consumeResponse(
            command: BridgeCommand(
                cmd: Command.response.rawValue,
                identity: owner,
                payload: .signature(secondExpected),
                cid: secondCommand.cid
            )
        )
        try await bridge.consumeResponse(
            command: BridgeCommand(
                cmd: Command.response.rawValue,
                identity: owner,
                payload: .signature(firstExpected),
                cid: firstCommand.cid
            )
        )

        let resolvedFirst = try await firstSignature
        let resolvedSecond = try await secondSignature
        XCTAssertEqual(resolvedFirst, firstExpected)
        XCTAssertEqual(resolvedSecond, secondExpected)
        let pendingCommandCount = await bridge.auditor.pendingCommandCount()
        XCTAssertEqual(pendingCommandCount, 0)
    }

    func testBridgeBaseSignMessageTimeoutClearsPendingCommand() async throws {
        let transport = MockBridgeTransport()
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        bridge.signRequestTimeoutNanoseconds = 300_000_000
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)
        let challenge = try identityChallengeData(for: owner, nonce: "sign-timeout")

        let publisher = bridge.signMessageForIdentity(
            messageData: challenge,
            identity: owner
        )
        async let timedOutSignature = publisher.getOneWithTimeout(1)
        _ = try await waitUntilTransportHasSent(1, transport: transport)

        do {
            _ = try await timedOutSignature
            XCTFail("Expected unanswered bridge signing request to time out")
        } catch {
            XCTAssertTrue(String(describing: error).contains("timeout"))
        }
        let pendingCommandCount = await bridge.auditor.pendingCommandCount()
        XCTAssertEqual(pendingCommandCount, 0)
    }

    func testBridgeIdentityVaultAsyncSigningReturnsResponseSignature() async throws {
        let transport = MockBridgeTransport()
        let localVault = MockIdentityVault()
        CellBase.defaultIdentityVault = localVault
        let owner = await localVault.identity(for: "owner", makeNewIfNotFound: true)!
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)
        let vault = BridgeIdentityVault(cloudBridge: bridge)
        let challenge = try identityChallengeData(for: owner, nonce: "bridge-vault")

        async let signature = vault.signMessageForIdentity(messageData: challenge, identity: owner)
        let sentCommands = try await waitUntilTransportHasSent(1, transport: transport)
        try await Task.sleep(nanoseconds: 50_000_000)

        let request = try XCTUnwrap(sentCommands.first)
        let expectedSignature = try await localVault.signMessageForIdentity(messageData: challenge, identity: owner)
        try await bridge.consumeResponse(
            command: BridgeCommand(
                cmd: Command.response.rawValue,
                identity: owner,
                payload: .signature(expectedSignature),
                cid: request.cid
            )
        )

        let resolvedSignature = try await signature
        XCTAssertEqual(resolvedSignature, expectedSignature)
    }

    func testBridgeBaseSignMessageRequiresReadyBeforeSending() async throws {
        let transport = MockBridgeTransport()
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        let challenge = try identityChallengeData(for: owner, nonce: "not-ready")

        let publisher = bridge.signMessageForIdentity(
            messageData: challenge,
            identity: owner
        )

        do {
            _ = try await publisher.getOneWithTimeout(1)
            XCTFail("Expected bridge signing to require a ready session")
        } catch {
            XCTAssertTrue(String(describing: error).contains("denied"))
        }
        XCTAssertTrue(transport.sentData.isEmpty)
    }

    func testBridgeBaseSignMessageRejectsUnverifiedSignatureResponse() async throws {
        let transport = MockBridgeTransport()
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)
        let challenge = try identityChallengeData(for: owner, nonce: "forged-response")

        let publisher = bridge.signMessageForIdentity(
            messageData: challenge,
            identity: owner
        )
        async let signature = publisher.getOneWithTimeout(1)
        let sentCommands = try await waitUntilTransportHasSent(1, transport: transport)
        let request = try XCTUnwrap(sentCommands.first)

        try await bridge.consumeResponse(
            command: BridgeCommand(
                cmd: Command.response.rawValue,
                identity: owner,
                payload: .signature(Data("forged-signature".utf8)),
                cid: request.cid
            )
        )

        do {
            _ = try await signature
            XCTFail("Expected unverified bridge signature response to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("signingFailed"))
        }
    }

    func testBridgeBaseSignMessageRejectsForgedResponseWhenIdentityVaultAlwaysApproves() async throws {
        let transport = MockBridgeTransport()
        let backingVault = MockIdentityVault()
        let owner = await backingVault.identity(for: "owner", makeNewIfNotFound: true)!
        let approvingVault = BridgeAlwaysTrueVerificationVault()
        owner.identityVault = approvingVault
        CellBase.defaultIdentityVault = approvingVault

        let bridge = try await BridgeBase(
            BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        )
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)
        let challenge = try identityChallengeData(for: owner, nonce: "always-true-vault")

        let publisher = bridge.signMessageForIdentity(messageData: challenge, identity: owner)
        async let signature = publisher.getOneWithTimeout(1)
        let sentCommands = try await waitUntilTransportHasSent(1, transport: transport)
        let request = try XCTUnwrap(sentCommands.first)

        try await bridge.consumeResponse(
            command: BridgeCommand(
                cmd: Command.response.rawValue,
                identity: owner,
                payload: .signature(Data(repeating: 0xA5, count: 64)),
                cid: request.cid
            )
        )

        do {
            _ = try await signature
            XCTFail("Expected public-key verification to reject a forged response despite an approving vault")
        } catch {
            XCTAssertTrue(String(describing: error).contains("signingFailed"))
        }
    }

    func testBridgeBaseSignMessageRejectsEd25519SignatureLabeledAsSecp256k1() async throws {
        let transport = MockBridgeTransport()
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let signingKey = try XCTUnwrap(owner.publicSecureKey)
        owner.publicSecureKey = SecureKey(
            date: Date(),
            privateKey: false,
            use: .signature,
            algorithm: .ECDSA,
            size: signingKey.size,
            curveType: .secp256k1,
            x: signingKey.x,
            y: signingKey.y,
            compressedKey: signingKey.compressedKey
        )

        let bridge = try await BridgeBase(
            BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        )
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)
        let challenge = try identityChallengeData(for: owner, nonce: "wrong-curve-metadata")
        let ed25519Signature = try await vault.signMessageForIdentity(
            messageData: challenge,
            identity: owner
        )

        let publisher = bridge.signMessageForIdentity(messageData: challenge, identity: owner)
        async let signature = publisher.getOneWithTimeout(1)
        let sentCommands = try await waitUntilTransportHasSent(1, transport: transport)
        let request = try XCTUnwrap(sentCommands.first)
        try await bridge.consumeResponse(
            command: BridgeCommand(
                cmd: Command.response.rawValue,
                identity: owner,
                payload: .signature(ed25519Signature),
                cid: request.cid
            )
        )

        do {
            _ = try await signature
            XCTFail("Expected algorithm/curve metadata mismatch to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("signingFailed"))
        }
    }

    func testBridgeBaseSignMessageRejectsRawPayloadBeforeSending() async throws {
        let transport = MockBridgeTransport()
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)

        let publisher = bridge.signMessageForIdentity(
            messageData: Data("raw bytes must not be bridge-signed".utf8),
            identity: owner
        )

        do {
            _ = try await publisher.getOneWithTimeout(1)
            XCTFail("Expected raw bridge signing request to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("invalidPayload"))
        }
        XCTAssertTrue(transport.sentData.isEmpty)
    }

    func testBridgeBaseSignMessageRejectsWrongPurposeChallengeBeforeSending() async throws {
        let transport = MockBridgeTransport()
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)

        let challenge = IdentitySigningChallenge(
            purpose: "not-identity-origin-proof",
            identityUUID: owner.uuid,
            publicKeyFingerprint: owner.signingPublicKeyFingerprint,
            domain: "bridge-test",
            resource: "bridge",
            action: "sign",
            audience: "BridgeTests",
            nonce: Data("wrong-purpose".utf8)
        )
        let publisher = bridge.signMessageForIdentity(
            messageData: try JSONEncoder().encode(challenge),
            identity: owner
        )

        do {
            _ = try await publisher.getOneWithTimeout(1)
            XCTFail("Expected wrong-purpose bridge signing request to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("wrongPurpose"))
        }
        XCTAssertTrue(transport.sentData.isEmpty)
    }

    func testBridgeBaseSignMessageRejectsMissingFingerprintChallengeBeforeSending() async throws {
        let transport = MockBridgeTransport()
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)

        let challenge = IdentitySigningChallenge(
            identityUUID: owner.uuid,
            publicKeyFingerprint: nil,
            domain: "bridge-test",
            resource: "bridge",
            action: "sign",
            audience: "BridgeTests",
            nonce: Data("missing-fingerprint".utf8)
        )
        let publisher = bridge.signMessageForIdentity(
            messageData: try JSONEncoder().encode(challenge),
            identity: owner
        )

        do {
            _ = try await publisher.getOneWithTimeout(1)
            XCTFail("Expected uuid-only bridge signing challenge to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("missingPublicKeyFingerprint"))
        }
        XCTAssertTrue(transport.sentData.isEmpty)
    }

    func testInboundBridgeSignCommandRejectsRawPayload() async throws {
        let transport = MockBridgeTransport()
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)

        let command = BridgeCommand(
            cmd: Command.sign.rawValue,
            identity: owner,
            payload: .signData(Data("raw inbound sign".utf8)),
            cid: 99
        )
        try await bridge.consumeCommand(command: command)

        XCTAssertEqual(transport.sentData.count, 1)
        let response = try JSONDecoder().decode(BridgeCommand.self, from: transport.sentData[0])
        XCTAssertEqual(response.command, .response)
        if case let .string(message) = response.payload {
            XCTAssertTrue(message.contains("signing denied"))
        } else {
            XCTFail("Expected signing denied string response")
        }
    }

    func testInboundBridgeSignCommandSignsKnownLocalIdentity() async throws {
        let transport = MockBridgeTransport()
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)
        let challenge = try identityChallengeData(for: owner, nonce: "inbound-local")

        let wireCommand = BridgeCommand(
            cmd: Command.sign.rawValue,
            identity: owner,
            payload: .signData(challenge),
            cid: 101
        )
        let decodedCommand = try JSONDecoder().decode(
            BridgeCommand.self,
            from: JSONEncoder().encode(wireCommand)
        )
        try await bridge.consumeCommand(command: decodedCommand)

        let sentCommands = try await waitUntilTransportHasSent(1, transport: transport)
        let response = try XCTUnwrap(sentCommands.first)
        XCTAssertEqual(response.command, .response)
        XCTAssertEqual(response.cid, 101)
        if case let .signature(signature) = response.payload {
            let verified = try await vault.verifySignature(
                signature: signature,
                messageData: challenge,
                for: owner
            )
            XCTAssertTrue(verified)
        } else {
            XCTFail("Expected signature payload")
        }
    }

    func testInboundBridgeSignCommandRejectsReplayedChallengeAndRecordsEvent() async throws {
        let transport = MockBridgeTransport()
        let vault = MockIdentityVault()
        let sink = InMemoryCellSecurityEventSink()
        CellBase.defaultIdentityVault = vault
        CellBase.securityEventSink = sink
        CellBase.signingChallengeReplayStore = CellSecuritySigningChallengeReplayStore()
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)
        let challenge = try identityChallengeData(for: owner, nonce: "inbound-replay")

        try await bridge.consumeCommand(command: BridgeCommand(
            cmd: Command.sign.rawValue,
            identity: owner,
            payload: .signData(challenge),
            cid: 201
        ))
        _ = try await waitUntilTransportHasSent(1, transport: transport)

        try await bridge.consumeCommand(command: BridgeCommand(
            cmd: Command.sign.rawValue,
            identity: owner,
            payload: .signData(challenge),
            cid: 202
        ))

        let sentCommands = try await waitUntilTransportHasSent(2, transport: transport)
        let replayResponse = try XCTUnwrap(sentCommands.last)
        XCTAssertEqual(replayResponse.cid, 202)
        if case let .string(message) = replayResponse.payload {
            XCTAssertTrue(message.contains("signing denied"))
            XCTAssertTrue(message.contains("replay"))
        } else {
            XCTFail("Expected replay signing denied string response")
        }

        let events = await sink.snapshot()
        XCTAssertEqual(events.last?.kind, .signingChallengeReplay)
        XCTAssertEqual(events.last?.reasonCode, CellSecurityReasonCode.challengeReplay)
        XCTAssertEqual(events.last?.requiredAction, "retry_with_fresh_challenge")
    }

    func testInboundBridgeSignCommandRespectsLocalQuarantineBeforeVaultSigning() async throws {
        let transport = MockBridgeTransport()
        let vault = MockIdentityVault()
        let sink = InMemoryCellSecurityEventSink()
        let controller = CellSecurityContainmentController()
        CellBase.defaultIdentityVault = vault
        CellBase.securityEventSink = sink
        CellBase.securityContainmentController = controller
        CellBase.securityContainmentPolicy = .localProtection
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)
        await controller.applyManualAction(
            CellSecurityContainmentAction(
                kind: .quarantineBridge,
                reasonCode: CellSecurityReasonCode.bridgeQuarantined,
                resource: CellSecurityResource(kind: "bridge", identifier: bridge.uuid, action: "sign"),
                requiredAction: "wait_for_quarantine_or_reauthenticate",
                automatic: true,
                expiresAt: Date().addingTimeInterval(60)
            )
        )
        let challenge = try identityChallengeData(for: owner, nonce: "inbound-quarantine")

        try await bridge.consumeCommand(command: BridgeCommand(
            cmd: Command.sign.rawValue,
            identity: owner,
            payload: .signData(challenge),
            cid: 203
        ))

        let sentCommands = try await waitUntilTransportHasSent(1, transport: transport)
        let response = try XCTUnwrap(sentCommands.last)
        XCTAssertEqual(response.cid, 203)
        if case let .string(message) = response.payload {
            XCTAssertTrue(message.contains("signing denied"))
            XCTAssertTrue(message.contains("quarantined"))
        } else {
            XCTFail("Expected quarantine signing denied string response")
        }

        let events = await sink.snapshot()
        XCTAssertEqual(events.last?.kind, .transportRejected)
        XCTAssertEqual(events.last?.reasonCode, CellSecurityReasonCode.bridgeQuarantined)
        XCTAssertEqual(events.last?.requiredAction, "wait_for_quarantine_or_reauthenticate")
    }

    func testInboundBridgeSignCommandRejectsNonLocalIdentity() async throws {
        let transport = MockBridgeTransport()
        let localVault = MockIdentityVault()
        CellBase.defaultIdentityVault = localVault
        let owner = await localVault.identity(for: "owner", makeNewIfNotFound: true)!
        let remoteVault = MockIdentityVault()
        let remoteIdentity = await remoteVault.identity(for: "remote", makeNewIfNotFound: true)!
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)
        let challenge = try identityChallengeData(for: remoteIdentity, nonce: "inbound-remote")

        let wireCommand = BridgeCommand(
            cmd: Command.sign.rawValue,
            identity: remoteIdentity,
            payload: .signData(challenge),
            cid: 102
        )
        let decodedCommand = try JSONDecoder().decode(
            BridgeCommand.self,
            from: JSONEncoder().encode(wireCommand)
        )
        try await bridge.consumeCommand(command: decodedCommand)

        let sentCommands = try await waitUntilTransportHasSent(1, transport: transport)
        let response = try XCTUnwrap(sentCommands.first)
        XCTAssertEqual(response.command, .response)
        XCTAssertEqual(response.cid, 102)
        if case let .string(message) = response.payload {
            XCTAssertTrue(message.contains("identity is not available in the local signing vault"))
        } else {
            XCTFail("Expected signing denied string response")
        }
    }

    func testInboundBridgeSignCommandRejectsValidChallengeBeforeReady() async throws {
        let transport = MockBridgeTransport()
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "owner", makeNewIfNotFound: true)!
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        let challenge = try identityChallengeData(for: owner, nonce: "inbound-not-ready")

        let command = BridgeCommand(
            cmd: Command.sign.rawValue,
            identity: owner,
            payload: .signData(challenge),
            cid: 100
        )
        try await bridge.consumeCommand(command: command)

        XCTAssertEqual(transport.sentData.count, 1)
        let response = try JSONDecoder().decode(BridgeCommand.self, from: transport.sentData[0])
        XCTAssertEqual(response.command, .response)
        if case let .string(message) = response.payload {
            XCTAssertTrue(message.contains("not ready"))
        } else {
            XCTFail("Expected signing denied string response")
        }
    }

    func testBridgeBaseAdmitRoutesConcurrentResponsesByCommandID() async throws {
        let transport = MockBridgeTransport()
        let bridgeOwner = TestFixtures.makeIdentity(displayName: "bridge-owner")
        let firstOwner = TestFixtures.makeIdentity(displayName: "first-owner", uuid: TestFixtures.fixedUUID1)
        let secondOwner = TestFixtures.makeIdentity(displayName: "second-owner", uuid: TestFixtures.fixedUUID2)
        let config = BridgeBase.Config(owner: bridgeOwner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: bridgeOwner)

        async let firstState = bridge.admit(context: ConnectContext(source: nil, target: nil, identity: firstOwner))
        async let secondState = bridge.admit(context: ConnectContext(source: nil, target: nil, identity: secondOwner))

        let sentCommands = try await waitUntilTransportHasSent(2, transport: transport)
        let firstCommand = try XCTUnwrap(sentCommands.first(where: { $0.identity?.uuid == firstOwner.uuid }))
        let secondCommand = try XCTUnwrap(sentCommands.first(where: { $0.identity?.uuid == secondOwner.uuid }))

        try await bridge.consumeResponse(
            command: BridgeCommand(
                cmd: Command.response.rawValue,
                identity: secondOwner,
                payload: .connectState(.signContract),
                cid: secondCommand.cid
            )
        )
        try await bridge.consumeResponse(
            command: BridgeCommand(
                cmd: Command.response.rawValue,
                identity: firstOwner,
                payload: .connectState(.connected),
                cid: firstCommand.cid
            )
        )

        let resolvedFirst = await firstState
        let resolvedSecond = await secondState
        XCTAssertEqual(resolvedFirst, .connected)
        XCTAssertEqual(resolvedSecond, .signContract)
    }

    func testBridgeBaseAgreementRoutesConcurrentResponsesByCommandID() async throws {
        let transport = MockBridgeTransport()
        let bridgeOwner = TestFixtures.makeIdentity(displayName: "bridge-owner")
        let firstOwner = TestFixtures.makeIdentity(displayName: "first-owner", uuid: TestFixtures.fixedUUID1)
        let secondOwner = TestFixtures.makeIdentity(displayName: "second-owner", uuid: TestFixtures.fixedUUID2)
        let config = BridgeBase.Config(owner: bridgeOwner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: bridgeOwner)

        let firstAgreement = Agreement(owner: firstOwner)
        let secondAgreement = Agreement(owner: secondOwner)

        async let firstState = bridge.addAgreement(firstAgreement, for: firstOwner)
        async let secondState = bridge.addAgreement(secondAgreement, for: secondOwner)

        let sentCommands = try await waitUntilTransportHasSent(2, transport: transport)
        let firstCommand = try XCTUnwrap(sentCommands.first(where: { $0.identity?.uuid == firstOwner.uuid }))
        let secondCommand = try XCTUnwrap(sentCommands.first(where: { $0.identity?.uuid == secondOwner.uuid }))

        try await bridge.consumeResponse(
            command: BridgeCommand(
                cmd: Command.response.rawValue,
                identity: secondOwner,
                payload: .contractState(.rejected),
                cid: secondCommand.cid
            )
        )
        try await bridge.consumeResponse(
            command: BridgeCommand(
                cmd: Command.response.rawValue,
                identity: firstOwner,
                payload: .contractState(.signed),
                cid: firstCommand.cid
            )
        )

        let resolvedFirst = try await firstState
        let resolvedSecond = try await secondState
        XCTAssertEqual(resolvedFirst, .signed)
        XCTAssertEqual(resolvedSecond, .rejected)
    }

    func testBridgeBaseGetFailsImmediatelyWhenTransportSendFails() async throws {
        let transport = FailingBridgeTransport()
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver

        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)

        do {
            _ = try await bridge.get(keypath: "state", requester: owner)
            XCTFail("Expected transport send failure")
        } catch {
            XCTAssertEqual(error as? FailingBridgeTransport.TransportFailure, .notConnected)
        }
    }

    func testBridgeBaseReadySticksWhenSignalArrivesBeforeWaiter() async throws {
        let transport = MockBridgeTransport()
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)

        try await bridge.consumeCommand(
            command: BridgeCommand(
                cmd: Command.ready.rawValue,
                identity: owner,
                payload: nil,
                cid: 1
            )
        )

        try await bridge.ready(timeout: 1)
    }

    func testBridgeBaseDefersOutboundSendUntilReadySignalArrives() async throws {
        let transport = MockBridgeTransport()
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)

        let sendTask = Task {
            await bridge.sendCommand(command: .get, identity: owner, payload: .string("state"))
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(transport.sentData.isEmpty)

        try await bridge.consumeCommand(
            command: BridgeCommand(
                cmd: Command.ready.rawValue,
                identity: owner,
                payload: nil,
                cid: 2
            )
        )

        await sendTask.value
        XCTAssertEqual(transport.sentData.count, 1)

        let sentCommand = try JSONDecoder().decode(BridgeCommand.self, from: transport.sentData[0])
        XCTAssertEqual(sentCommand.command, .get)
        if case let .string(keypath) = sentCommand.payload {
            XCTAssertEqual(keypath, "state")
        } else {
            XCTFail("Expected string payload")
        }
    }

    func testBridgeBaseSharesOneRemoteFeedAcrossLocalSubscribers() async throws {
        let transport = MockBridgeTransport()
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let bridge = try await BridgeBase(
            BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        )
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)

        let firstPublisher = try await bridge.flow(requester: owner)
        let secondPublisher = try await bridge.flow(requester: owner)
        let sentCommands = try await waitUntilTransportHasSent(1, transport: transport)
        let feedCommand = try XCTUnwrap(sentCommands.first)
        XCTAssertEqual(feedCommand.command, .feed)
        XCTAssertEqual(sentCommands.filter { $0.command == .feed }.count, 1)

        let firstReceived = expectation(description: "first subscriber receives remote flow")
        let secondReceived = expectation(description: "second subscriber receives remote flow")
        let secondSurvivesFirstCancellation = expectation(description: "second subscriber stays active")
        var secondValues = [String]()

        var firstCancellable: AnyCancellable? = firstPublisher.sink(
            receiveCompletion: { _ in },
            receiveValue: { flowElement in
                if flowElement.id == "shared-1" {
                    firstReceived.fulfill()
                }
            }
        )
        var secondCancellable: AnyCancellable? = secondPublisher.sink(
            receiveCompletion: { _ in },
            receiveValue: { flowElement in
                secondValues.append(flowElement.id)
                if flowElement.id == "shared-1" {
                    secondReceived.fulfill()
                } else if flowElement.id == "shared-2" {
                    secondSurvivesFirstCancellation.fulfill()
                }
            }
        )

        try await bridge.consumeResponse(command: BridgeCommand(
            cmd: Command.response.rawValue,
            identity: owner,
            payload: .flowElement(FlowElement(
                id: "shared-1",
                title: "first",
                content: .string("one"),
                properties: .init(type: .content, contentType: .string)
            )),
            cid: feedCommand.cid
        ))
        await fulfillment(of: [firstReceived, secondReceived], timeout: 1)

        firstCancellable?.cancel()
        firstCancellable = nil
        XCTAssertEqual(
            try transport.sentData.map { try JSONDecoder().decode(BridgeCommand.self, from: $0) }
                .filter { $0.command == .stopFeed }
                .count,
            0
        )

        try await bridge.consumeResponse(command: BridgeCommand(
            cmd: Command.response.rawValue,
            identity: owner,
            payload: .flowElement(FlowElement(
                id: "shared-2",
                title: "second",
                content: .string("two"),
                properties: .init(type: .content, contentType: .string)
            )),
            cid: feedCommand.cid
        ))
        await fulfillment(of: [secondSurvivesFirstCancellation], timeout: 1)
        XCTAssertEqual(secondValues, ["shared-1", "shared-2"])

        secondCancellable?.cancel()
        secondCancellable = nil
        let afterCancellation = try await waitUntilTransportHasSent(2, transport: transport)
        let stopCommand = try XCTUnwrap(afterCancellation.first(where: { $0.command == .stopFeed }))
        XCTAssertEqual(stopCommand.payload, .integer(feedCommand.cid))
    }

    func testCellResolverBuildsPublisherFirstBridgeheadURLWhenRouteRequestsIt() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = vault
        RecordingBridgeTransport.reset()

        try await resolver.registerTransport(RecordingBridgeTransport.self, for: "wss")
        resolver.registerRemoteCellHost(
            "bridge-layout.example",
            route: RemoteCellHostRoute(
                websocketEndpoint: "bridgehead",
                schemePreference: .wss,
                pathLayout: .publisherUUIDThenEndpoint
            )
        )

        let requesterValue = await vault.identity(for: "requester", makeNewIfNotFound: true)
        let requester = try XCTUnwrap(requesterValue)
        _ = try await resolver.cellAtEndpoint(
            endpoint: "cell://bridge-layout.example/ConferenceAIGatewayPreview",
            requester: requester
        )

        let setupURL = try XCTUnwrap(RecordingBridgeTransport.recordedSetupURL())
        let components = try XCTUnwrap(URLComponents(url: setupURL, resolvingAgainstBaseURL: false))
        let pathComponents = components.path.split(separator: "/").map(String.init)

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "bridge-layout.example")
        XCTAssertEqual(pathComponents.count, 3)
        XCTAssertEqual(pathComponents[0], "bridgehead")
        XCTAssertEqual(pathComponents[2], "ConferenceAIGatewayPreview")
        XCTAssertEqual(pathComponents[1].count, 36)
    }

    func testCellResolverRouteReplacementInvalidatesCachedRemoteBridge() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = vault
        RecordingBridgeTransport.reset()
        try await resolver.registerTransport(RecordingBridgeTransport.self, for: "wss")
        let host = "route-replacement-\(UUID().uuidString.lowercased()).example"
        let endpoint = "cell://\(host)/RuntimeSurface"
        let resolvedIdentity = await vault.identity(
            for: "route-replacement-owner",
            makeNewIfNotFound: true
        )
        let identity = try XCTUnwrap(resolvedIdentity)

        resolver.registerRemoteCellHost(
            host,
            route: RemoteCellHostRoute(websocketEndpoint: "bridge-a", schemePreference: .wss)
        )
        let first = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)

        resolver.registerRemoteCellHost(
            host,
            route: RemoteCellHostRoute(websocketEndpoint: "bridge-b", schemePreference: .wss)
        )
        let second = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)
        let setupURLs = RecordingBridgeTransport.recordedSetupURLs()

        XCTAssertNotEqual(first.uuid, second.uuid)
        XCTAssertEqual(setupURLs.count, 2)
        let globallyRegisteredBridgeUUID = await resolver.cellUUID(for: endpoint)
        XCTAssertNil(globallyRegisteredBridgeUUID)
        if setupURLs.count == 2 {
            XCTAssertEqual(setupURLs[0].path.split(separator: "/").first.map(String.init), "bridge-a")
            XCTAssertEqual(setupURLs[1].path.split(separator: "/").first.map(String.init), "bridge-b")
        }
    }

    func testCellResolverUnregisterRevokesCachedRemoteBridge() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = vault
        RecordingBridgeTransport.reset()
        try await resolver.registerTransport(RecordingBridgeTransport.self, for: "wss")
        let host = "route-unregister-\(UUID().uuidString.lowercased()).example"
        let endpoint = "cell://\(host)/RuntimeSurface"
        let resolvedIdentity = await vault.identity(
            for: "route-unregister-owner",
            makeNewIfNotFound: true
        )
        let identity = try XCTUnwrap(resolvedIdentity)

        resolver.registerRemoteCellHost(
            host,
            route: RemoteCellHostRoute(websocketEndpoint: "bridgehead", schemePreference: .wss)
        )
        _ = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)
        resolver.unregisterRemoteCellHost(host)

        do {
            _ = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)
            XCTFail("Unregistered host must not resolve through a cached bridge")
        } catch CellResolverError.missingRemoteCellHostRegistration(let deniedHost) {
            XCTAssertEqual(deniedHost, host)
        } catch {
            XCTFail("Expected missingRemoteCellHostRegistration, got \(error)")
        }
        XCTAssertEqual(RecordingBridgeTransport.recordedSetupURLs().count, 1)
    }

    func testCellResolverIdenticalRouteRegistrationKeepsCachedRemoteBridge() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = vault
        RecordingBridgeTransport.reset()
        try await resolver.registerTransport(RecordingBridgeTransport.self, for: "wss")
        let host = "route-stable-\(UUID().uuidString.lowercased()).example"
        let endpoint = "cell://\(host)/RuntimeSurface"
        let resolvedIdentity = await vault.identity(
            for: "route-stable-owner",
            makeNewIfNotFound: true
        )
        let identity = try XCTUnwrap(resolvedIdentity)
        let route = RemoteCellHostRoute(
            websocketEndpoint: "bridgehead",
            schemePreference: .wss,
            pathLayout: .publisherUUIDThenEndpoint
        )

        resolver.registerRemoteCellHost(host, route: route)
        let first = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)
        resolver.registerRemoteCellHost(host, route: route)
        let second = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)

        XCTAssertEqual(first.uuid, second.uuid)
        XCTAssertEqual(RecordingBridgeTransport.recordedSetupURLs().count, 1)
    }

    func testCellResolverRemoteBridgeSeparatesProofBearingPrincipalsWithSameUUID() async throws {
        let resolver = CellResolver.sharedInstance
        let firstVault = EphemeralIdentityVault()
        let secondVault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        RecordingBridgeTransport.reset()
        try await resolver.registerTransport(RecordingBridgeTransport.self, for: "wss")
        let host = "route-principal-\(UUID().uuidString.lowercased()).example"
        let endpoint = "cell://\(host)/RuntimeSurface"
        resolver.registerRemoteCellHost(
            host,
            route: RemoteCellHostRoute(websocketEndpoint: "bridgehead", schemePreference: .wss)
        )
        let resolvedFirst = await firstVault.identity(
            for: "route-principal-first",
            makeNewIfNotFound: true
        )
        let first = try XCTUnwrap(resolvedFirst)
        let resolvedSecond = await secondVault.identity(
            for: "route-principal-second",
            makeNewIfNotFound: true
        )
        let second = try XCTUnwrap(resolvedSecond)
        let secondKey = try XCTUnwrap(second.publicSecureKey)
        let wrongKey = Identity(first.uuid, displayName: "wrong-key", identityVault: secondVault)
        wrongKey.publicSecureKey = secondKey
        wrongKey.homeVaultReference = second.homeVaultReference

        let firstBridge = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: first)
        let secondPrincipalBridge = try await resolver.cellAtEndpoint(
            endpoint: endpoint,
            requester: wrongKey
        )

        XCTAssertNotEqual(firstBridge.uuid, secondPrincipalBridge.uuid)
        XCTAssertEqual(RecordingBridgeTransport.recordedSetupURLs().count, 2)
    }

    func testCellResolverRemoteBridgeRejectsCopiedDescriptorMissingOrWrongVaultProof() async throws {
        let resolver = CellResolver.sharedInstance
        let homeVault = EphemeralIdentityVault()
        let wrongVault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = homeVault
        RecordingBridgeTransport.reset()
        try await resolver.registerTransport(RecordingBridgeTransport.self, for: "wss")
        let host = "route-proof-\(UUID().uuidString.lowercased()).example"
        let endpoint = "cell://\(host)/RuntimeSurface"
        resolver.registerRemoteCellHost(
            host,
            route: RemoteCellHostRoute(websocketEndpoint: "bridgehead", schemePreference: .wss)
        )
        let ownerValue = await homeVault.identity(for: "route-proof-owner", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerValue)
        _ = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: owner)

        let copiedWithoutVault = Identity(owner.uuid, displayName: "copied", identityVault: nil)
        copiedWithoutVault.publicSecureKey = owner.publicSecureKey
        copiedWithoutVault.homeVaultReference = owner.homeVaultReference

        let copiedWithWrongVault = Identity(owner.uuid, displayName: "wrong-vault", identityVault: wrongVault)
        copiedWithWrongVault.publicSecureKey = owner.publicSecureKey
        copiedWithWrongVault.homeVaultReference = owner.homeVaultReference

        let missingHomeReference = Identity(owner.uuid, displayName: "missing-home", identityVault: homeVault)
        missingHomeReference.publicSecureKey = owner.publicSecureKey

        let missingSigningKey = Identity(owner.uuid, displayName: "missing-key", identityVault: homeVault)
        missingSigningKey.homeVaultReference = owner.homeVaultReference

        for deniedRequester in [
            copiedWithoutVault,
            copiedWithWrongVault,
            missingHomeReference,
            missingSigningKey
        ] {
            do {
                _ = try await resolver.cellAtEndpoint(
                    endpoint: endpoint,
                    requester: deniedRequester
                )
                XCTFail("Remote bridge resolution must require current private-key and home-vault control")
            } catch CellSetupError.ownerAuthorityUnavailable {
                // Expected.
            } catch {
                XCTFail("Expected ownerAuthorityUnavailable, got \(error)")
            }
        }

        XCTAssertEqual(RecordingBridgeTransport.recordedSetupURLs().count, 1)
    }

    func testCellResolverDirectWebSocketBridgeSeparatesPrincipalsAndRejectsCopiedDescriptor() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = EphemeralIdentityVault()
        let secondVault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = vault
        RecordingBridgeTransport.reset()
        try await resolver.registerTransport(RecordingBridgeTransport.self, for: "wss")
        let endpoint = "wss://direct-proof-\(UUID().uuidString.lowercased()).example/RuntimeSurface"
        let ownerValue = await vault.identity(for: "direct-proof-owner", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerValue)

        let firstBridge = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: owner)
        let secondOwnerValue = await secondVault.identity(
            for: "direct-proof-second-owner",
            makeNewIfNotFound: true
        )
        let secondOwner = try XCTUnwrap(secondOwnerValue)
        XCTAssertEqual(secondOwner.uuid, owner.uuid)
        let secondBridge = try await resolver.cellAtEndpoint(
            endpoint: endpoint,
            requester: secondOwner
        )
        XCTAssertNotEqual(firstBridge.uuid, secondBridge.uuid)

        let copied = Identity(owner.uuid, displayName: "copied", identityVault: nil)
        copied.publicSecureKey = owner.publicSecureKey
        copied.homeVaultReference = owner.homeVaultReference

        do {
            _ = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: copied)
            XCTFail("Direct WebSocket bridge cache must not accept a copied public descriptor")
        } catch CellSetupError.ownerAuthorityUnavailable {
            // Expected.
        } catch {
            XCTFail("Expected ownerAuthorityUnavailable, got \(error)")
        }

        XCTAssertEqual(RecordingBridgeTransport.recordedSetupURLs().count, 2)
        let globallyRegisteredBridgeUUID = await resolver.cellUUID(for: endpoint)
        XCTAssertNil(globallyRegisteredBridgeUUID)
    }

    func testCellResolverRouteReplacementWhileSetupIsPendingCannotPublishStaleBridge() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = vault
        await BlockingRouteBridgeTransport.setupGate.reset()
        try await resolver.registerTransport(BlockingRouteBridgeTransport.self, for: "wss")
        let host = "route-pending-\(UUID().uuidString.lowercased()).example"
        let endpoint = "cell://\(host)/RuntimeSurface"
        let resolvedIdentity = await vault.identity(
            for: "route-pending-owner",
            makeNewIfNotFound: true
        )
        let identity = try XCTUnwrap(resolvedIdentity)

        resolver.registerRemoteCellHost(
            host,
            route: RemoteCellHostRoute(websocketEndpoint: "bridge-a", schemePreference: .wss)
        )
        let resolution = Task {
            try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)
        }
        try await waitForBlockingRouteSetupCount(1)

        resolver.registerRemoteCellHost(
            host,
            route: RemoteCellHostRoute(websocketEndpoint: "bridge-b", schemePreference: .wss)
        )
        await BlockingRouteBridgeTransport.setupGate.releaseNext()
        try await waitForBlockingRouteSetupCount(2)
        await BlockingRouteBridgeTransport.setupGate.releaseNext()

        let resolved = try await resolution.value
        let cached = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)
        let setupURLs = await BlockingRouteBridgeTransport.setupGate.recordedSetupURLs()

        XCTAssertEqual(resolved.uuid, cached.uuid)
        XCTAssertEqual(setupURLs.count, 2)
        if setupURLs.count == 2 {
            XCTAssertEqual(setupURLs[0].path.split(separator: "/").first.map(String.init), "bridge-a")
            XCTAssertEqual(setupURLs[1].path.split(separator: "/").first.map(String.init), "bridge-b")
        }
    }

    func testCellResolverPinnedRouteFailsInsteadOfRetryingThroughReplacement() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = vault
        await BlockingRouteBridgeTransport.setupGate.reset()
        try await resolver.registerTransport(BlockingRouteBridgeTransport.self, for: "wss")
        let host = "route-pinned-\(UUID().uuidString.lowercased()).example"
        let endpoint = "cell://\(host)/RuntimeSurface"
        let resolvedIdentity = await vault.identity(
            for: "route-pinned-owner",
            makeNewIfNotFound: true
        )
        let identity = try XCTUnwrap(resolvedIdentity)
        let routeA = RemoteCellHostRoute(websocketEndpoint: "BridgeA", schemePreference: .wss)
        let routeB = RemoteCellHostRoute(websocketEndpoint: "bridgeb", schemePreference: .wss)

        let pinnedResolution = Task {
            try await resolver.cellAtEndpoint(
                endpoint: endpoint,
                requester: identity,
                remoteRoute: routeA
            )
        }
        try await waitForBlockingRouteSetupCount(1)
        resolver.registerRemoteCellHost(host, route: routeB)
        resolver.registerRemoteCellHost(host, route: routeA)
        await BlockingRouteBridgeTransport.setupGate.releaseNext()

        do {
            _ = try await pinnedResolution.value
            XCTFail("Pinned resolution must fail after route replacement, even when the same route is restored")
        } catch {
            // The exact internal route error is intentionally not part of the
            // public API; the invariant is failure without a replacement retry.
        }
        let setupURLs = await BlockingRouteBridgeTransport.setupGate.recordedSetupURLs()
        XCTAssertEqual(setupURLs.count, 1)
        XCTAssertEqual(
            setupURLs.first?.path.split(separator: "/").first.map(String.init),
            "BridgeA"
        )
    }

    func testCellResolverPinnedRouteCapturesItsOwnGenerationAtomically() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = vault
        RecordingBridgeTransport.reset()
        try await resolver.registerTransport(RecordingBridgeTransport.self, for: "wss")
        let host = "route-installation-\(UUID().uuidString.lowercased()).example"
        let endpoint = "cell://\(host)/RuntimeSurface"
        let identityValue = await vault.identity(
            for: "route-installation-owner",
            makeNewIfNotFound: true
        )
        let identity = try XCTUnwrap(identityValue)
        let routeA = RemoteCellHostRoute(websocketEndpoint: "BridgeA", schemePreference: .wss)
        let routeB = RemoteCellHostRoute(websocketEndpoint: "bridgeb", schemePreference: .wss)
        let installationGate = RemoteRouteInstallationGate()
        resolver.setRemoteRouteInstalledHookForTesting { installedHost, generation in
            await installationGate.arriveAndWait(host: installedHost, generation: generation)
        }
        defer {
            resolver.setRemoteRouteInstalledHookForTesting(nil)
        }

        let pinnedResolution = Task {
            try await resolver.cellAtEndpoint(
                endpoint: endpoint,
                requester: identity,
                remoteRoute: routeA
            )
        }
        let installed = await installationGate.waitForInstallation()
        XCTAssertEqual(installed.host, host)
        resolver.registerRemoteCellHost(host, route: routeB)
        resolver.registerRemoteCellHost(host, route: routeA)
        resolver.setRemoteRouteInstalledHookForTesting(nil)
        await installationGate.release()

        do {
            _ = try await pinnedResolution.value
            XCTFail("Pinned resolution must retain its own generation across register-to-resolve ABA churn")
        } catch {
            // Expected: the route text matches again, but its generation does not.
        }
        XCTAssertTrue(RecordingBridgeTransport.recordedSetupURLs().isEmpty)
    }

    func testCellResolverRemoteBridgeUsesOwnedPrincipalSnapshotAcrossCallerMutation() async throws {
        let resolver = CellResolver.sharedInstance
        let firstVault = EphemeralIdentityVault()
        let secondVault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = firstVault
        await BlockingRouteBridgeTransport.setupGate.reset()
        try await resolver.registerTransport(BlockingRouteBridgeTransport.self, for: "wss")
        let host = "route-principal-snapshot-\(UUID().uuidString.lowercased()).example"
        let endpoint = "cell://\(host)/RuntimeSurface"
        resolver.registerRemoteCellHost(
            host,
            route: RemoteCellHostRoute(websocketEndpoint: "bridgehead", schemePreference: .wss)
        )
        let firstValue = await firstVault.identity(for: "snapshot-first", makeNewIfNotFound: true)
        let secondValue = await secondVault.identity(for: "snapshot-second", makeNewIfNotFound: true)
        let callerOwnedIdentity = try XCTUnwrap(firstValue)
        let replacementIdentity = try XCTUnwrap(secondValue)
        XCTAssertEqual(callerOwnedIdentity.uuid, replacementIdentity.uuid)
        let firstFingerprint = try XCTUnwrap(callerOwnedIdentity.signingPublicKeyFingerprint)
        let firstHomeVaultReference = try XCTUnwrap(callerOwnedIdentity.homeVaultReference)
        let secondFingerprint = try XCTUnwrap(replacementIdentity.signingPublicKeyFingerprint)
        let secondHomeVaultReference = try XCTUnwrap(replacementIdentity.homeVaultReference)

        let firstResolution = Task {
            try await resolver.cellAtEndpoint(
                endpoint: endpoint,
                requester: callerOwnedIdentity
            )
        }
        try await waitForBlockingRouteSetupCount(1)
        let firstSetupIdentities = await BlockingRouteBridgeTransport.setupGate.recordedSetupIdentities()
        let firstSetupIdentity = try XCTUnwrap(firstSetupIdentities.first)

        callerOwnedIdentity.publicSecureKey = replacementIdentity.publicSecureKey
        callerOwnedIdentity.publicKeyAgreementSecureKey = replacementIdentity.publicKeyAgreementSecureKey
        callerOwnedIdentity.homeVaultReference = replacementIdentity.homeVaultReference
        callerOwnedIdentity.identityVault = secondVault

        XCTAssertFalse(firstSetupIdentity === callerOwnedIdentity)
        XCTAssertEqual(firstSetupIdentity.signingPublicKeyFingerprint, firstFingerprint)
        XCTAssertEqual(firstSetupIdentity.homeVaultReference, firstHomeVaultReference)
        await BlockingRouteBridgeTransport.setupGate.releaseNext()
        let firstBridge = try await firstResolution.value

        let secondResolution = Task {
            try await resolver.cellAtEndpoint(
                endpoint: endpoint,
                requester: callerOwnedIdentity
            )
        }
        try await waitForBlockingRouteSetupCount(2)
        let setupIdentities = await BlockingRouteBridgeTransport.setupGate.recordedSetupIdentities()
        XCTAssertEqual(setupIdentities.count, 2)
        if setupIdentities.count == 2 {
            XCTAssertFalse(setupIdentities[1] === callerOwnedIdentity)
            XCTAssertEqual(setupIdentities[1].signingPublicKeyFingerprint, secondFingerprint)
            XCTAssertEqual(setupIdentities[1].homeVaultReference, secondHomeVaultReference)
        }
        await BlockingRouteBridgeTransport.setupGate.releaseNext()
        let secondBridge = try await secondResolution.value

        XCTAssertNotEqual(firstBridge.uuid, secondBridge.uuid)
    }

    func testCellResolverUnregisterWhileSetupIsPendingCannotReturnOrPublishBridge() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = vault
        await BlockingRouteBridgeTransport.setupGate.reset()
        try await resolver.registerTransport(BlockingRouteBridgeTransport.self, for: "wss")
        let host = "route-pending-unregister-\(UUID().uuidString.lowercased()).example"
        let endpoint = "cell://\(host)/RuntimeSurface"
        let resolvedIdentity = await vault.identity(
            for: "route-pending-unregister-owner",
            makeNewIfNotFound: true
        )
        let identity = try XCTUnwrap(resolvedIdentity)
        resolver.registerRemoteCellHost(
            host,
            route: RemoteCellHostRoute(websocketEndpoint: "bridgehead", schemePreference: .wss)
        )

        let resolution = Task {
            try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)
        }
        try await waitForBlockingRouteSetupCount(1)
        resolver.unregisterRemoteCellHost(host)
        await BlockingRouteBridgeTransport.setupGate.releaseNext()

        do {
            _ = try await resolution.value
            XCTFail("Unregister must revoke an in-flight remote bridge resolution")
        } catch CellResolverError.missingRemoteCellHostRegistration(let deniedHost) {
            XCTAssertEqual(deniedHost, host)
        } catch {
            XCTFail("Expected missingRemoteCellHostRegistration, got \(error)")
        }
        let setupCount = await BlockingRouteBridgeTransport.setupGate.recordedSetupURLs().count
        XCTAssertEqual(setupCount, 1)
        let globallyRegisteredBridgeUUID = await resolver.cellUUID(for: endpoint)
        XCTAssertNil(globallyRegisteredBridgeUUID)
    }

    func testCellResolverRouteChurnDoesNotSwallowCallerCancellation() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = vault
        await BlockingRouteBridgeTransport.setupGate.reset()
        try await resolver.registerTransport(BlockingRouteBridgeTransport.self, for: "wss")
        let host = "route-cancel-\(UUID().uuidString.lowercased()).example"
        let endpoint = "cell://\(host)/RuntimeSurface"
        let identityValue = await vault.identity(for: "route-cancel-owner", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(identityValue)
        resolver.registerRemoteCellHost(
            host,
            route: RemoteCellHostRoute(websocketEndpoint: "bridge-a", schemePreference: .wss)
        )

        let resolution = Task {
            try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)
        }
        try await waitForBlockingRouteSetupCount(1)
        resolver.registerRemoteCellHost(
            host,
            route: RemoteCellHostRoute(websocketEndpoint: "bridge-b", schemePreference: .wss)
        )
        resolution.cancel()
        await BlockingRouteBridgeTransport.setupGate.releaseNext()

        do {
            _ = try await resolution.value
            XCTFail("Route churn must not convert caller cancellation into a successful retry")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let setupCount = await BlockingRouteBridgeTransport.setupGate.recordedSetupURLs().count
        XCTAssertEqual(setupCount, 1)
    }

    func testCancelledWaiterPublishesSuccessfullyOpenedRemoteBridgeForReuse() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = vault
        await BlockingRouteBridgeTransport.setupGate.reset()
        try await resolver.registerTransport(BlockingRouteBridgeTransport.self, for: "wss")
        let host = "route-cancelled-waiter-\(UUID().uuidString.lowercased()).example"
        let endpoint = "cell://\(host)/RuntimeSurface"
        let identityValue = await vault.identity(for: "route-cancelled-waiter-owner", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(identityValue)
        resolver.registerRemoteCellHost(
            host,
            route: RemoteCellHostRoute(websocketEndpoint: "bridge", schemePreference: .wss)
        )

        let cancelledResolution = Task {
            try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)
        }
        try await waitForBlockingRouteSetupCount(1)
        cancelledResolution.cancel()
        await BlockingRouteBridgeTransport.setupGate.releaseNext()

        do {
            _ = try await cancelledResolution.value
            XCTFail("A cancelled waiter must still observe cancellation")
        } catch is CancellationError {
            // Expected. The shared bridge result is still published for reuse.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let reusedBridge = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)
        let setupCount = await BlockingRouteBridgeTransport.setupGate.recordedSetupURLs().count
        XCTAssertEqual(setupCount, 1)
        let globallyRegisteredBridgeUUID = await resolver.cellUUID(for: endpoint)
        XCTAssertNil(globallyRegisteredBridgeUUID)
        XCTAssertFalse(reusedBridge.uuid.isEmpty)
    }

    private func waitForBlockingRouteSetupCount(_ expectedCount: Int) async throws {
        for _ in 0..<1_000 {
            if await BlockingRouteBridgeTransport.setupGate.recordedSetupURLs().count >= expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(expectedCount) blocked route setup calls")
        throw CellResolverError.bridgeSetupError
    }

    private func waitUntilTransportHasSent(_ expectedCount: Int, transport: MockBridgeTransport) async throws -> [BridgeCommand] {
        for _ in 0..<50 {
            let sentData = transport.sentData
            if sentData.count >= expectedCount {
                return try sentData.map { try JSONDecoder().decode(BridgeCommand.self, from: $0) }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw XCTSkip("Timed out waiting for transport to send \(expectedCount) command(s)")
    }

    private func markBridgeReady(_ bridge: BridgeBase, identity: Identity) async throws {
        try await bridge.consumeCommand(
            command: BridgeCommand(
                cmd: Command.ready.rawValue,
                identity: identity,
                payload: nil,
                cid: 0
            )
        )
    }

    private func bridgeCommandJSON(_ command: BridgeCommand) throws -> [String: Any] {
        let data = try JSONEncoder().encode(command)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func identityChallengeData(for identity: Identity, nonce: String) throws -> Data {
        var nonceData = Data(nonce.utf8)
        if nonceData.count < IdentitySigningChallenge.minimumNonceBytes {
            nonceData.append(
                Data(
                    repeating: 0,
                    count: IdentitySigningChallenge.minimumNonceBytes - nonceData.count
                )
            )
        }
        return try IdentitySigningChallenge.signingData(
            for: identity,
            trustedIdentity: identity,
            domain: "bridge-test",
            resource: "bridge",
            action: "sign",
            audience: "BridgeTests",
            nonce: nonceData
        )
    }
}

private actor BridgeAlwaysTrueVerificationVault: IdentityVaultProtocol {
    func initialize() async -> IdentityVaultProtocol { self }

    func addIdentity(identity: inout Identity, for identityContext: String) async {
        identity.identityVault = self
    }

    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? {
        nil
    }

    func saveIdentity(_ identity: Identity) async {}

    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        Data(repeating: 0xA5, count: 64)
    }

    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        true
    }

    func randomBytes64() async -> Data? {
        Data(repeating: 0xA5, count: 64)
    }

    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        ("always-true-\(tag)", "always-true-iv")
    }
}

private final class FailingBridgeTransport: BridgeTransportProtocol {
    enum TransportFailure: Error {
        case notConnected
    }

    private let vault: IdentityVaultProtocol

    init(vault: IdentityVaultProtocol = MockIdentityVault()) {
        self.vault = vault
    }

    static func new() -> BridgeTransportProtocol {
        FailingBridgeTransport()
    }

    func setDelegate(_ delegate: BridgeDelegateProtocol) {}

    func setup(_ endpointURL: URL, identity: Identity) async throws {}

    func sendData(_ data: Data) async throws {
        throw TransportFailure.notConnected
    }

    func identityVault(for: Identity?) async -> IdentityVaultProtocol {
        vault
    }
}
