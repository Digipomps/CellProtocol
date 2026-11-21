import Foundation
import CellBase

/// An invitation-bound logical bridge on the private scanner channel. It does
/// not replace the lobby delegate or confer Cell authority. All inner commands
/// still pass the ordinary BridgeBase requester/proof/Cell admission path.
final class ScannerMeetingRelay: BridgeTransportProtocol, @unchecked Sendable {
    static let topic = "scanner.meeting.bridge.v1"
    struct Frame: Codable { let channelID: UUID; let cellID: String; let bytes: Data }
    let context: ScannerConsumerContext
    let cellID: String
    let channelID: UUID
    private weak var service: ScannerService?
    private let lock = NSLock()
    private weak var delegate: BridgeDelegateProtocol?
    private var closed = false
    var bridge: BridgeBase?
    var channelSession: BridgeChannelSession? { context.session }
    init(service: ScannerService, context: ScannerConsumerContext, cellID: String, channelID: UUID) {
        self.service = service; self.context = context; self.cellID = cellID; self.channelID = channelID
    }
    static func new() -> any BridgeTransportProtocol { fatalError("Meeting relay requires a verified invitation and live scanner context") }
    func setDelegate(_ delegate: any BridgeDelegateProtocol) { lock.withLock { self.delegate = delegate } }
    func setup(_ endpointURL: URL, identity: Identity) async throws {
        guard endpointURL.absoluteString == "cell:///" + cellID,
              identity.referencesSameSigningIdentity(as: context.localIdentity.makeIdentity()) else { throw MeetingSessionError.forbidden }
        try context.check()
    }
    func identityVault(for identity: Identity?) async -> any IdentityVaultProtocol { BridgeIdentityVault(cloudBridge: bridge) }
    func close() async {
        let old = lock.withLock { () -> BridgeBase? in
            closed = true; delegate = nil; let old = bridge; bridge = nil; return old
        }
        context.physical.removeMeetingRelay(self)
        old?.close(requester: context.localIdentity.makeIdentity())
    }
    func sendData(_ bytes: Data) async throws {
      do {
        try context.check()
        guard !lock.withLock({ closed }), bytes.count <= 512 * 1024, let service else { throw MeetingSessionError.unavailable }
        let frame = Frame(channelID: channelID, cellID: cellID, bytes: bytes)
        let value = try JSONDecoder().decode(FlowElementValueType.self, from: JSONEncoder().encode(frame))
        var event = FlowElement(title: "Private meeting channel", content: value, properties: .init(type: .event, contentType: .object))
        event.topic = Self.topic
        try await service.sendScannerFlowElement(event, context: context)
      } catch {
        // Detach this BridgeBase before returning the send error. Otherwise its
        // generic channelDidClose path would close the shared physical session.
        await close()
        throw error
      }
    }
    static func frame(_ outer: BridgeCommand) throws -> Frame? {
        guard outer.cid < 0, outer.command == .response, case let .flowElement(event) = outer.payload,
              event.topic == topic else { return nil }
        let data = try JSONEncoder().encode(event.content)
        guard data.count <= 768 * 1024 else { throw MeetingSessionError.invalidPlan }
        let frame = try JSONDecoder().decode(Frame.self, from: data)
        guard frame.bytes.count <= 512 * 1024 else { throw MeetingSessionError.invalidPlan }
        return frame
    }
    func isControl(_ frame: Frame) -> Bool {
        guard frame.channelID == channelID, frame.cellID == cellID, context.isLive,
              !lock.withLock({ closed }), let bridge,
              let command = try? JSONDecoder().decode(BridgeCommand.self, from: frame.bytes) else { return false }
        return command.command == .sign || bridge.isOriginSigningResponse(command)
    }
    func receive(_ frame: Frame, on incoming: ScannerConsumerContext) async throws {
        try context.check()
        guard context.matches(incoming), frame.cellID == cellID, frame.channelID == channelID,
              let delegate = lock.withLock({ closed ? nil : delegate }) else { throw CancellationError() }
        try delegate.validateInboundPayload(frame.bytes)
        let command = try JSONDecoder().decode(BridgeCommand.self, from: frame.bytes)
        guard !command.cmd.hasPrefix("channel"), command.channelID == nil, command.peerGeneration == nil, command.cid >= 0 else { throw MeetingSessionError.forbidden }
        if command.command == .response { try await delegate.consumeResponse(command: command) }
        else { try await delegate.consumeCommand(command: command) }
        try context.check()
    }
}
