import Foundation

/// Private local reader for packages already committed on this device.
/// The same configuration is renderable in Binding and a local web host.
public final class MeetingInboxCell: GeneralCell, @unchecked Sendable {
    private let sourceLock = NSLock()
    private var sources: [String: (MeetingDeliveryService, Identity)] = [:]
    public required init(owner: Identity) async { await super.init(owner: owner) }
    public required init(from decoder: Decoder) throws { try super.init(from: decoder) }
    public override func installCellRuntimeBindingsForAccess() async throws {
        for key in ["state", "cellConfiguration"] {
            await registerExploreContract(requester: owner, key: key, method: .get, input: .null,
                returns: ExploreContract.schema(type: "object"), permissions: ["r---"], required: false,
                description: .string("Owner-only locally committed encrypted transcript packages; reading does not acknowledge a remote delivery."))
        }
        await registerExploreContract(requester: owner, key: "delete", method: .set,
            input: ExploreContract.schema(type: "object"), returns: ExploreContract.schema(type: "object"), permissions: ["-w--"], required: false,
            description: .string("Owner-only: removes one received transcript package from this device. Other participants keep theirs."))
    }
    public override func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? {
        guard keypath == "delete" else { return try await super.set(keypath: keypath, value: value, requester: requester) }
        guard requester.referencesSameSigningIdentity(as: owner), await checkIdentityOrigin(requester, against: owner) else { throw MeetingSessionError.forbidden }
        guard case let .object(object) = value, case let .string(packetID)? = object["packetID"], !packetID.isEmpty, packetID.utf8.count <= 256 else {
            return .object(["status": .string("invalid")])
        }
        for (inbox, _) in sourceLock.withLock({ Array(sources.values) }) {
            if try await inbox.removeReceived(packetID: packetID) { return .object(["status": .string("deleted")]) }
        }
        return .object(["status": .string("not_found")])
    }
    public func add(cellID: String, inbox: MeetingDeliveryService, sender: Identity) {
        sourceLock.withLock { sources[cellID] = (inbox, sender.publicIdentitySnapshot()) }
    }
    public override func get(keypath: String, requester: Identity) async throws -> ValueType {
        guard requester.referencesSameSigningIdentity(as: owner), await checkIdentityOrigin(requester, against: owner) else { throw MeetingSessionError.forbidden }
        if keypath == "cellConfiguration" { return MeetingSurfaceConfiguration.encode(try configuration()) }
        guard keypath == "state" else { return try await super.get(keypath: keypath, requester: requester) }
        var rows: [ValueType] = []
        var remainingBytes = 4 * 1024 * 1024
        sourcesLoop: for (inbox, sender) in sourceLock.withLock({ sources.sorted(by: { $0.key < $1.key }).map(\.value) }) {
            try await inbox.purgeExpired()
            for packet in try await inbox.receivedPackets().prefix(64) {
                let package = try await inbox.readReceived(packetID: packet.id, sender: sender)
                guard rows.count < 64, package.transcript.utf8.count <= remainingBytes else { break sourcesLoop }
                remainingBytes -= package.transcript.utf8.count
                let ref = package.segment.reference
                rows.append(.object([
                    "title": .string(package.segment.plan.purpose + " · v" + String(package.version)),
                    "transcript": .string(package.transcript.isEmpty ? "Ingen tale kunne transkriberes." : package.transcript),
                    "notice": .string(package.incomplete ? "Delvis transkript · ikke godkjent referat" : "Automatisk transkript · ikke godkjent referat"),
                    "trust": .string("Tillitspakke · plan \(ref.revision) · \(package.consents.count) signerte ja\nSHA-256: \(packet.packageHash)\n\(package.segment.plan.processingRoute) · \(package.segment.plan.locale)\n" + package.uncertainties.joined(separator: "\n")),
                    "retention": .string("Lagret på denne enheten. Slettes senest " + ISO8601DateFormatter().string(from: packet.recipientExpiresAt)),
                    "deletePayload": .object(["packetID": .string(packet.id)])
                ]))
            }
        }
        return .object(["notice": .string(rows.isEmpty ? "Ingen transkripter er mottatt ennå." : "Transkript og tillitspakke er lagret lokalt."), "packages": .list(rows)])
    }
    public func configuration() throws -> CellConfiguration {
        var configuration = CellConfiguration(name: "Mine transkripter", cellReferences: [CellReference(endpoint: "cell:///" + uuid, subscribeFeed: false, label: "inbox")])
        configuration.skeleton = try JSONDecoder().decode(SkeletonElement.self, from: Data(Self.skeleton.utf8))
        return configuration
    }
    private static let skeleton = #"""
    {"VStack":{"spacing":14,"modifiers":{"padding":24,"background":"#F5F2E9","hAlignment":"leading","maxWidthInfinity":true},"elements":[
      {"Text":{"text":"Mine transkripter","modifiers":{"fontSize":28,"fontWeight":"bold","foregroundColor":"#292D29"}}},
      {"Text":{"keypath":"inbox.state.notice","modifiers":{"fontSize":16,"foregroundColor":"#626B60"}}},
      {"List":{"keypath":"inbox.state.packages","elements":[],"modifiers":{"rowDecoration":"none","maxWidthInfinity":true},"flowElementSkeleton":{"VStack":{"spacing":14,"modifiers":{"padding":18,"background":"#FFFFFF","cornerRadius":12,"hAlignment":"leading","maxWidthInfinity":true},"elements":[
        {"Text":{"keypath":"title","modifiers":{"fontSize":20,"fontWeight":"semibold","foregroundColor":"#292D29"}}},
        {"Text":{"keypath":"notice","modifiers":{"fontSize":14,"foregroundColor":"#98382F"}}},
        {"Text":{"keypath":"transcript","modifiers":{"fontSize":16,"foregroundColor":"#292D29"}}},
        {"Text":{"keypath":"trust","modifiers":{"fontSize":14,"foregroundColor":"#626B60"}}},
        {"Text":{"keypath":"retention","modifiers":{"fontSize":14,"foregroundColor":"#626B60"}}},
        {"Button":{"keypath":"inbox.delete","label":"Slett fra denne enheten","payloadKeypath":"deletePayload","modifiers":{"foregroundColor":"#98382F"}}}
      ]}}}}
    ]}}
    """#
}
