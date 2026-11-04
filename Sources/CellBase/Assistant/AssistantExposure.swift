// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Additive Explore-contract metadata that says how, if at all, an assistant
/// (Siri AI through App Intents, a Foundation Models session, Claude or Codex)
/// may reach one key of a cell.
///
/// The field is opt-in per key and absent by default, so contracts that do not
/// mention it encode exactly as before. It never grants anything by itself: a
/// requester still needs a signed Contract covering the key
/// (`AssistantRequesterContract`), and the gateway refuses keys that are not
/// exposed (`AssistantGateway`). See `Docs/Assistant_Exposure_Contract.md`.
public struct AssistantExposure: Codable, Equatable, Sendable {
    /// Mirrors the three levels Siri can enforce before it shows a value.
    public enum Authentication: String, Codable, Equatable, Sendable, CaseIterable {
        case alwaysAllowed
        case requiresAuthentication
        case requiresLocalDeviceAuthentication
    }

    public enum Field {
        public static let exposeAsTool = "exposeAsTool"
        public static let exposeAsEntity = "exposeAsEntity"
        public static let entityTitleKey = "entityTitleKey"
        public static let entityIDKey = "entityIDKey"
        public static let entityItemsKey = "entityItemsKey"
        public static let authentication = "authentication"
        public static let indexable = "indexable"
    }

    /// The key may be invoked as a tool (a `set` key with a described input).
    public var exposeAsTool: Bool
    /// The key's value (or the collection under `entityItemsKey`) describes entities.
    public var exposeAsEntity: Bool
    /// Property of an entity item that holds its display title.
    public var entityTitleKey: String?
    /// Property of an entity item that holds its stable identifier.
    public var entityIDKey: String?
    /// Property of the key's return value under which the entity items live; nil means the value itself is the entity.
    public var entityItemsKey: String?
    /// What an assistant must prove before it may show the value. Default is the strict choice.
    public var authentication: Authentication
    /// Whether entity items may be put in a local semantic index (never for consent-classified content).
    public var indexable: Bool

    public static let off = AssistantExposure()

    public init(
        exposeAsTool: Bool = false,
        exposeAsEntity: Bool = false,
        entityTitleKey: String? = nil,
        entityIDKey: String? = nil,
        entityItemsKey: String? = nil,
        authentication: Authentication = .requiresAuthentication,
        indexable: Bool = false
    ) {
        self.exposeAsTool = exposeAsTool
        self.exposeAsEntity = exposeAsEntity
        self.entityTitleKey = entityTitleKey
        self.entityIDKey = entityIDKey
        self.entityItemsKey = entityItemsKey
        self.authentication = authentication
        self.indexable = indexable
    }

    public static func tool(authentication: Authentication = .requiresAuthentication) -> AssistantExposure {
        AssistantExposure(exposeAsTool: true, authentication: authentication)
    }

    public static func entity(
        idKey: String = "id",
        titleKey: String = "title",
        itemsKey: String? = nil,
        authentication: Authentication = .requiresAuthentication,
        indexable: Bool = false
    ) -> AssistantExposure {
        AssistantExposure(
            exposeAsEntity: true,
            entityTitleKey: titleKey,
            entityIDKey: idKey,
            entityItemsKey: itemsKey,
            authentication: authentication,
            indexable: indexable
        )
    }

    public var isExposed: Bool { exposeAsTool || exposeAsEntity }

    /// The wire form stored under `ExploreContract.Field.assistant`. Optional
    /// strings are omitted when nil so the object stays minimal and stable.
    public func valueType() -> ValueType {
        var object = Object()
        object[Field.exposeAsTool] = .bool(exposeAsTool)
        object[Field.exposeAsEntity] = .bool(exposeAsEntity)
        if let entityTitleKey {
            object[Field.entityTitleKey] = .string(entityTitleKey)
        }
        if let entityIDKey {
            object[Field.entityIDKey] = .string(entityIDKey)
        }
        if let entityItemsKey {
            object[Field.entityItemsKey] = .string(entityItemsKey)
        }
        object[Field.authentication] = .string(authentication.rawValue)
        object[Field.indexable] = .bool(indexable)
        return .object(object)
    }

    /// Decodes the wire form. Fails closed: a value that is not an object, or
    /// an unknown authentication level, yields nil (treated as not exposed).
    public init?(value: ValueType?) {
        guard case let .object(object)? = value else {
            return nil
        }
        let authenticationName = ExploreContract.string(from: object[Field.authentication])
            ?? Authentication.requiresAuthentication.rawValue
        guard let authentication = Authentication(rawValue: authenticationName) else {
            return nil
        }
        self.init(
            exposeAsTool: ExploreContract.bool(from: object[Field.exposeAsTool]) ?? false,
            exposeAsEntity: ExploreContract.bool(from: object[Field.exposeAsEntity]) ?? false,
            entityTitleKey: ExploreContract.string(from: object[Field.entityTitleKey]),
            entityIDKey: ExploreContract.string(from: object[Field.entityIDKey]),
            entityItemsKey: ExploreContract.string(from: object[Field.entityItemsKey]),
            authentication: authentication,
            indexable: ExploreContract.bool(from: object[Field.indexable]) ?? false
        )
    }
}

public extension ExploreContract {
    /// The assistant exposure declared on a contract, or nil when the contract
    /// does not expose the key (the default for every contract).
    static func assistantExposure(from contract: ValueType?) -> AssistantExposure? {
        guard let object = object(from: contract),
              let exposure = AssistantExposure(value: object[Field.assistant]),
              exposure.isExposed else {
            return nil
        }
        return exposure
    }
}

public extension GeneralCell {
    /// Allows a requester that holds either the cell's owner-area grant or an
    /// exact grant on the key. Owners pass on the first check; an assistant
    /// admitted through `AssistantRequesterContract` holds only exact key
    /// grants, so a key that was not opted in stays denied.
    func validateAccess(
        _ requestedAccess: String,
        atKey key: String,
        orArea area: String,
        for identity: Identity
    ) async -> Bool {
        if await validateAccess(requestedAccess, at: key, for: identity) {
            return true
        }
        return await validateAccess(requestedAccess, at: area, for: identity)
    }
}
