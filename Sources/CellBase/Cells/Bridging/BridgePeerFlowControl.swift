// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import Crypto

/// Gate-owned, under its lock. Tokens are fresh local randomness, not derived
/// from Kapp (the receiver knows Kapp). No payload or ciphertext is retained.
final class BridgePeerFlowControl {
    enum WindowFull: Error { case blocked }
    typealias Failure = BridgeChannelAuthentication.Failure
    struct Receipt { let counter: UInt64; let token: Data }
    struct Outstanding { let token: Data; let bytes: Int; let control: Bool; let since: TimeInterval }
    static let maximumDataRecords = 32
    static let maximumControlRecords = 64
    static let maximumDataBytes = 2 * 1024 * 1024
    static let maximumReceipts = 64
    static let maximumOverhead = 34 + 40 * maximumReceipts
    private(set) var outstanding: [UInt64: Outstanding] = [:]
    private var receipts: [Receipt] = []
    private var needsReceipt = false
    private var dataProgress: TimeInterval?
    var bytes: Int { outstanding.values.reduce(0) { $0 + $1.bytes } }
    var shouldSendReceipt: Bool { needsReceipt }
    var oldest: TimeInterval? { outstanding.values.contains { !$0.control } ? dataProgress : nil }

    func prepare(_ payload: Data?, counter: UInt64, now: TimeInterval,
                 reserve: (Int) throws -> Void) throws -> Data {
        let control = payload == nil
        guard !control || needsReceipt else { throw Failure.unexpectedMessage }
        let selected = outstanding.values.filter { $0.control == control }
        guard selected.count < (control ? Self.maximumControlRecords : Self.maximumDataRecords) else { if control { throw Failure.capacity }; throw WindowFull.blocked }
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var body = Data([control ? 2 : 1, UInt8(receipts.count)])
        for receipt in receipts {
            var value = receipt.counter.bigEndian
            body += withUnsafeBytes(of: &value) { Data($0) }; body += receipt.token
        }
        if let payload { body += payload }
        // Entropy is at the tail: knowing a payload and an early ciphertext
        // prefix must not reveal the full-wire receipt before the tail arrives.
        body += token
        let wireBytes = body.count + BridgePeerRecordLayer.overhead
        guard body.count <= BridgePeerRecordLayer.maximumPlaintext else { throw Failure.capacity }
        guard control || wireBytes <= Self.maximumDataBytes - selected.reduce(0, { $0 + $1.bytes }) else { throw WindowFull.blocked }
        try reserve(wireBytes)
        if !control && selected.isEmpty { dataProgress = now }
        outstanding[counter] = Outstanding(token: Data(SHA256.hash(data: body)), bytes: wireBytes, control: control, since: now)
        receipts.removeAll(keepingCapacity: true); needsReceipt = false
        return body
    }

    func sealed(counter: UInt64, wire: Data) {
        guard let entry = outstanding[counter] else { return }
        outstanding[counter] = Outstanding(token: Data(SHA256.hash(data: wire)), bytes: entry.bytes,
                                           control: entry.control, since: entry.since)
    }

    /// Called only AFTER AEAD, direction, exact counter and generation checks.
    /// Receipt bytes themselves remain charged until piggybacked confirmation
    /// arrives on later traffic; receiving a receipt never emits another receipt.
    func receive(_ body: Data, counter: UInt64, wire: Data? = nil, now: TimeInterval = 0, release: (Int) -> Void) throws -> Data {
        guard body.count >= 34, body[0] == 1 || body[0] == 2 else { throw Failure.malformed }
        let count = Int(body[1]), end = 2 + count * 40
        guard count <= Self.maximumReceipts, body.count >= end + 32,
              (body[0] == 2 ? body.count == end + 32 && count > 0 : body.count > end + 32),
              receipts.count < Self.maximumReceipts else { throw Failure.malformed }
        // Validate the WHOLE receipt set before releasing any quota.
        var matched = Set<UInt64>()
        for i in 0..<count {
            let offset = 2 + i * 40
            let number = body[offset..<offset+8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard matched.insert(number).inserted, let sent = outstanding[number],
                  sent.token == body.subdata(in: offset+8..<offset+40) else { throw Failure.invalidProof }
        }
        for number in matched {
            if let sent = outstanding.removeValue(forKey: number) {
                if !sent.control { dataProgress = now }
                release(sent.bytes)
            }
        }
        receipts.append(Receipt(counter: counter, token: Data(SHA256.hash(data: wire ?? body))))
        if body[0] == 1 { needsReceipt = true }
        return body.subdata(in: end..<body.count - 32)
    }

    func retire(release: (Int) -> Void) {
        release(bytes); outstanding.removeAll(); receipts.removeAll(); needsReceipt = false; dataProgress = nil
    }
}
