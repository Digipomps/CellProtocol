// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import KeyPathResolver
import HavenCoreSchemas

public final class CommonsResolverCell: GeneralCell {
    private var commonsRootPath: String?
    private var service: CommonsLocalService?
    private var lastLoadError: String?

    private enum CodingKeys: String, CodingKey {
        case commonsRootPath
        case generalCell
    }

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
        reloadService()
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.commonsRootPath = try container.decodeIfPresent(String.self, forKey: .commonsRootPath)
        try super.init(from: decoder)

        Task {
            await setupPermissions(owner: self.owner)
            await setupKeys(owner: self.owner)
            self.reloadService()
        }
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(commonsRootPath, forKey: .commonsRootPath)
    }

    private func setupPermissions(owner: Identity) async {
        agreementTemplate.addGrant("rw--", for: "commons")
    }

    private func setupKeys(owner: Identity) async {
        await addInterceptForGet(requester: owner, key: "commons.status") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "commons", for: requester) else { return .string("denied") }
            return self.statusPayload()
        }

        await addInterceptForGet(requester: owner, key: "commons.samples.keypathRequests") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "commons", for: requester) else { return .string("denied") }
            return self.keypathSamplesPayload()
        }

        await addInterceptForSet(requester: owner, key: "commons.configure.rootPath") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "commons", for: requester) else { return .string("denied") }

            if let value = CommonsCellCodec.string(from: value) {
                self.commonsRootPath = value
                self.reloadService()
                return CommonsCellCodec.success(message: "Configured commons root path", extra: ["root_path": .string(value)])
            }

            if case let .object(object) = value,
               let rootPath = CommonsCellCodec.string(from: object["root_path"]) {
                self.commonsRootPath = rootPath
                self.reloadService()
                return CommonsCellCodec.success(message: "Configured commons root path", extra: ["root_path": .string(rootPath)])
            }

            return CommonsCellCodec.error(message: "Expected string or object with root_path", operation: "commons.configure.rootPath")
        }

        await addInterceptForSet(requester: owner, key: "commons.resolve.keypath") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "commons", for: requester) else { return .string("denied") }
            return self.resolveSingleKeypath(value: value, requester: requester)
        }

        await addInterceptForSet(requester: owner, key: "commons.resolve.batchKeypaths") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "commons", for: requester) else { return .string("denied") }
            return self.resolveBatchKeypaths(value: value)
        }

        await addInterceptForSet(requester: owner, key: "commons.lint.keypaths") { [weak self] _, _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "commons", for: requester) else { return .string("denied") }
            return self.lintPayload()
        }

        await addInterceptForSet(requester: owner, key: "commons.validate.schemas") { [weak self] _, _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "commons", for: requester) else { return .string("denied") }
            return self.validatePayload()
        }

        await registerContracts(requester: owner)
    }

    private func registerContracts(requester: Identity) async {
        await registerExploreContract(
            requester: requester,
            key: "commons.status",
            method: .get,
            input: .null,
            returns: Self.statusSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Reports resolver cell health, configured commons root, and resolver registry counts.")
        )

        await registerExploreContract(
            requester: requester,
            key: "commons.samples.keypathRequests",
            method: .get,
            input: .null,
            returns: Self.samplesSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Returns sample single keypath resolution payloads for documentation, testing, and onboarding.")
        )

        await registerExploreContract(
            requester: requester,
            key: "commons.configure.rootPath",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.schema(type: "string", description: "Filesystem path to the commons root."),
                    ExploreContract.objectSchema(
                        properties: [
                            "root_path": ExploreContract.schema(type: "string", description: "Filesystem path to the commons root.")
                        ],
                        requiredKeys: ["root_path"],
                        description: "Object payload alternative for configure root path."
                    )
                ],
                description: "Accepts either a raw root path string or an object with `root_path`."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [
                    Self.configureSuccessSchema(),
                    Self.errorSchema(operation: "commons.configure.rootPath")
                ],
                description: "Returns success on reconfiguration or a structured error object."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Configures the commons root directory used by the resolver and taxonomy services.")
        )

        await registerExploreContract(
            requester: requester,
            key: "commons.resolve.keypath",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.schema(type: "string", description: "A single keypath resolved relative to the requester identity."),
                    Self.resolveRequestSchema()
                ],
                description: "Accepts a keypath string shortcut or a full ResolveKeyPathRequest object."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [
                    Self.resultEnvelopeSchema(result: Self.resolvedKeyPathSchema()),
                    Self.errorSchema(operation: "commons.resolve.keypath")
                ],
                description: "Returns either a resolved keypath payload or a structured error."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Resolves a single keypath request through the local commons registry.")
        )

        await registerExploreContract(
            requester: requester,
            key: "commons.resolve.batchKeypaths",
            method: .set,
            input: ExploreContract.listSchema(
                item: Self.resolveRequestSchema(),
                description: "List of ResolveKeyPathRequest payloads."
            ),
            returns: Self.batchKeypathResponseSchema(),
            permissions: ["-w--"],
            required: true,
            description: .string("Resolves a batch of keypath requests and returns per-item success or error payloads.")
        )

        await registerExploreContract(
            requester: requester,
            key: "commons.lint.keypaths",
            method: .set,
            input: .null,
            returns: Self.lintResponseSchema(),
            permissions: ["-w--"],
            required: false,
            description: .string("Runs commons keypath lint checks and returns any registry issues.")
        )

        await registerExploreContract(
            requester: requester,
            key: "commons.validate.schemas",
            method: .set,
            input: .null,
            returns: Self.validateSchemasResponseSchema(),
            permissions: ["-w--"],
            required: false,
            description: .string("Validates local commons schemas and reports registry counts for taxonomy and keypath assets.")
        )
    }

    private func reloadService() {
        do {
            if let commonsRootPath, !commonsRootPath.isEmpty {
                service = try CommonsLocalService(
                    commonsRoot: URL(fileURLWithPath: commonsRootPath, isDirectory: true)
                )
            } else {
                service = try CommonsLocalService()
            }
            lastLoadError = nil
        } catch {
            service = nil
            lastLoadError = "\(error)"
        }
    }

    private func statusPayload() -> ValueType {
        var object: Object = [
            "cell": .string("CommonsResolverCell"),
            "service_loaded": .bool(service != nil),
            "commons_root_path": .string(commonsRootPath ?? defaultCommonsRootPath()),
            "operations": .list([
                .string("commons.resolve.keypath"),
                .string("commons.resolve.batchKeypaths"),
                .string("commons.lint.keypaths"),
                .string("commons.validate.schemas"),
                .string("commons.samples.keypathRequests")
            ])
        ]

        if let lastLoadError {
            object["last_error"] = .string(lastLoadError)
        }

        if let service {
            object["registered_keypaths_count"] = .integer(service.keyPathResolver.registry.specs.count)
            object["registered_routes_count"] = .integer(service.keyPathResolver.registry.routes.count)
        }

        return .object(object)
    }

    private func keypathSamplesPayload() -> ValueType {
        let samples: ValueTypeList = [
            .object([
                "entity_id": .string("entity-sample-1"),
                "path": .string("#/identity/addresses"),
                "context": .object(["role": .string("member"), "consent_tokens": .list([])])
            ]),
            .object([
                "entity_id": .string("entity-sample-2"),
                "path": .string("#/purposes"),
                "context": .object(["role": .string("owner"), "consent_tokens": .list([])])
            ]),
            .object([
                "entity_id": .string("entity-sample-3"),
                "path": .string("#/chronicle/events"),
                "context": .object(["role": .string("member"), "consent_tokens": .list([])])
            ]),
            .object([
                "entity_id": .string("entity-sample-4"),
                "path": .string("#/custom/local-football-club/initiative"),
                "context": .object(["role": .string("member"), "consent_tokens": .list([])])
            ]),
            .object([
                "entity_id": .string("entity-sample-5"),
                "path": .string("haven://entity/self#/perspective/pre/goals"),
                "context": .object(["role": .string("member"), "consent_tokens": .list([.string("#/perspective/*")])])
            ])
        ]

        return .object([
            "status": .string("ok"),
            "count": .integer(samples.count),
            "items": .list(samples)
        ])
    }

    private func resolveSingleKeypath(value: ValueType, requester: Identity) -> ValueType {
        guard let service else {
            return CommonsCellCodec.error(
                message: "Commons service not loaded: \(lastLoadError ?? "unknown error")",
                operation: "commons.resolve.keypath"
            )
        }

        do {
            let request = try parseSingleRequest(from: value, requester: requester)
            let response = try service.postResolveKeyPath(request)
            return CommonsCellCodec.success(try CommonsCellCodec.encode(response))
        } catch {
            return CommonsCellCodec.error(error, operation: "commons.resolve.keypath")
        }
    }

    private func resolveBatchKeypaths(value: ValueType) -> ValueType {
        guard let service else {
            return CommonsCellCodec.error(
                message: "Commons service not loaded: \(lastLoadError ?? "unknown error")",
                operation: "commons.resolve.batchKeypaths"
            )
        }

        guard case let .list(items) = value else {
            return CommonsCellCodec.error(
                message: "Expected list of ResolveKeyPathRequest payloads",
                operation: "commons.resolve.batchKeypaths"
            )
        }

        var responses = ValueTypeList()

        for item in items {
            do {
                let request = try CommonsCellCodec.decode(item, as: ResolveKeyPathRequest.self)
                let result = try service.postResolveKeyPath(request)
                responses.append(.object([
                    "status": .string("ok"),
                    "result": try CommonsCellCodec.encode(result)
                ]))
            } catch {
                responses.append(.object([
                    "status": .string("error"),
                    "message": .string("\(error)")
                ]))
            }
        }

        return .object([
            "status": .string("ok"),
            "count": .integer(responses.count),
            "items": .list(responses)
        ])
    }

    private func lintPayload() -> ValueType {
        guard let service else {
            return CommonsCellCodec.error(
                message: "Commons service not loaded: \(lastLoadError ?? "unknown error")",
                operation: "commons.lint.keypaths"
            )
        }

        let issues = service.keyPathResolver.registry.lintIssues()
        return .object([
            "status": .string(issues.isEmpty ? "ok" : "issues"),
            "issues": .list(issues.map { .string($0) }),
            "issue_count": .integer(issues.count)
        ])
    }

    private func validatePayload() -> ValueType {
        guard let service else {
            return CommonsCellCodec.error(
                message: "Commons service not loaded: \(lastLoadError ?? "unknown error")",
                operation: "commons.validate.schemas"
            )
        }

        return .object([
            "status": .string("ok"),
            "taxonomy_packages": .integer(service.taxonomyResolver.registry.packages.count),
            "keypath_specs": .integer(service.keyPathResolver.registry.specs.count),
            "path_routes": .integer(service.keyPathResolver.registry.routes.count)
        ])
    }

    private func parseSingleRequest(from value: ValueType, requester: Identity) throws -> ResolveKeyPathRequest {
        if let path = CommonsCellCodec.string(from: value) {
            return ResolveKeyPathRequest(
                entityId: requester.uuid,
                path: path,
                context: RequesterContext(role: .member)
            )
        }

        return try CommonsCellCodec.decode(value, as: ResolveKeyPathRequest.self)
    }

    private func defaultCommonsRootPath() -> String {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("commons", isDirectory: true)
            .path
    }

    private static func statusSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "cell": ExploreContract.schema(type: "string"),
                "service_loaded": ExploreContract.schema(type: "bool"),
                "commons_root_path": ExploreContract.schema(type: "string"),
                "operations": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "last_error": ExploreContract.schema(type: "string"),
                "registered_keypaths_count": ExploreContract.schema(type: "integer"),
                "registered_routes_count": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["cell", "service_loaded", "commons_root_path", "operations"],
            description: "Resolver cell status payload."
        )
    }

    private static func requesterContextSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "role": ExploreContract.schema(type: "string"),
                "consent_tokens": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))
            ],
            requiredKeys: ["role", "consent_tokens"],
            description: "Requester role and consent context."
        )
    }

    private static func resolveRequestSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "entity_id": ExploreContract.schema(type: "string"),
                "path": ExploreContract.schema(type: "string"),
                "context": requesterContextSchema(),
                "binding": ExploreContract.schema(type: "object", description: "Optional EntityAnchorBinding override.")
            ],
            requiredKeys: ["entity_id", "path", "context"],
            description: "ResolveKeyPathRequest payload."
        )
    }

    private static func samplesSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "count": ExploreContract.schema(type: "integer"),
                "items": ExploreContract.listSchema(item: resolveRequestSchema())
            ],
            requiredKeys: ["status", "count", "items"],
            description: "Sample keypath resolution requests."
        )
    }

    private static func configureSuccessSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "message": ExploreContract.schema(type: "string"),
                "root_path": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["status", "message", "root_path"],
            description: "Successful commons root path configuration response."
        )
    }

    private static func permissionDecisionSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "is_allowed": ExploreContract.schema(type: "bool"),
                "permission_class": ExploreContract.schema(type: "string"),
                "reason": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["is_allowed", "permission_class", "reason"],
            description: "Permission resolution for a keypath."
        )
    }

    private static func keypathAuditSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "alias_applied": ExploreContract.schema(type: "string"),
                "route_prefix": ExploreContract.schema(type: "string"),
                "route_resolution": ExploreContract.schema(type: "string"),
                "deprecated_path": ExploreContract.schema(type: "bool"),
                "registry_matched": ExploreContract.schema(type: "bool")
            ],
            requiredKeys: ["deprecated_path", "registry_matched"],
            description: "Resolver audit metadata for a resolved keypath."
        )
    }

    private static func resolvedKeyPathSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "entity_id": ExploreContract.schema(type: "string"),
                "input_path": ExploreContract.schema(type: "string"),
                "canonical_path": ExploreContract.schema(type: "string"),
                "resolved_cell_id": ExploreContract.schema(type: "string"),
                "resolved_cell_type": ExploreContract.schema(type: "string"),
                "resolved_local_path": ExploreContract.schema(type: "string"),
                "type_ref": ExploreContract.schema(type: "string"),
                "permission": permissionDecisionSchema(),
                "audit_info": keypathAuditSchema(),
                "storage_domain": ExploreContract.schema(type: "string")
            ],
            requiredKeys: [
                "entity_id",
                "input_path",
                "canonical_path",
                "resolved_cell_id",
                "resolved_cell_type",
                "resolved_local_path",
                "type_ref",
                "permission",
                "audit_info"
            ],
            description: "Resolved keypath response payload."
        )
    }

    private static func resultEnvelopeSchema(result: ValueType) -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "result": result
            ],
            requiredKeys: ["status", "result"],
            description: "Success envelope with result payload."
        )
    }

    private static func errorSchema(operation: String) -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "operation": ExploreContract.schema(type: "string", description: operation),
                "message": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["status", "operation", "message"],
            description: "Structured commons error response."
        )
    }

    private static func batchItemSchema(result: ValueType) -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                ExploreContract.objectSchema(
                    properties: [
                        "status": ExploreContract.schema(type: "string"),
                        "result": result
                    ],
                    requiredKeys: ["status", "result"],
                    description: "Batch item success payload."
                ),
                ExploreContract.objectSchema(
                    properties: [
                        "status": ExploreContract.schema(type: "string"),
                        "message": ExploreContract.schema(type: "string")
                    ],
                    requiredKeys: ["status", "message"],
                    description: "Batch item error payload."
                )
            ],
            description: "Per-item batch result."
        )
    }

    private static func batchKeypathResponseSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "count": ExploreContract.schema(type: "integer"),
                "items": ExploreContract.listSchema(item: batchItemSchema(result: resolvedKeyPathSchema()))
            ],
            requiredKeys: ["status", "count", "items"],
            description: "Batch keypath resolution response."
        )
    }

    private static func lintResponseSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "issues": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "issue_count": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["status", "issues", "issue_count"],
            description: "Keypath lint response."
        )
    }

    private static func validateSchemasResponseSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "taxonomy_packages": ExploreContract.schema(type: "integer"),
                "keypath_specs": ExploreContract.schema(type: "integer"),
                "path_routes": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["status", "taxonomy_packages", "keypath_specs", "path_routes"],
            description: "Commons schema validation response."
        )
    }
}
