// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import XCTest
@testable import CellBase

final class BridgeDiagnosticPrivacyTests: XCTestCase {
    private let marker = "SYNTHETIC_PRIVATE_PAYLOAD_N19_8E2D"
    private var savedDomains = Set<CellBase.DiagnosticLogDomain>()
    private var savedHandler: ((CellBase.DiagnosticLogDomain, String) -> Void)?
    private let logs = DiagnosticLines()
    override func setUp() {
        super.setUp()
        savedDomains = CellBase.enabledDiagnosticLogDomains
        savedHandler = CellBase.diagnosticLogHandler
        CellBase.enabledDiagnosticLogDomains = [.bridge]
        CellBase.diagnosticLogHandler = { [logs] domain, text in
            if domain == .bridge { logs.append(text) }
        }
    }
    override func tearDown() {
        XCTAssertFalse(logs.lines.isEmpty, "Diagnostics must actually be enabled")
        XCTAssertFalse(logs.lines.joined(separator: "\n").contains(marker))
        XCTAssertTrue(logs.lines.allSatisfy { $0.utf8.count <= 256 }, "Bounded metadata only")
        CellBase.enabledDiagnosticLogDomains = savedDomains
        CellBase.diagnosticLogHandler = savedHandler
        super.tearDown()
    }
    private func bridge(_ wire: BridgeTransportProtocol = MockBridgeTransport()) async throws -> (BridgeBase, Identity) {
        let owner = await MockIdentityVault().identity(for: "diagnostic-owner", makeNewIfNotFound: true)!
        let bridge = BridgeBase(owner: owner)
        try await bridge.setTransport(wire, connection: .outbound)
        try await authenticateBridgeFixture(bridge, principal: owner)
        return (bridge, owner)
    }

    func testEveryPayloadMismatchAndUnknownResponseLogsMetadataWithoutDecryptedContent() async throws {
        let (bridge, _) = try await bridge()
        for (request, code) in [(Command.description, "description"), (.admit, "connect"), (.connectEmitter, "connect"),
                                (.agreement, "contract"), (.feed, "flow")] {
            let cid = await bridge.auditor.getNewCommandId()
            await bridge.auditor.storeBridgeCommand(.init(cmd: request.rawValue, payload: nil, cid: cid), for: cid)
            let count = logs.lines.count
            try await bridge.consumeResponse(command: .init(cmd: "response", payload: .string(marker), cid: cid))
            let added = logs.lines.dropFirst(count)
            XCTAssertTrue(added.contains { $0.contains("code=expected_" + code) && $0.contains("cid=\(cid)") })
        }
        try await bridge.consumeResponse(command: .init(cmd: "response", payload: .string(marker), cid: 9999,
            channelID: marker, targetEndpoint: marker, streamID: marker, peerGeneration: marker))
        XCTAssertTrue(logs.lines.contains { $0.contains("code=unknown_cid") && $0.contains("cid=9999") })
    }

    func testMalformedDescriptionBytesNeverEnterDiagnostics() async throws {
        let (bridge, _) = try await bridge()
        let bytes = Data("{\"private\":\"\(marker)\"}".utf8)
        bridge.configure(from: bytes)
        XCTAssertTrue(logs.lines.contains { $0.contains("code=invalid_description bytes=\(bytes.count)") })
    }

    func testAgreementCommandUnknownCommandAndGetErrorDoNotLogPeerText() async throws {
        let (bridge, owner) = try await bridge()
        let cell = await DiagnosticFailureCell(owner: owner)
        cell.failure = NSError(domain: marker, code: 17, userInfo: [NSLocalizedDescriptionKey: marker])
        bridge.emitCellAtEndpoint = cell
        try await bridge.consumeCommand(command: .init(cmd: "agreement", identity: owner, payload: .string(marker), cid: 71))
        XCTAssertTrue(logs.lines.contains { $0.contains("code=expected_agreement") && $0.contains("cid=71") })
        try await bridge.consumeCommand(command: .init(cmd: marker, identity: owner, payload: .string(marker), cid: 72))
        XCTAssertTrue(logs.lines.contains { $0.contains("type=none cid=72") })
        try await bridge.consumeCommand(command: .init(cmd: "get", identity: owner, payload: .string(marker), cid: 73))
        XCTAssertTrue(logs.lines.contains { $0.contains("code=get_failed cid=73") })
        await bridge.sendCommand(command: .description, identity: owner, payload: .string(marker))
        let request = await bridge.auditor.getNewCommandId()
        await bridge.auditor.storeBridgeCommand(.init(cmd: marker, payload: .string(marker), cid: request), for: request)
        try await bridge.consumeResponse(command: .init(cmd: "response", payload: .string(marker), cid: request))
        XCTAssertTrue(logs.lines.contains { $0.contains("Response did not match request type=none") })
    }

    func testTransportErrorDescriptionsNeverEnterBaseDiagnostics() async throws {
        let wire = DiagnosticFailingTransport()
        let (bridge, owner) = try await bridge(wire)
        wire.failure = NSError(domain: marker, code: 19, userInfo: [NSLocalizedDescriptionKey: marker])
        await bridge.sendCommand(command: .get, identity: owner, payload: .string(marker))
        XCTAssertTrue(logs.lines.contains { $0.contains("Sending command failed") })
        let (responseBridge, responseOwner) = try await self.bridge(wire)
        let cell = await DiagnosticFailureCell(owner: responseOwner)
        responseBridge.emitCellAtEndpoint = cell
        try await responseBridge.consumeCommand(command: .init(cmd: "description", identity: responseOwner, payload: .string(marker), cid: 80))
        XCTAssertTrue(logs.lines.contains { $0.contains("Consume command description failed") })
    }
}

private final class DiagnosticLines: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []
    var lines: [String] { lock.withLock { value } }
    func append(_ text: String) { lock.withLock { value.append(text) } }
}
private final class DiagnosticFailureCell: GeneralCell {
    var failure: Error = BridgeChannelAuthentication.Failure.unavailable
    override func get(keypath: String, requester: Identity) async throws -> ValueType { throw failure }
}
private final class DiagnosticFailingTransport: BridgeTransportProtocol {
    var failure: Error?
    static func new() -> BridgeTransportProtocol { DiagnosticFailingTransport() }
    func setDelegate(_ delegate: BridgeDelegateProtocol) {}
    func setup(_ endpointURL: URL, identity: Identity) async throws {}
    func sendData(_ data: Data) async throws { if let failure { throw failure } }
    func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
}
