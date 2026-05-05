// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public struct LookupCondition: Codable, Condition {
    public var uuid: String
    public var name: String
    public var keypath: String
    var expectedValue: ValueType
    
    public init(keypath: String, expectedValue: ValueType = .bool(true)) {
        self.name = "Lookup condition"
        self.keypath = keypath
        self.expectedValue = expectedValue
        self.uuid = UUID().uuidString
    }
    
    public func isMet(context: ConnectContext) async -> ConditionState {
        if CellBase.debugValidateAccessForEverything { return .met }
        guard let identity = context.identity else {
            return .unresolved
        }

        let resolvedKeypath = await resolvedRuntimeKeypath(for: context)
        let keypathArray = resolvedKeypath.split(separator: ".")
        guard let contextKeyComponent = keypathArray.first,
              keypathArray.count > 1 else {
            CellBase.diagnosticLog("LookupCondition missing child keypath for \(resolvedKeypath)", domain: .agreement)
            return .unresolved
        }

        let contextKey = String(contextKeyComponent)
        do {
            let value = try await lookupValue(
                contextKey: contextKey,
                keypathComponents: keypathArray,
                resolvedKeypath: resolvedKeypath,
                identity: identity,
                context: context
            )
            return value == expectedValue ? .met : .unmet
        } catch {
            CellBase.diagnosticLog("LookupCondition failed for \(resolvedKeypath): \(error)", domain: .agreement)
            return .unresolved
        }
    }
    public func resolve(context: ConnectContext) async {
        
    }

    private func resolvedRuntimeKeypath(for context: ConnectContext) async -> String {
        var resolvedKeyPath = keypath
        if resolvedKeyPath.contains("$identity") {
            resolvedKeyPath = resolvedKeyPath.replacingOccurrences(
                of: "$identity",
                with: context.identity?.uuid ?? "missing identity error"
            )
        }
        if resolvedKeyPath.contains("$target") {
            let replacement = (try? await context.target)?.uuid ?? "missing target error"
            resolvedKeyPath = resolvedKeyPath.replacingOccurrences(of: "$target", with: replacement)
        }
        if resolvedKeyPath.contains("$source") {
            let replacement: String
            if let source = try? await context.source,
               let sourceEmit = source as? Emit {
                replacement = sourceEmit.uuid
            } else {
                replacement = "missing source error"
            }
            resolvedKeyPath = resolvedKeyPath.replacingOccurrences(of: "$source", with: replacement)
        }
        return resolvedKeyPath
    }

    private func lookupValue(
        contextKey: String,
        keypathComponents: [Substring],
        resolvedKeypath: String,
        identity: Identity,
        context: ConnectContext
    ) async throws -> ValueType {
        switch contextKey {
        case "identity":
            let childKeypath = keypathComponents.dropFirst().joined(separator: ".")
            CellBase.diagnosticLog("LookupCondition checking identity", domain: .agreement)
            return try await identity.get(keypath: childKeypath, requester: identity)
        case "source":
            let childKeypath = keypathComponents.dropFirst().joined(separator: ".")
            CellBase.diagnosticLog("LookupCondition checking source", domain: .agreement)
            guard let source = try await context.source as? Meddle else {
                throw ConnectContextError.noSource
            }
            return try await source.get(keypath: childKeypath, requester: identity)
        case "target":
            let childKeypath = keypathComponents.dropFirst().joined(separator: ".")
            CellBase.diagnosticLog("LookupCondition checking target", domain: .agreement)
            guard let target = try await context.target as? Meddle else {
                throw ConnectContextError.noTarget
            }
            return try await target.get(keypath: childKeypath, requester: identity)
        case "resolve":
            guard keypathComponents.count > 2 else {
                throw DataError.unknownCase
            }
            guard let resolver = CellBase.defaultCellResolver else {
                throw CellBaseError.noResolver
            }
            let cellKey = String(keypathComponents[1])
            let cellChildKeypath = keypathComponents.dropFirst(2).joined(separator: ".")
            let cell = try await resolver.cellAtEndpoint(endpoint: "cell:///\(cellKey)", requester: identity)
            CellBase.diagnosticLog("LookupCondition resolved cell \(cellKey)", domain: .agreement)
            guard let lookupable = cell as? Meddle else {
                throw DataError.unknownCase
            }
            return try await lookupable.get(keypath: cellChildKeypath, requester: identity)
        default:
            CellBase.diagnosticLog("LookupCondition unknown context key for \(resolvedKeypath)", domain: .agreement)
            throw DataError.unknownCase
        }
    }
}
