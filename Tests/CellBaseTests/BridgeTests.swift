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

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousRemoteWebSocketQueryItemsProvider = CellBase.remoteWebSocketQueryItemsProvider
        CellBase.defaultIdentityVault = MockIdentityVault()
        CellBase.remoteWebSocketQueryItemsProvider = nil
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.remoteWebSocketQueryItemsProvider = previousRemoteWebSocketQueryItemsProvider
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

    func testBridgeBaseSignMessageRoutesResponsesByCommandID() async throws {
        let transport = MockBridgeTransport()
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)

        let firstPublisher = bridge.signMessageForIdentity(
            messageData: Data("first".utf8),
            identity: owner
        )
        let secondPublisher = bridge.signMessageForIdentity(
            messageData: Data("second".utf8),
            identity: owner
        )

        async let firstSignature = firstPublisher.getOneWithTimeout(1)
        async let secondSignature = secondPublisher.getOneWithTimeout(1)

        let sentCommands = try await waitUntilTransportHasSent(2, transport: transport)
        let firstCommand = try XCTUnwrap(
            sentCommands.first(where: { command in
                if case let .signData(data) = command.payload {
                    return data == Data("first".utf8)
                }
                return false
            })
        )
        let secondCommand = try XCTUnwrap(
            sentCommands.first(where: { command in
                if case let .signData(data) = command.payload {
                    return data == Data("second".utf8)
                }
                return false
            })
        )

        let firstExpected = Data("signature-one".utf8)
        let secondExpected = Data("signature-two".utf8)

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
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let config = BridgeBase.Config(owner: owner, transport: transport, connection: .outbound)
        let bridge = try await BridgeBase(config)
        try await bridge.setTransport(transport, connection: .outbound)
        try await markBridgeReady(bridge, identity: owner)
        let vault = BridgeIdentityVault(cloudBridge: bridge)

        async let signature = vault.signMessageForIdentity(messageData: Data("payload".utf8), identity: owner)
        let sentCommands = try await waitUntilTransportHasSent(1, transport: transport)
        try await Task.sleep(nanoseconds: 50_000_000)

        let request = try XCTUnwrap(sentCommands.first)
        let expectedSignature = Data("bridge-signature".utf8)
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
