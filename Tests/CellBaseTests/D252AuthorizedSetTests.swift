import XCTest
@testable import CellBase

final class D252AuthorizedSetTests: XCTestCase {
    // Loopback D252E/D256 wire format is opt-in on main; these tests exercise it.
    private var previousObjectWireFormat = CellBase.ObjectWireFormat.legacyInference
    override func setUp() {
        super.setUp()
        previousObjectWireFormat = CellBase.objectWireFormat
        CellBase.objectWireFormat = .explicitEntries
    }
    override func tearDown() {
        CellBase.objectWireFormat = previousObjectWireFormat
        super.tearDown()
    }

    private final class PeerTransport: BridgeTransportProtocol {
        weak var delegate: BridgeDelegateProtocol?
        let peerVault: IdentityVaultProtocol?
        private let lock = NSLock()
        private var commands: [BridgeCommand] = []

        init(peerVault: IdentityVaultProtocol? = nil) { self.peerVault = peerVault }
        static func new() -> BridgeTransportProtocol { PeerTransport() }
        func setDelegate(_ delegate: BridgeDelegateProtocol) { self.delegate = delegate }
        func setup(_ endpointURL: URL, identity: Identity) async throws {}
        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
            // Deliberately reproduce transport hydration with the server's vault.
            CellBase.defaultIdentityVault!
        }
        func snapshot() -> [BridgeCommand] { lock.withLock { commands } }

        func sendData(_ data: Data) async throws {
            let command = try JSONDecoder().decode(BridgeCommand.self, from: data)
            lock.withLock { commands.append(command) }
            guard command.command == .sign,
                  let identity = command.identity,
                  case let .signData(challenge) = command.payload else { return }
            let payload: ValueType
            if let peerVault,
               let signature = try? await peerVault.signMessageForIdentity(messageData: challenge, identity: identity) {
                payload = .signature(signature)
            } else {
                payload = .string("peer does not control this key")
            }
            try await delegate?.consumeResponse(command: BridgeCommand(
                cmd: Command.response.rawValue, payload: payload, cid: command.cid
            ))
        }
    }


    private final class StoredValue: @unchecked Sendable {
        let lock = NSLock()
        var value: ValueType = .string("initial")
        var writes = 0
        func set(_ newValue: ValueType) -> ValueType { lock.withLock { writes += 1; value = newValue; return value } }
        func get() -> ValueType { lock.withLock { value } }
        func count() -> Int { lock.withLock { writes } }
    }
    func testAuthorizedSetRejectsMalformedTypeWithoutCellEffectAndNormalSetGetWorks() async throws {
        let oldVault = CellBase.defaultIdentityVault, oldResolver = CellBase.defaultCellResolver
        let oldDebug = CellBase.debugValidateAccessForEverything
        defer {
            CellBase.defaultIdentityVault = oldVault; CellBase.defaultCellResolver = oldResolver
            CellBase.debugValidateAccessForEverything = oldDebug
        }
        CellBase.debugValidateAccessForEverything = false
        let vault = EphemeralIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "set-owner", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner), stored = StoredValue()
        await cell.addInterceptForSet(requester: owner, key: "writable") { _, value, _ in stored.set(value) }
        await cell.addInterceptForGet(requester: owner, key: "writable") { _, _ in stored.get() }
        let resolver = MockCellResolver()
        CellBase.defaultCellResolver = resolver
        try await resolver.registerNamedEmitCell(name: "D252SetTarget", emitCell: cell, scope: .template, identity: owner)
        let transport = PeerTransport(peerVault: vault)
        let server = try await BridgeBase(BridgeBase.Config(owner: owner, transport: transport,
            connection: .inbound(publisherUuid: "D252SetTarget"), inboundPublisherLookupIdentity: owner))
        try await server.setTransport(transport, connection: .inbound(publisherUuid: "D252SetTarget"))
        transport.setDelegate(server)
        // Main #53: readiness comes from a verified channel, never from a ready frame.
        try await authenticateBridgeFixture(server, principal: owner, signer: vault)
        let encoder = JSONEncoder()
        let normal = BridgeCommand(cmd: "set", identity: owner,
            payload: .keyValue(.init(key: "writable", value: .string("FIXTURE-PAYLOAD"))), cid: 801)
        let good = try encoder.encode(normal)
        try await server.consumeCommand(command: JSONDecoder().decode(BridgeCommand.self, from: good))
        XCTAssertEqual(stored.count(), 1, "D252-B actual authorized Cell write")
        XCTAssertEqual(stored.get(), .string("FIXTURE-PAYLOAD"))
        for (field, bad) in ["string": 123, "number": false, "float": "FIXTURE-PAYLOAD", "integer": 1.5, "object": false, "list": false] as [String: Any] {
            var frame = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
            var payload = try XCTUnwrap(frame["&keyValue"] as? [String: Any]); payload[field] = bad
            frame["&keyValue"] = payload
            let bytes = try JSONSerialization.data(withJSONObject: frame)
            var rejected = false
            do {
                let decoded = try JSONDecoder().decode(BridgeCommand.self, from: bytes)
                try await server.consumeCommand(command: decoded)
            } catch { rejected = true }
            XCTAssertTrue(rejected, "D252-B authorized malformed \(field) must fail decoding")
            XCTAssertEqual(stored.count(), 1, "D252-B rejected \(field) has zero additional Cell effect")
        }
        let get = BridgeCommand(cmd: "get", identity: owner, payload: .string("writable"), cid: 802)
        try await server.consumeCommand(command: JSONDecoder().decode(BridgeCommand.self, from: encoder.encode(get)))
        let response = try XCTUnwrap(transport.snapshot().last { $0.command == .response && $0.cid == 802 })
        XCTAssertEqual(response.payload, .string("FIXTURE-PAYLOAD"), "D252-B normal get reads actual set value")
        XCTAssertGreaterThan(transport.snapshot().filter { $0.command == .sign }.count, 0, "D252-B real requester proof")
        await server.finishRetirement()
    }
}
