// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Pure, deterministic projection of a cell's Explore contracts into the shape
/// an assistant adapter needs: tools (callable keys with described parameters),
/// entities (described content) and the grants a requester must hold.
///
/// No Apple types live here. `CellApple` maps `AssistantToolDescriptor` to an
/// App Intents tool intent or a Foundation Models `Tool`, and
/// `AssistantEntityDescriptor` to an `AppEntity`; Vapor and Porthole hosts can
/// read the same descriptors. Output is sorted so equal input gives equal
/// output byte for byte.

public struct AssistantParameterDescriptor: Codable, Equatable, Sendable {
    public var name: String
    /// Canonical Explore type name (`string`, `integer`, `object`, `list`, `oneOf`, …).
    public var type: String
    public var description: String?
    public var required: Bool
    /// For `oneOf`: the canonical type of each accepted option, in declaration order.
    public var options: [String]?

    public init(name: String, type: String, description: String? = nil, required: Bool, options: [String]? = nil) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.options = options
    }
}

public struct AssistantPropertyDescriptor: Codable, Equatable, Sendable {
    public var name: String
    public var type: String
    public var description: String?
    public var required: Bool

    public init(name: String, type: String, description: String? = nil, required: Bool) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

public struct AssistantToolDescriptor: Codable, Equatable {
    public var id: String
    public var cellType: String
    public var key: String
    public var method: String
    /// Humanised key, e.g. `lists.item.add` → "Lists item add". Adapters may localise.
    public var title: String
    /// The contract summary; what the assistant reads to pick the tool.
    public var description: String
    /// The single permission string the contract declares for this operation.
    public var permission: String
    public var authentication: AssistantExposure.Authentication
    public var parameters: [AssistantParameterDescriptor]
    public var inputType: String
    public var returnType: String
    public var flowTopics: [String]
    /// The contract's normalised input schema, for payload validation before dispatch.
    public var inputSchema: ValueType

    public init(
        id: String,
        cellType: String,
        key: String,
        method: String,
        title: String,
        description: String,
        permission: String,
        authentication: AssistantExposure.Authentication,
        parameters: [AssistantParameterDescriptor],
        inputType: String,
        returnType: String,
        flowTopics: [String],
        inputSchema: ValueType
    ) {
        self.id = id
        self.cellType = cellType
        self.key = key
        self.method = method
        self.title = title
        self.description = description
        self.permission = permission
        self.authentication = authentication
        self.parameters = parameters
        self.inputType = inputType
        self.returnType = returnType
        self.flowTopics = flowTopics
        self.inputSchema = inputSchema
    }
}

public struct AssistantEntityDescriptor: Codable, Equatable {
    public var id: String
    public var cellType: String
    public var key: String
    public var method: String
    /// Humanised type name, e.g. `lists.state` + items `lists` → "Lists state lists".
    public var typeName: String
    public var description: String
    public var permission: String
    public var idKey: String
    public var titleKey: String
    public var itemsKey: String?
    public var authentication: AssistantExposure.Authentication
    public var indexable: Bool
    public var properties: [AssistantPropertyDescriptor]
    /// The normalised schema of one entity item.
    public var itemSchema: ValueType

    public init(
        id: String,
        cellType: String,
        key: String,
        method: String,
        typeName: String,
        description: String,
        permission: String,
        idKey: String,
        titleKey: String,
        itemsKey: String?,
        authentication: AssistantExposure.Authentication,
        indexable: Bool,
        properties: [AssistantPropertyDescriptor],
        itemSchema: ValueType
    ) {
        self.id = id
        self.cellType = cellType
        self.key = key
        self.method = method
        self.typeName = typeName
        self.description = description
        self.permission = permission
        self.idKey = idKey
        self.titleKey = titleKey
        self.itemsKey = itemsKey
        self.authentication = authentication
        self.indexable = indexable
        self.properties = properties
        self.itemSchema = itemSchema
    }
}

/// One grant an assistant requester must hold to reach an exposed key.
public struct AssistantGrantRequirement: Codable, Equatable, Hashable, Sendable {
    public var keypath: String
    public var permission: String

    public init(keypath: String, permission: String) {
        self.keypath = keypath
        self.permission = permission
    }
}

public struct AssistantSurfaceDescriptor: Codable, Equatable {
    public static let currentSchemaVersion = "haven.assistant.surface.v1"

    public var schemaVersion: String
    public var cellType: String
    public var contractVersion: Int
    public var tools: [AssistantToolDescriptor]
    public var entities: [AssistantEntityDescriptor]
    /// Deduplicated, sorted by keypath then permission.
    public var grants: [AssistantGrantRequirement]

    public init(
        schemaVersion: String = AssistantSurfaceDescriptor.currentSchemaVersion,
        cellType: String,
        contractVersion: Int = ExploreContract.version,
        tools: [AssistantToolDescriptor],
        entities: [AssistantEntityDescriptor],
        grants: [AssistantGrantRequirement]
    ) {
        self.schemaVersion = schemaVersion
        self.cellType = cellType
        self.contractVersion = contractVersion
        self.tools = tools
        self.entities = entities
        self.grants = grants
    }

    public var isEmpty: Bool { tools.isEmpty && entities.isEmpty }

    public func tool(for key: String) -> AssistantToolDescriptor? {
        tools.first { $0.key == key }
    }

    public func entity(for key: String) -> AssistantEntityDescriptor? {
        entities.first { $0.key == key }
    }
}

public enum AssistantDescriptorProjection {
    /// Projects the surface of a live cell. Uses the per-operation contracts
    /// when the cell provides them, otherwise the legacy single-slot contract
    /// per key. Only contracts that declare an `assistant` exposure contribute.
    public static func project(
        for cell: any CellProtocol,
        requester: Identity
    ) async throws -> AssistantSurfaceDescriptor {
        let cellType = String(describing: type(of: cell))
        let contracts: [ValueType]
        if let provider = cell as? any ExploreOperationContractProviding {
            contracts = try await provider.operationContracts(requester: requester)
        } else {
            var collected = [ValueType]()
            for key in try await cell.keys(requester: requester).sorted() {
                collected.append(try await cell.typeForKey(key: key, requester: requester))
            }
            contracts = collected
        }
        return project(cellType: cellType, contracts: contracts)
    }

    /// Pure projection over contract objects. Order of `contracts` does not matter.
    public static func project(cellType: String, contracts: [ValueType]) -> AssistantSurfaceDescriptor {
        var tools = [AssistantToolDescriptor]()
        var entities = [AssistantEntityDescriptor]()
        var grants = Set<AssistantGrantRequirement>()

        for contract in contracts {
            guard let object = ExploreContract.object(from: contract),
                  let exposure = ExploreContract.assistantExposure(from: contract),
                  let key = ExploreContract.string(from: object[ExploreContract.Field.key]),
                  let method = ExploreContract.string(from: object[ExploreContract.Field.method]) else {
                continue
            }
            let permission = declaredPermission(object: object, method: method)
            let summary = ExploreContract.string(from: object[ExploreContract.Field.summary]) ?? "*"
            let input = object[ExploreContract.Field.input]
            let returns = object[ExploreContract.Field.returns]
            let flowTopics = ExploreContract.flowEffects(from: contract).compactMap {
                ExploreContract.string(from: $0[ExploreContract.Field.topic])
            }

            if exposure.exposeAsTool, method == ExploreContractMethod.set.rawValue {
                tools.append(
                    AssistantToolDescriptor(
                        id: "\(cellType)#\(key)#\(method)",
                        cellType: cellType,
                        key: key,
                        method: method,
                        title: humanise(key),
                        description: summary,
                        permission: permission,
                        authentication: exposure.authentication,
                        parameters: parameters(from: input),
                        inputType: ExploreContract.schemaType(from: input) ?? "unknown",
                        returnType: ExploreContract.schemaType(from: returns) ?? "unknown",
                        flowTopics: flowTopics,
                        inputSchema: input ?? .null
                    )
                )
                grants.insert(AssistantGrantRequirement(keypath: key, permission: permission))
            }

            if exposure.exposeAsEntity {
                let itemSchema = entityItemSchema(returns: returns, itemsKey: exposure.entityItemsKey)
                let typeNameSource = exposure.entityItemsKey.map { "\(key).\($0)" } ?? key
                entities.append(
                    AssistantEntityDescriptor(
                        id: "\(cellType)#\(key)#\(method)#entity",
                        cellType: cellType,
                        key: key,
                        method: method,
                        typeName: humanise(typeNameSource),
                        description: summary,
                        permission: permission,
                        idKey: exposure.entityIDKey ?? "id",
                        titleKey: exposure.entityTitleKey ?? "title",
                        itemsKey: exposure.entityItemsKey,
                        authentication: exposure.authentication,
                        indexable: exposure.indexable,
                        properties: properties(from: itemSchema),
                        itemSchema: itemSchema
                    )
                )
                grants.insert(AssistantGrantRequirement(keypath: key, permission: permission))
            }
        }

        tools.sort { ($0.key, $0.method) < ($1.key, $1.method) }
        entities.sort { ($0.key, $0.method) < ($1.key, $1.method) }
        let sortedGrants = grants.sorted { ($0.keypath, $0.permission) < ($1.keypath, $1.permission) }

        return AssistantSurfaceDescriptor(
            cellType: cellType,
            tools: tools,
            entities: entities,
            grants: sortedGrants
        )
    }

    // MARK: - Helpers

    /// "lists.item.add" → "Lists item add".
    public static func humanise(_ key: String) -> String {
        let words = key.split(separator: ".").map { String($0) }.filter { !$0.isEmpty }
        guard let first = words.first else { return key }
        let head = first.prefix(1).uppercased() + String(first.dropFirst())
        return ([head] + words.dropFirst().map { $0.lowercased() }).joined(separator: " ")
    }

    static func declaredPermission(object: Object, method: String) -> String {
        let declared = ExploreContract.list(from: object[ExploreContract.Field.permissions])?
            .compactMap { ExploreContract.string(from: $0) } ?? []
        if let first = declared.first {
            return first
        }
        return method == ExploreContractMethod.get.rawValue ? "r---" : "-w--"
    }

    /// Flattens an input schema into named parameters. An object schema gives
    /// one parameter per property (sorted by name); anything else gives one
    /// parameter named `value`. A `null` input gives no parameters.
    static func parameters(from input: ValueType?) -> [AssistantParameterDescriptor] {
        guard let input else { return [] }
        if case .null = input { return [] }

        if let object = ExploreContract.object(from: input),
           object[ExploreContract.Field.oneOf] == nil,
           let propertySchemas = ExploreContract.object(from: object[ExploreContract.Field.properties]),
           !propertySchemas.isEmpty {
            let requiredKeys = Set(
                ExploreContract.list(from: object[ExploreContract.Field.requiredKeys])?
                    .compactMap { ExploreContract.string(from: $0) } ?? []
            )
            return propertySchemas.keys.sorted().map { name in
                let schema = propertySchemas[name]
                return AssistantParameterDescriptor(
                    name: name,
                    type: ExploreContract.schemaType(from: schema) ?? "unknown",
                    description: schemaDescription(schema),
                    required: requiredKeys.contains(name),
                    options: oneOfOptionTypes(schema)
                )
            }
        }

        return [
            AssistantParameterDescriptor(
                name: "value",
                type: ExploreContract.schemaType(from: input) ?? "unknown",
                description: schemaDescription(input),
                required: true,
                options: oneOfOptionTypes(input)
            )
        ]
    }

    static func properties(from itemSchema: ValueType) -> [AssistantPropertyDescriptor] {
        guard let object = ExploreContract.object(from: itemSchema),
              let propertySchemas = ExploreContract.object(from: object[ExploreContract.Field.properties]) else {
            return []
        }
        let requiredKeys = Set(
            ExploreContract.list(from: object[ExploreContract.Field.requiredKeys])?
                .compactMap { ExploreContract.string(from: $0) } ?? []
        )
        return propertySchemas.keys.sorted().map { name in
            let schema = propertySchemas[name]
            return AssistantPropertyDescriptor(
                name: name,
                type: ExploreContract.schemaType(from: schema) ?? "unknown",
                description: schemaDescription(schema),
                required: requiredKeys.contains(name)
            )
        }
    }

    /// Finds the schema of one entity item: the return schema itself, or the
    /// `item` of the list stored under `itemsKey` in the return schema's properties.
    static func entityItemSchema(returns: ValueType?, itemsKey: String?) -> ValueType {
        guard let returns else { return ExploreContract.unknownSchema() }
        guard let itemsKey else { return returns }
        guard let object = ExploreContract.object(from: returns),
              let propertySchemas = ExploreContract.object(from: object[ExploreContract.Field.properties]),
              let collection = propertySchemas[itemsKey] else {
            return ExploreContract.unknownSchema(description: "No property \(itemsKey) in return schema")
        }
        if let collectionObject = ExploreContract.object(from: collection),
           let item = collectionObject[ExploreContract.Field.item] {
            return item
        }
        return collection
    }

    static func schemaDescription(_ schema: ValueType?) -> String? {
        guard let object = ExploreContract.object(from: schema) else { return nil }
        return ExploreContract.string(from: object[ExploreContract.Field.description])
    }

    static func oneOfOptionTypes(_ schema: ValueType?) -> [String]? {
        guard let object = ExploreContract.object(from: schema),
              let options = ExploreContract.list(from: object[ExploreContract.Field.oneOf]) else {
            return nil
        }
        return options.map { ExploreContract.schemaType(from: $0) ?? $0.contractTypeName }
    }
}
