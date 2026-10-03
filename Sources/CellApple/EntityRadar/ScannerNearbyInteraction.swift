// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import MultipeerConnectivity
import CellBase
#if os(iOS)
import NearbyInteraction
#endif

struct ScannerNIMeasurement {
    let distance: Float?, x: Float?, y: Float?, z: Float?
}
enum ScannerNIEvent {
    case measurement(ScannerNIMeasurement)
    case suspended, resumed, timeout, ended, invalidated
}

/// Every method, property and callback is confined to the supplied serial queue.
/// The adapter filters objects by the exact platform session and discovery token.
protocol ScannerNISession: AnyObject {
    var localToken: Data { get }
    var event: ((ScannerNIEvent) -> Void)? { get set }
    func run(token: Data) throws
    func invalidate()
}

/// NI association only. Admission, authentication, revocation and send quotas
/// remain owned by the existing bridge gate/session, never by a second gate.
final class ScannerNearbyInteraction {
    final class Entry {
        let context: ScannerConsumerContext
        let generation = UUID()
        var driver: ScannerNISession?
        var remoteGeneration: UUID?
        var remoteToken: Data?
        var suspended = false
        init(context: ScannerConsumerContext, driver: ScannerNISession) {
            self.context = context; self.driver = driver
        }
    }
    struct Outgoing { let token: Data; let generation: UUID }
    private let queue: DispatchQueue
    private var entries: [ObjectIdentifier: Entry] = [:]
    var factory: (DispatchQueue) throws -> ScannerNISession? = { queue in
#if os(iOS)
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else { return nil }
        return try AppleScannerNISession(queue: queue)
#else
        return nil
#endif
    }
    init(queue: DispatchQueue) { self.queue = queue }
    private func assertExecutor() { dispatchPrecondition(condition: .onQueue(queue)) }

    static func tokenFlow(_ token: Data, generation: UUID, context: ScannerConsumerContext) -> FlowElement {
        let content: Object = ["niVersion": .integer(1), "token": .data(token),
            "userUuid": .string(context.localIdentity.uuid), "targetSession": .string(context.remoteUUID),
            "setupID": .string(context.setupID), "niGeneration": .string(generation.uuidString)]
        return FlowElement(title: "DiscoveryToken", content: .object(content), properties: .init(type: .event, contentType: .object))
    }
    private func decode(_ object: Object, context: ScannerConsumerContext) throws -> (UUID, Data) {
        try context.check()
        guard Set(object.keys) == Set(["niVersion", "token", "userUuid", "targetSession", "setupID", "niGeneration"]),
              object["niVersion"] == .integer(1), object["userUuid"] == .string(context.identity.uuid),
              object["targetSession"] == .string(context.localUUID),
              object["setupID"] == .string(context.setupID),
              case let .string(generationString)? = object["niGeneration"],
              let generation = UUID(uuidString: generationString), generation.uuidString == generationString else {
            throw BridgeChannelAuthentication.Failure.identityMismatch
        }
        let token: Data?
        switch object["token"] {
        case .data(let bytes): token = bytes
        case .string(let base64) where base64.utf8.count <= 24 * 1024: token = Data(base64Encoded: base64)
        default: token = nil
        }
        guard let token, !token.isEmpty, token.count <= 16 * 1024 else { throw BridgeChannelAuthentication.Failure.malformed }
        return (generation, token)
    }
    func validate(_ object: Object, context: ScannerConsumerContext) throws {
        assertExecutor(); _ = try decode(object, context: context)
    }
    func start(context: ScannerConsumerContext, report: @escaping (Entry, ScannerNIMeasurement) -> Void) throws -> Outgoing? {
        assertExecutor()
        try context.check()
        let key = ObjectIdentifier(context.physical)
        // A terminal NI entry is a tombstone until channel retirement. No token
        // replacement/restart within this channel, even after platform failure.
        if let entry = entries[key] {
            guard entry.context.matches(context) else { throw CancellationError() }
            return nil
        }
        guard let driver = try factory(queue) else { return nil }
        guard !driver.localToken.isEmpty, driver.localToken.count <= 16 * 1024 else {
            driver.invalidate(); throw BridgeChannelAuthentication.Failure.malformed
        }
        let entry = Entry(context: context, driver: driver)
        do {
            try context.perform { entries[key] = entry }
        } catch { driver.invalidate(); throw error }
        driver.event = { [weak self, weak entry, weak driver] event in
            guard let self, let entry, let driver else { return }
            self.assertExecutor()
            guard self.isCurrent(entry), entry.driver === driver else { return }
            switch event {
            case .measurement(let measurement):
                guard entry.remoteToken != nil, !entry.suspended else { return }
                report(entry, measurement)
            case .suspended: entry.suspended = true
            case .resumed, .timeout:
                do {
                    try entry.context.perform {
                        if let token = entry.remoteToken { try driver.run(token: token) }
                        entry.suspended = false
                    }
                } catch { self.invalidate(entry) }
            case .ended, .invalidated: self.invalidate(entry)
            }
        }
        return Outgoing(token: driver.localToken, generation: entry.generation)
    }
    func receive(_ object: Object, context: ScannerConsumerContext) throws {
        assertExecutor()
        let (generation, token) = try decode(object, context: context)
        guard let entry = entries[ObjectIdentifier(context.physical)], entry.context.matches(context),
              isCurrent(entry), let driver = entry.driver else { return } // unsupported or terminal NI
        if let existing = entry.remoteToken {
            guard entry.remoteGeneration == generation, existing == token else {
                throw BridgeChannelAuthentication.Failure.unexpectedMessage
            }
            return // exact duplicate is idempotent; never re-run from incoming data
        }
        do {
            try context.perform {
                try driver.run(token: token)
                entry.remoteToken = token; entry.remoteGeneration = generation
            }
        } catch { invalidate(entry); throw error }
    }
    func isCurrent(_ entry: Entry) -> Bool {
        assertExecutor()
        guard entries[ObjectIdentifier(entry.context.physical)] === entry, entry.driver != nil else { return false }
        guard entry.context.isLive else { invalidate(entry); return false }
        return true
    }
    private func invalidate(_ entry: Entry) {
        let driver = entry.driver
        entry.driver = nil; entry.remoteToken = nil; entry.remoteGeneration = nil
        driver?.event = nil; driver?.invalidate()
    }
    func retire(physical: ScannerPeerTransport) {
        assertExecutor()
        if let entry = entries.removeValue(forKey: ObjectIdentifier(physical)) { invalidate(entry) }
    }
    func retire(session: MCSession) {
        assertExecutor()
        for entry in Array(entries.values) where entry.context.physical.mcSession === session { retire(physical: entry.context.physical) }
    }
    func stop() {
        assertExecutor()
        for entry in entries.values { invalidate(entry) }
        entries.removeAll()
    }
}

#if os(iOS)
/// No Scanner UUID lookup occurs here: only this exact NISession and its one
/// installed token can produce an event for the captured entry above.
final class AppleScannerNISession: NSObject, ScannerNISession, NISessionDelegate {
    private let session: NISession
    private let queue: DispatchQueue
    private var peerToken: NIDiscoveryToken?
    private var invalidated = false
    let localToken: Data
    var event: ((ScannerNIEvent) -> Void)?

    init(queue: DispatchQueue) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        self.queue = queue
        let session = NISession()
        self.session = session
        guard let token = session.discoveryToken else { session.invalidate(); throw BridgeChannelAuthentication.Failure.unavailable }
        do { localToken = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) }
        catch { session.invalidate(); throw error }
        super.init()
        session.delegateQueue = queue; session.delegate = self
    }
    static func decodeToken(_ data: Data) throws -> NIDiscoveryToken {
        guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else {
            throw BridgeChannelAuthentication.Failure.malformed
        }
        return token
    }
    func run(token: Data) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !invalidated else { throw CancellationError() }
        let decoded = try Self.decodeToken(token)
        if let peerToken, peerToken != decoded { throw BridgeChannelAuthentication.Failure.identityMismatch }
        peerToken = decoded
        session.run(NINearbyPeerConfiguration(peerToken: decoded))
    }
    func invalidate() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !invalidated else { return }
        invalidated = true; peerToken = nil; event = nil
        session.delegate = nil; session.invalidate()
    }
    private func current(_ candidate: NISession) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return candidate === session && !invalidated
    }
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard current(session), let token = peerToken,
              let object = nearbyObjects.first(where: { $0.discoveryToken == token }) else { return }
        event?(.measurement(.init(distance: object.distance, x: object.direction?.x, y: object.direction?.y, z: object.direction?.z)))
    }
    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard current(session), let token = peerToken, nearbyObjects.contains(where: { $0.discoveryToken == token }) else { return }
        event?(reason == .timeout ? .timeout : .ended)
    }
    func sessionWasSuspended(_ session: NISession) { if current(session) { event?(.suspended) } }
    func sessionSuspensionEnded(_ session: NISession) { if current(session) { event?(.resumed) } }
    func session(_ session: NISession, didInvalidateWith error: Error) { if current(session) { event?(.invalidated) } }
}
#endif
