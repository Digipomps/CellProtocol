// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class BridgeMultiplexingTests: XCTestCase {
    private final class PassiveBridgeDelegate: BridgeDelegateProtocol {
        let uuid = UUID().uuidString

        func consumeCommand(command: BridgeCommand) async throws { _ = command }
        func consumeResponse(command: BridgeCommand) async throws { _ = command }
        func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {
            _ = command
            _ = identity
            _ = payload
        }
        func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {
            _ = requestedKey
            _ = setValueState
        }
        func pushError(errorMessage: String?, error: Error?) async {
            _ = errorMessage
            _ = error
        }
        func ready() async throws {}
    }

    private final class GapRecordingDelegate: BridgeDelegateProtocol {
        let uuid = UUID().uuidString
        private let stateLock = NSLock()
        private var responseCount = 0
        private var messages: [String] = []

        func consumeCommand(command: BridgeCommand) async throws { _ = command }
        func consumeResponse(command: BridgeCommand) async throws {
            _ = command
            stateLock.withLock { responseCount += 1 }
        }
        func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {
            _ = command
            _ = identity
            _ = payload
        }
        func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {
            _ = requestedKey
            _ = setValueState
        }
        func pushError(errorMessage: String?, error: Error?) async {
            _ = error
            if let errorMessage {
                stateLock.withLock { messages.append(errorMessage) }
            }
        }
        func ready() async throws {}

        func snapshot() -> (responseCount: Int, messages: [String]) {
            stateLock.withLock { (responseCount, messages) }
        }
    }

    private final class ServerRecordingTransport: BridgeTransportProtocol {
        private weak var delegate: BridgeDelegateProtocol?
        private let stateLock = NSLock()
        private var frames: [BridgeCommand] = []

        static func new() -> BridgeTransportProtocol { ServerRecordingTransport() }
        func setDelegate(_ delegate: BridgeDelegateProtocol) { self.delegate = delegate }
        func setup(_ endpointURL: URL, identity: Identity) async throws {
            _ = endpointURL
            _ = identity
        }
        func sendData(_ data: Data) async throws {
            let frame = try JSONDecoder().decode(BridgeCommand.self, from: data)
            stateLock.withLock { frames.append(frame) }
        }
        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
            _ = identity
            return BridgeIdentityVault(cloudBridge: delegate as? BridgeProtocol)
        }
        func snapshot() -> [BridgeCommand] { stateLock.withLock { frames } }
    }

    private final class FailFirstChannelOpenedTransport: BridgeTransportProtocol {
        enum SendFailure: Error {
            case channelOpened
        }

        private weak var delegate: BridgeDelegateProtocol?
        private let stateLock = NSLock()
        private var failedChannelOpened = false
        private var frames: [BridgeCommand] = []

        static func new() -> BridgeTransportProtocol { FailFirstChannelOpenedTransport() }
        func setDelegate(_ delegate: BridgeDelegateProtocol) { self.delegate = delegate }
        func setup(_ endpointURL: URL, identity: Identity) async throws {
            _ = endpointURL
            _ = identity
        }
        func sendData(_ data: Data) async throws {
            let frame = try JSONDecoder().decode(BridgeCommand.self, from: data)
            let shouldFail = stateLock.withLock { () -> Bool in
                frames.append(frame)
                guard frame.command == .channelOpened, failedChannelOpened == false else {
                    return false
                }
                failedChannelOpened = true
                return true
            }
            if shouldFail {
                throw SendFailure.channelOpened
            }
        }
        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
            _ = identity
            return BridgeIdentityVault(cloudBridge: delegate as? BridgeProtocol)
        }
        func snapshot() -> [BridgeCommand] { stateLock.withLock { frames } }
    }

    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousSecurityEventSink: CellSecurityEventSink?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousSecurityEventSink = CellBase.securityEventSink
        CellBase.securityEventSink = nil
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.securityEventSink = previousSecurityEventSink
        super.tearDown()
    }

    private final class ResolverMultiplexTransport: BridgeTransportProtocol {
        private static let stateLock = NSLock()
        private static var instances = 0
        private static var setupURLs: [URL] = []

        private weak var delegate: BridgeDelegateProtocol?
        private let instanceLock = NSLock()
        private var targets: [String: String] = [:]

        init() {
            Self.stateLock.withLock { Self.instances += 1 }
        }

        static func new() -> BridgeTransportProtocol {
            ResolverMultiplexTransport()
        }

        static func reset() {
            stateLock.withLock {
                instances = 0
                setupURLs = []
            }
        }

        static func snapshot() -> (instances: Int, setupURLs: [URL]) {
            stateLock.withLock { (instances, setupURLs) }
        }

        func setDelegate(_ delegate: BridgeDelegateProtocol) {
            self.delegate = delegate
        }

        func setup(_ endpointURL: URL, identity: Identity) async throws {
            _ = identity
            Self.stateLock.withLock { Self.setupURLs.append(endpointURL) }
        }

        func sendData(_ data: Data) async throws {
            let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
            guard let channelID = command.channelID else {
                throw BridgeMultiplexError.invalidChannel
            }
            switch command.command {
            case .openChannel:
                guard let targetEndpoint = command.targetEndpoint else {
                    throw BridgeMultiplexError.invalidChannel
                }
                instanceLock.withLock { targets[channelID] = targetEndpoint }
                try await delegate?.consumeCommand(command: BridgeCommand(
                    cmd: Command.channelOpened.rawValue,
                    identity: command.identity,
                    payload: nil,
                    cid: command.cid,
                    protocolVersion: 2,
                    channelID: channelID
                ))
            case .description:
                guard let identity = command.identity,
                      let targetEndpoint = instanceLock.withLock({ targets[channelID] }) else {
                    throw BridgeMultiplexError.channelNotFound
                }
                let description = AnyCell(
                    uuid: UUID().uuidString,
                    name: targetEndpoint,
                    contractTemplate: Agreement(owner: identity),
                    owner: identity,
                    experiences: nil,
                    feedEndpoint: nil,
                    feedProperties: nil,
                    identityDomain: "resolver-multiplex-test"
                )
                let response = BridgeCommand(
                    cmd: Command.response.rawValue,
                    identity: identity,
                    payload: .description(description),
                    cid: command.cid,
                    protocolVersion: 2,
                    channelID: channelID
                )
                let delegate = delegate
                Task {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    try? await delegate?.consumeResponse(command: response)
                }
            default:
                break
            }
        }

        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
            _ = identity
            return BridgeIdentityVault()
        }
    }

    private final class MultiplexPhysicalTransport: BridgeTransportProtocol {
        private weak var delegate: BridgeDelegateProtocol?
        private let stateLock = NSLock()
        private let vault: IdentityVaultProtocol
        private var targets: [String: String] = [:]
        private var commands: [BridgeCommand] = []
        private var setupInvocations = 0
        private var closeInvocations = 0

        init(vault: IdentityVaultProtocol) {
            self.vault = vault
        }

        static func new() -> BridgeTransportProtocol {
            MultiplexPhysicalTransport(vault: EphemeralIdentityVault())
        }

        func setDelegate(_ delegate: BridgeDelegateProtocol) {
            self.delegate = delegate
        }

        func setup(_ endpointURL: URL, identity: Identity) async throws {
            _ = endpointURL
            _ = identity
            stateLock.withLock { setupInvocations += 1 }
        }

        func sendData(_ data: Data) async throws {
            let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
            stateLock.withLock { commands.append(command) }

            switch command.command {
            case .openChannel:
                guard let channelID = command.channelID,
                      let targetEndpoint = command.targetEndpoint else {
                    throw BridgeMultiplexError.invalidChannel
                }
                stateLock.withLock { targets[channelID] = targetEndpoint }
                try await delegate?.consumeCommand(command: BridgeCommand(
                    cmd: Command.channelOpened.rawValue,
                    identity: command.identity,
                    payload: nil,
                    cid: command.cid,
                    protocolVersion: 2,
                    channelID: channelID
                ))
            case .description:
                guard let identity = command.identity,
                      let channelID = command.channelID,
                      let targetEndpoint = stateLock.withLock({ targets[channelID] }) else {
                    throw BridgeMultiplexError.channelNotFound
                }
                let description = AnyCell(
                    uuid: UUID().uuidString,
                    name: targetEndpoint,
                    contractTemplate: Agreement(owner: identity),
                    owner: identity,
                    experiences: nil,
                    feedEndpoint: nil,
                    feedProperties: nil,
                    identityDomain: "multiplex-test"
                )
                let response = BridgeCommand(
                    cmd: Command.response.rawValue,
                    identity: identity,
                    payload: .description(description),
                    cid: command.cid,
                    protocolVersion: 2,
                    channelID: channelID
                )
                let delegate = delegate
                Task {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    try? await delegate?.consumeResponse(command: response)
                }
            default:
                break
            }
        }

        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
            _ = identity
            return vault
        }

        func close() async {
            stateLock.withLock { closeInvocations += 1 }
        }

        func snapshot() -> (setupInvocations: Int, closeInvocations: Int, commands: [BridgeCommand]) {
            stateLock.withLock { (setupInvocations, closeInvocations, commands) }
        }

        func injectResponse(_ command: BridgeCommand) async throws {
            try await delegate?.consumeResponse(command: command)
        }
    }

    func testBridgeCommandV2MetadataRoundTripsWithoutChangingLegacyDefaults() throws {
        let legacy = BridgeCommand(cmd: Command.feed.rawValue, payload: nil, cid: 1)
        let legacyDecoded = try JSONDecoder().decode(
            BridgeCommand.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertNil(legacyDecoded.protocolVersion)
        XCTAssertNil(legacyDecoded.channelID)

        let v2 = BridgeCommand(
            cmd: Command.response.rawValue,
            payload: .string("payload"),
            cid: 7,
            protocolVersion: 2,
            channelID: "channel-1",
            streamID: "stream-1",
            sequence: 42,
            resumeFromSequence: 40
        )
        let decoded = try JSONDecoder().decode(
            BridgeCommand.self,
            from: JSONEncoder().encode(v2)
        )
        XCTAssertEqual(decoded.protocolVersion, 2)
        XCTAssertEqual(decoded.channelID, "channel-1")
        XCTAssertEqual(decoded.streamID, "stream-1")
        XCTAssertEqual(decoded.sequence, 42)
        XCTAssertEqual(decoded.resumeFromSequence, 40)
    }

    func testContinuityTrackerDetectsGapWithoutClaimingReplay() {
        let tracker = BridgeFlowContinuityTracker()

        XCTAssertEqual(tracker.observe(streamID: nil, sequence: nil), .untracked)
        XCTAssertEqual(tracker.observe(streamID: "stream", sequence: 7), .first(sequence: 7))
        XCTAssertEqual(tracker.observe(streamID: "stream", sequence: 8), .contiguous(sequence: 8))
        XCTAssertEqual(tracker.observe(streamID: "stream", sequence: 8), .duplicate(sequence: 8))
        XCTAssertEqual(
            tracker.observe(streamID: "stream", sequence: 6),
            .outOfOrder(lastSeen: 8, received: 6)
        )
        XCTAssertEqual(
            tracker.observe(streamID: "stream", sequence: 11),
            .gap(expected: 9, received: 11)
        )
        XCTAssertEqual(tracker.watermark(for: "stream"), 11)
    }

    func testContinuityTrackerBoundsStreamsAndRejectsOversizedIdentifiers() {
        let tracker = BridgeFlowContinuityTracker(maximumStreams: 2)

        XCTAssertEqual(tracker.observe(streamID: "first", sequence: 1), .first(sequence: 1))
        XCTAssertEqual(tracker.observe(streamID: "second", sequence: 1), .first(sequence: 1))
        XCTAssertEqual(tracker.observe(streamID: "third", sequence: 1), .first(sequence: 1))
        XCTAssertNil(tracker.watermark(for: "first"))
        XCTAssertEqual(tracker.trackedStreamCount(), 2)

        let oversized = String(repeating: "x", count: BridgeMultiplexSession.maximumStreamIDBytes + 1)
        XCTAssertEqual(tracker.observe(streamID: oversized, sequence: 1), .untracked)
        XCTAssertEqual(tracker.trackedStreamCount(), 2)
    }

    func testConnectionPoolRejectsUnboundSecurityKeyBeforeCreatingTransport() throws {
        let pool = BridgeConnectionPool()
        let sessionURL = try XCTUnwrap(URL(string: "wss://bridge.example/session"))
        let key = BridgeConnectionPoolKey(
            sessionEndpoint: sessionURL,
            identityUUID: "",
            signingKeyFingerprint: "",
            homeVaultReference: ""
        )
        var factoryCalls = 0

        XCTAssertThrowsError(try pool.channelTransport(
            for: key,
            targetEndpoint: "PrivateCell",
            physicalTransportFactory: {
                factoryCalls += 1
                return ServerRecordingTransport()
            }
        )) { error in
            XCTAssertEqual(error as? BridgeMultiplexError, .invalidSecurityContext)
        }
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(pool.sessionCount(), 0)
    }

    func testConnectionPoolEvictsLeastRecentlyUsedSessionAndClosesItAfterChannelRelease() async throws {
        let vault = EphemeralIdentityVault()
        let pool = BridgeConnectionPool(maximumSessions: 2)
        let sessionURL = try XCTUnwrap(URL(string: "wss://bridge.example/session"))
        var transports: [MultiplexPhysicalTransport] = []
        var channels: [BridgeTransportProtocol] = []

        for index in 0..<3 {
            let identityValue = await vault.identity(for: "pool-owner-\(index)", makeNewIfNotFound: true)
            let identity = try XCTUnwrap(identityValue)
            let physical = MultiplexPhysicalTransport(vault: vault)
            transports.append(physical)
            let key = BridgeConnectionPoolKey(
                sessionEndpoint: sessionURL,
                identityUUID: identity.uuid,
                signingKeyFingerprint: try XCTUnwrap(identity.signingPublicKeyFingerprint),
                homeVaultReference: try XCTUnwrap(identity.homeVaultReference)
            )
            channels.append(try pool.channelTransport(
                for: key,
                targetEndpoint: "Cell-\(index)",
                physicalTransportFactory: { physical }
            ))
        }

        XCTAssertEqual(pool.sessionCount(), 2)
        XCTAssertEqual(transports[0].snapshot().closeInvocations, 0)
        await channels[0].close()
        XCTAssertEqual(transports[0].snapshot().closeInvocations, 1)

        pool.reset()
        await channels[1].close()
        await channels[2].close()
        XCTAssertEqual(transports[1].snapshot().closeInvocations, 1)
        XCTAssertEqual(transports[2].snapshot().closeInvocations, 1)
    }

    func testClientSessionBoundsIssuedChannelsAndReleasesReservationOnClose() async throws {
        let physical = ServerRecordingTransport()
        let session = BridgeMultiplexSession(
            physicalTransport: physical,
            maximumChannels: 1,
            maximumPendingChannelOpens: 1
        )
        let first = try session.channelTransport(targetEndpoint: "FirstCell")

        XCTAssertThrowsError(try session.channelTransport(targetEndpoint: "SecondCell")) { error in
            XCTAssertEqual(error as? BridgeMultiplexError, .resourceLimitExceeded)
        }

        await first.close()
        let replacement = try session.channelTransport(targetEndpoint: "SecondCell")
        await replacement.close()
    }

    func testServerSessionAddsPerStreamSequenceWatermarksToFlowFrames() async throws {
        let vault = EphemeralIdentityVault()
        let identityValue = await vault.identity(for: "server-sequence-owner", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(identityValue)
        let physical = ServerRecordingTransport()
        let delegate = PassiveBridgeDelegate()
        var logicalTransport: BridgeTransportProtocol?
        let server = BridgeMultiplexServerSession(physicalTransport: physical) { _, _, transport in
            logicalTransport = transport
            return delegate
        }
        try await server.consumeCommand(command: BridgeCommand(
            cmd: Command.openChannel.rawValue,
            identity: identity,
            payload: nil,
            cid: 1,
            protocolVersion: 2,
            channelID: "channel-1",
            targetEndpoint: "RemoteCell"
        ))
        let channelTransport = try XCTUnwrap(logicalTransport)
        let element = FlowElement(
            id: "event",
            title: "event",
            content: .string("event"),
            properties: .init(type: .event, contentType: .string)
        )
        for _ in 0..<2 {
            try await channelTransport.sendData(JSONEncoder().encode(BridgeCommand(
                cmd: Command.response.rawValue,
                identity: identity,
                payload: .flowElement(element),
                cid: 77
            )))
        }

        let flowFrames = physical.snapshot().filter {
            if case .flowElement? = $0.payload { return true }
            return false
        }
        XCTAssertEqual(flowFrames.count, 2)
        XCTAssertEqual(flowFrames.map(\.sequence), [1, 2])
        XCTAssertEqual(Set(flowFrames.compactMap(\.streamID)).count, 1)
        XCTAssertEqual(flowFrames.first?.streamID, "channel-1:77")
    }

    func testClientSessionReportsDetectedGapButStillDeliversFollowingFrame() async throws {
        let vault = EphemeralIdentityVault()
        let identityValue = await vault.identity(for: "gap-owner", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(identityValue)
        let physical = MultiplexPhysicalTransport(vault: vault)
        let session = BridgeMultiplexSession(physicalTransport: physical)
        let transport = try XCTUnwrap(
            try session.channelTransport(targetEndpoint: "RemoteCell") as? BridgeMultiplexChannelTransport
        )
        let delegate = GapRecordingDelegate()
        transport.setDelegate(delegate)
        let sessionURL = try XCTUnwrap(URL(string: "wss://bridge.example/bridgehead/session"))
        try await transport.setup(sessionURL, identity: identity)
        let element = FlowElement(
            id: "gap-event",
            title: "gap",
            content: .string("gap"),
            properties: .init(type: .event, contentType: .string)
        )

        for sequence: UInt64 in [1, 3] {
            try await physical.injectResponse(BridgeCommand(
                cmd: Command.response.rawValue,
                identity: identity,
                payload: .flowElement(element),
                cid: 9,
                protocolVersion: 2,
                channelID: transport.channelID,
                streamID: "\(transport.channelID):9",
                sequence: sequence
            ))
        }

        let snapshot = delegate.snapshot()
        XCTAssertEqual(snapshot.responseCount, 2)
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertTrue(snapshot.messages[0].contains("expected 2, received 3"))
        XCTAssertTrue(snapshot.messages[0].contains("Replay is not guaranteed"))
    }

    func testServerSessionRejectsRemoteTargetAuthorityBeforeCallingFactory() async throws {
        let vault = EphemeralIdentityVault()
        let identityValue = await vault.identity(for: "rejected-route-owner", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(identityValue)
        let physical = ServerRecordingTransport()
        let sink = InMemoryCellSecurityEventSink()
        CellBase.securityEventSink = sink
        var factoryCalls = 0
        let server = BridgeMultiplexServerSession(physicalTransport: physical) { _, _, _ in
            factoryCalls += 1
            return PassiveBridgeDelegate()
        }

        try await server.consumeCommand(command: BridgeCommand(
            cmd: Command.openChannel.rawValue,
            identity: identity,
            payload: nil,
            cid: 3,
            protocolVersion: 2,
            channelID: "channel-rejected",
            targetEndpoint: "cell://outside.example/PrivateCell"
        ))

        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(physical.snapshot().last?.command, .channelRejected)
        let events = await sink.snapshot()
        XCTAssertFalse(events.contains { $0.reasonCode == CellSecurityReasonCode.identityPublicKeyMismatch })
    }

    func testServerSessionRejectsIdentityWithoutSigningKeyBeforeCallingFactory() async throws {
        let identity = Identity("uuid-only", displayName: "UUID only", identityVault: nil)
        let physical = ServerRecordingTransport()
        let sink = InMemoryCellSecurityEventSink()
        CellBase.securityEventSink = sink
        var factoryCalls = 0
        let server = BridgeMultiplexServerSession(physicalTransport: physical) { _, _, _ in
            factoryCalls += 1
            return PassiveBridgeDelegate()
        }

        try await server.consumeCommand(command: BridgeCommand(
            cmd: Command.openChannel.rawValue,
            identity: identity,
            payload: nil,
            cid: 4,
            protocolVersion: 2,
            channelID: "uuid-only-channel",
            targetEndpoint: "PrivateCell"
        ))

        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(physical.snapshot().last?.command, .channelRejected)
        let events = await sink.snapshot()
        XCTAssertEqual(events.last?.reasonCode, CellSecurityReasonCode.identityPublicKeyMismatch)
        XCTAssertEqual(events.last?.requiredAction, "retry_with_key_bound_identity")
    }

    func testServerSessionEnforcesChannelCapacityWithStableEvent() async throws {
        let vault = EphemeralIdentityVault()
        let identityValue = await vault.identity(for: "capacity-owner", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(identityValue)
        let physical = ServerRecordingTransport()
        let sink = InMemoryCellSecurityEventSink()
        CellBase.securityEventSink = sink
        var factoryCalls = 0
        let server = BridgeMultiplexServerSession(
            physicalTransport: physical,
            maximumChannels: 1,
            maximumPendingChannelOpens: 1
        ) { _, _, _ in
            factoryCalls += 1
            return PassiveBridgeDelegate()
        }

        for (cid, channelID) in [(1, "first-channel"), (2, "second-channel")] {
            try await server.consumeCommand(command: BridgeCommand(
                cmd: Command.openChannel.rawValue,
                identity: identity,
                payload: nil,
                cid: cid,
                protocolVersion: 2,
                channelID: channelID,
                targetEndpoint: "PrivateCell"
            ))
        }

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(physical.snapshot().last?.command, .channelRejected)
        let events = await sink.snapshot()
        XCTAssertEqual(events.last?.reasonCode, CellSecurityReasonCode.bridgeChannelCapacityExceeded)
        XCTAssertEqual(events.last?.requiredAction, "wait_before_opening_another_channel")
    }

    func testServerSessionRemovesInsertedChannelWhenOpenedFrameCannotBeSent() async throws {
        let vault = EphemeralIdentityVault()
        let identityValue = await vault.identity(for: "send-failure-owner", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(identityValue)
        let physical = FailFirstChannelOpenedTransport()
        var factoryCalls = 0
        let server = BridgeMultiplexServerSession(physicalTransport: physical) { _, _, _ in
            factoryCalls += 1
            return PassiveBridgeDelegate()
        }
        let open = BridgeCommand(
            cmd: Command.openChannel.rawValue,
            identity: identity,
            payload: nil,
            cid: 5,
            protocolVersion: 2,
            channelID: "retry-channel",
            targetEndpoint: "PrivateCell"
        )

        try await server.consumeCommand(command: open)
        try await server.consumeCommand(command: open)

        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(physical.snapshot().map(\.command), [.channelOpened, .channelRejected, .channelOpened])
    }

    func testClientSessionRejectsResponseBeforeChannelIsOpened() async throws {
        let physical = ServerRecordingTransport()
        let session = BridgeMultiplexSession(physicalTransport: physical)

        do {
            try await session.consumeResponse(command: BridgeCommand(
                cmd: Command.response.rawValue,
                payload: .string("must-not-be-delivered"),
                cid: 6,
                protocolVersion: 2,
                channelID: "unknown-channel"
            ))
            XCTFail("Expected an unopened channel to be rejected")
        } catch {
            XCTAssertEqual(error as? BridgeMultiplexError, .channelNotFound)
        }
    }

    func testTwoRemoteBridgesShareOnePhysicalSessionAndKeepResponsesOnTheirChannels() async throws {
        let vault = EphemeralIdentityVault()
        let identityValue = await vault.identity(for: "multiplex-owner", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(identityValue)
        let fingerprint = try XCTUnwrap(identity.signingPublicKeyFingerprint)
        let homeVaultReference = try XCTUnwrap(identity.homeVaultReference)
        let sessionURL = try XCTUnwrap(URL(string: "wss://bridge.example/bridgehead/session"))
        let key = BridgeConnectionPoolKey(
            sessionEndpoint: sessionURL,
            identityUUID: identity.uuid,
            signingKeyFingerprint: fingerprint,
            homeVaultReference: homeVaultReference
        )
        let physical = MultiplexPhysicalTransport(vault: vault)
        let pool = BridgeConnectionPool()
        var physicalFactoryInvocations = 0

        let firstTransport = try pool.channelTransport(
            for: key,
            targetEndpoint: "FirstCell",
            physicalTransportFactory: {
                physicalFactoryInvocations += 1
                return physical
            }
        )
        let secondTransport = try pool.channelTransport(
            for: key,
            targetEndpoint: "SecondCell",
            physicalTransportFactory: {
                physicalFactoryInvocations += 1
                return physical
            }
        )

        let firstBridge = try await BridgeBase(.init(
            owner: identity,
            transport: firstTransport,
            connection: .outbound
        ))
        let secondBridge = try await BridgeBase(.init(
            owner: identity,
            transport: secondTransport,
            connection: .outbound
        ))
        try await firstBridge.setTransport(firstTransport, connection: .outbound)
        try await secondBridge.setTransport(secondTransport, connection: .outbound)

        try await firstTransport.setup(sessionURL, identity: identity)
        try await secondTransport.setup(sessionURL, identity: identity)
        async let firstDescription: Void = firstBridge.retrieveProxyRepresentation(for: identity)
        async let secondDescription: Void = secondBridge.retrieveProxyRepresentation(for: identity)
        _ = try await (firstDescription, secondDescription)

        let snapshot = physical.snapshot()
        XCTAssertEqual(pool.sessionCount(), 1)
        XCTAssertEqual(physicalFactoryInvocations, 1)
        XCTAssertEqual(snapshot.setupInvocations, 1)
        XCTAssertEqual(snapshot.commands.filter { $0.command == .openChannel }.count, 2)
        XCTAssertEqual(Set(snapshot.commands.compactMap(\.channelID)).count, 2)
        XCTAssertEqual(firstBridge.name, "FirstCell")
        XCTAssertEqual(secondBridge.name, "SecondCell")
    }

    func testPoolDoesNotSharePhysicalSessionAcrossSecurityIdentities() async throws {
        let firstVault = EphemeralIdentityVault()
        let secondVault = EphemeralIdentityVault()
        let firstValue = await firstVault.identity(for: "first", makeNewIfNotFound: true)
        let secondValue = await secondVault.identity(for: "second", makeNewIfNotFound: true)
        let first = try XCTUnwrap(firstValue)
        let second = try XCTUnwrap(secondValue)
        let sessionURL = try XCTUnwrap(URL(string: "wss://bridge.example/bridgehead/session"))
        let pool = BridgeConnectionPool()
        var physicalFactoryInvocations = 0

        func key(for identity: Identity) throws -> BridgeConnectionPoolKey {
            BridgeConnectionPoolKey(
                sessionEndpoint: sessionURL,
                identityUUID: identity.uuid,
                signingKeyFingerprint: try XCTUnwrap(identity.signingPublicKeyFingerprint),
                homeVaultReference: try XCTUnwrap(identity.homeVaultReference)
            )
        }

        _ = try pool.channelTransport(
            for: try key(for: first),
            targetEndpoint: "Cell",
            physicalTransportFactory: {
                physicalFactoryInvocations += 1
                return MultiplexPhysicalTransport(vault: firstVault)
            }
        )
        _ = try pool.channelTransport(
            for: try key(for: second),
            targetEndpoint: "Cell",
            physicalTransportFactory: {
                physicalFactoryInvocations += 1
                return MultiplexPhysicalTransport(vault: secondVault)
            }
        )

        XCTAssertEqual(pool.sessionCount(), 2)
        XCTAssertEqual(physicalFactoryInvocations, 2)
    }

    func testResolverMultiplexRouteUsesOneSessionURLForTwoRemoteCells() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = EphemeralIdentityVault()
        CellBase.defaultCellResolver = resolver
        CellBase.defaultIdentityVault = vault
        ResolverMultiplexTransport.reset()
        try await resolver.registerTransport(ResolverMultiplexTransport.self, for: "wss")
        let host = "multiplex-\(UUID().uuidString.lowercased()).example"
        resolver.registerRemoteCellHost(
            host,
            route: RemoteCellHostRoute(
                websocketEndpoint: "bridgehead",
                schemePreference: .wss,
                connectionSharing: .multiplexedV2
            )
        )
        let identityValue = await vault.identity(for: "resolver-multiplex-owner", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(identityValue)

        let first = try await resolver.cellAtEndpoint(
            endpoint: "cell://\(host)/FirstRemoteCell",
            requester: identity
        )
        let second = try await resolver.cellAtEndpoint(
            endpoint: "cell://\(host)/SecondRemoteCell",
            requester: identity
        )

        let snapshot = ResolverMultiplexTransport.snapshot()
        XCTAssertNotEqual(first.uuid, second.uuid)
        XCTAssertEqual(snapshot.instances, 1)
        XCTAssertEqual(snapshot.setupURLs.count, 1)
        XCTAssertEqual(snapshot.setupURLs.first?.path, "/bridgehead/session")
    }
}
