// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum EntityBatchPersistEnvelopeError: Error {
    case missingField(String)
    case wrongFieldType(String)
}

public struct EntityBatchPersistMutation: Codable, Equatable {
    public var keypath: String
    public var value: ValueType

    public init(keypath: String, value: ValueType) {
        self.keypath = keypath
        self.value = value
    }

    public init(object: Object) throws {
        guard let keypathValue = object["keypath"] else {
            throw EntityBatchPersistEnvelopeError.missingField("keypath")
        }
        guard case let .string(keypath) = keypathValue else {
            throw EntityBatchPersistEnvelopeError.wrongFieldType("keypath")
        }
        guard let value = object["value"] else {
            throw EntityBatchPersistEnvelopeError.missingField("value")
        }
        self.keypath = keypath
        self.value = value
    }

    public func objectValue() -> Object {
        [
            "keypath": .string(keypath),
            "value": value
        ]
    }
}

public struct EntityBatchPersistEnvelope: Codable, Equatable {
    public static let operation = "entity.batchPersist"

    public var schema: String
    public var mutations: [EntityBatchPersistMutation]
    public var metadata: Object

    public init(
        schema: String,
        mutations: [EntityBatchPersistMutation],
        metadata: Object = [:]
    ) {
        self.schema = schema
        self.mutations = mutations
        self.metadata = metadata
    }

    public init(object: Object) throws {
        guard let schemaValue = object["schema"] else {
            throw EntityBatchPersistEnvelopeError.missingField("schema")
        }
        guard case let .string(schema) = schemaValue else {
            throw EntityBatchPersistEnvelopeError.wrongFieldType("schema")
        }
        guard let mutationsValue = object["mutations"] else {
            throw EntityBatchPersistEnvelopeError.missingField("mutations")
        }
        guard case let .list(mutationValues) = mutationsValue else {
            throw EntityBatchPersistEnvelopeError.wrongFieldType("mutations")
        }

        self.schema = schema
        self.mutations = try mutationValues.map { item in
            guard case let .object(object) = item else {
                throw EntityBatchPersistEnvelopeError.wrongFieldType("mutations[]")
            }
            return try EntityBatchPersistMutation(object: object)
        }

        if let metadataValue = object["metadata"] {
            guard case let .object(metadata) = metadataValue else {
                throw EntityBatchPersistEnvelopeError.wrongFieldType("metadata")
            }
            self.metadata = metadata
        } else {
            self.metadata = [:]
        }
    }

    public func objectValue() -> Object {
        [
            "schema": .string(schema),
            "mutations": .list(mutations.map { .object($0.objectValue()) }),
            "metadata": .object(metadata)
        ]
    }
}
