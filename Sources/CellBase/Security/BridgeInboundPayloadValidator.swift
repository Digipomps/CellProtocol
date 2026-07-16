// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum BridgeInboundPayloadError: Error, Equatable, Sendable {
    case tooLarge(actualBytes: Int, maximumBytes: Int)
    case tooDeep(maximumDepth: Int)
    case malformedStructure

    public var reasonCode: String {
        switch self {
        case .tooLarge:
            return CellSecurityReasonCode.bridgePayloadTooLarge
        case .tooDeep:
            return CellSecurityReasonCode.bridgePayloadTooDeep
        case .malformedStructure:
            return CellSecurityReasonCode.bridgePayloadMalformed
        }
    }
}

/// Performs a bounded O(n) structural pass before decoding untrusted bridge JSON.
public struct BridgeInboundPayloadValidator: Sendable {
    public static let defaultMaximumBytes = 1_048_576
    public static let defaultMaximumNestingDepth = 64

    public let maximumBytes: Int
    public let maximumNestingDepth: Int

    public init(
        maximumBytes: Int = Self.defaultMaximumBytes,
        maximumNestingDepth: Int = Self.defaultMaximumNestingDepth
    ) {
        self.maximumBytes = max(1, maximumBytes)
        self.maximumNestingDepth = max(1, maximumNestingDepth)
    }

    public func validate(_ data: Data) throws {
        guard data.count <= maximumBytes else {
            throw BridgeInboundPayloadError.tooLarge(
                actualBytes: data.count,
                maximumBytes: maximumBytes
            )
        }

        var containers: [UInt8] = []
        containers.reserveCapacity(min(maximumNestingDepth, 64))
        var inString = false
        var escaped = false

        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }

            switch byte {
            case 0x22:
                inString = true
            case 0x7B, 0x5B:
                containers.append(byte)
                guard containers.count <= maximumNestingDepth else {
                    throw BridgeInboundPayloadError.tooDeep(maximumDepth: maximumNestingDepth)
                }
            case 0x7D:
                guard containers.popLast() == 0x7B else {
                    throw BridgeInboundPayloadError.malformedStructure
                }
            case 0x5D:
                guard containers.popLast() == 0x5B else {
                    throw BridgeInboundPayloadError.malformedStructure
                }
            default:
                break
            }
        }

        guard inString == false, escaped == false, containers.isEmpty else {
            throw BridgeInboundPayloadError.malformedStructure
        }
    }
}
