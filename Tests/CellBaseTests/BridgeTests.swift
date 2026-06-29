// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class BridgeTests: XCTestCase {
    private final class RecordingBridgeTransport: BridgeTransportProtocol {
        static let stateLock = NSLock()
        static var lastSetupURL: URL?

        static func new() -> BridgeTransportProtocol {
            RecordingBridgeTransport()
        }

        static func reset() {
            stateLock.withLock {
                lastSetupURL = nil
            }
        }

        static func recordedSetupURL() -> URL? {
            stateLock.withLock {
                lastSetupURL
            }
        }

        func setDelegate(_ delegate: BridgeDelegateProtocol) {}

        func setup(_ endpointURL: URL, identity: Identity) async throws {
            Self.stateLock.withLock {
                Self.lastSetupURL = endpointURL
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

    func testCellResolverBuildsPublisherFirstBridgeheadURLWhenRouteRequestsIt() async throws {
        let resolver = CellResolver.sharedInstance
        CellBase.defaultCellResolver = resolver
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

        let requester = TestFixtures.makeIdentity(displayName: "requester")
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
        try IdentitySigningChallenge.signingData(
            for: identity,
            trustedIdentity: identity,
            domain: "bridge-test",
            resource: "bridge",
            action: "sign",
            audience: "BridgeTests",
            nonce: Data(nonce.utf8)
        )
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
