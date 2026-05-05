// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum InterceptKind {
    case get
    case set
}

public extension GeneralCell {
    /// Common registration helper for both GET and SET intercepts.
    public func registerIntercept(
        _ kind: InterceptKind,
        key: String,
        owner: Identity,
        handler: @escaping (_ requester: Identity, _ payload: ValueType?) async -> ValueType?
    ) async {
        switch kind {
        case .get:
            await addInterceptForGet(requester: owner, key: key) { _, requester in
                await handler(requester, nil) ?? .null
            }
        case .set:
            await addInterceptForSet(requester: owner, key: key) { _, value, requester in
                await handler(requester, value)
            }
        }
    }

    /// Convenience wrapper for GET intercept registration.
    public func registerGet(
        key: String,
        owner: Identity,
        handler: @escaping (_ requester: Identity) async -> ValueType
    ) async {
        await addInterceptForGet(requester: owner, key: key) { _, requester in
            await handler(requester)
        }
    }

    /// Convenience wrapper for SET intercept registration.
    public func registerSet(
        key: String,
        owner: Identity,
        handler: @escaping (_ requester: Identity, _ payload: ValueType) async -> ValueType?
    ) async {
        await addInterceptForSet(requester: owner, key: key) { _, value, requester in
            await handler(requester, value)
        }
    }

    /// Strict-mode friendly GET registration that declares the contract before wiring the handler.
    public func registerGet(
        key: String,
        owner: Identity,
        returns: ValueType,
        permissions: [String] = [],
        required: Bool = false,
        flowEffects: [ValueType] = [],
        description: ValueType = .string("*"),
        handler: @escaping (_ requester: Identity) async -> ValueType
    ) async {
        await registerExploreContract(
            requester: owner,
            key: key,
            method: .get,
            input: .null,
            returns: returns,
            permissions: permissions,
            required: required,
            flowEffects: flowEffects,
            description: description
        )
        await addInterceptForGet(requester: owner, key: key) { _, requester in
            await handler(requester)
        }
    }

    /// Strict-mode friendly SET registration that declares the contract before wiring the handler.
    public func registerSet(
        key: String,
        owner: Identity,
        input: ValueType,
        returns: ValueType? = nil,
        permissions: [String] = [],
        required: Bool = false,
        flowEffects: [ValueType] = [],
        description: ValueType = .string("*"),
        handler: @escaping (_ requester: Identity, _ payload: ValueType) async -> ValueType?
    ) async {
        await registerExploreContract(
            requester: owner,
            key: key,
            method: .set,
            input: input,
            returns: returns,
            permissions: permissions,
            required: required,
            flowEffects: flowEffects,
            description: description
        )
        await addInterceptForSet(requester: owner, key: key) { _, value, requester in
            await handler(requester, value)
        }
    }
}
