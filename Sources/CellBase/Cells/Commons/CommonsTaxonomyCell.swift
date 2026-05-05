// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import HavenCoreSchemas
import KeyPathResolver

public final class CommonsTaxonomyCell: GeneralCell {
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
        agreementTemplate.addGrant("rw--", for: "taxonomy")
    }

    private func setupKeys(owner: Identity) async {
        await addInterceptForGet(requester: owner, key: "taxonomy.status") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "taxonomy", for: requester) else { return .string("denied") }
            return self.statusPayload()
        }

        await addInterceptForGet(requester: owner, key: "taxonomy.samples.termRequests") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "taxonomy", for: requester) else { return .string("denied") }
            return self.termSamplesPayload()
        }

        await addInterceptForSet(requester: owner, key: "taxonomy.configure.rootPath") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "taxonomy", for: requester) else { return .string("denied") }

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

            return CommonsCellCodec.error(message: "Expected string or object with root_path", operation: "taxonomy.configure.rootPath")
        }

        await addInterceptForSet(requester: owner, key: "taxonomy.resolve.term") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "taxonomy", for: requester) else { return .string("denied") }
            return self.resolveTerm(value: value)
        }

        await addInterceptForSet(requester: owner, key: "taxonomy.resolve.batchTerms") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "taxonomy", for: requester) else { return .string("denied") }
            return self.resolveBatchTerms(value: value)
        }

        await addInterceptForSet(requester: owner, key: "taxonomy.resolve.guidance") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "taxonomy", for: requester) else { return .string("denied") }
            return self.resolveGuidance(value: value)
        }

        await addInterceptForSet(requester: owner, key: "taxonomy.validate.purposeTree") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "taxonomy", for: requester) else { return .string("denied") }
            return self.validatePurposeTree(value: value)
        }

        await addInterceptForSet(requester: owner, key: "taxonomy.validate.localizationCoverage") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "taxonomy", for: requester) else { return .string("denied") }
            return self.validateLocalizationCoverage(value: value)
        }

        await registerContracts(requester: owner)
    }

    private func registerContracts(requester: Identity) async {
        await registerExploreContract(
            requester: requester,
            key: "taxonomy.status",
            method: .get,
            input: .null,
            returns: Self.statusSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Reports taxonomy cell health, configured commons root, and loaded taxonomy package count.")
        )

        await registerExploreContract(
            requester: requester,
            key: "taxonomy.samples.termRequests",
            method: .get,
            input: .null,
            returns: Self.samplesSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Returns example taxonomy resolve, guidance, purpose-tree validation, and localization coverage payloads.")
        )

        await registerExploreContract(
            requester: requester,
            key: "taxonomy.configure.rootPath",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.schema(type: "string", description: "Filesystem path to the commons root."),
                    ExploreContract.objectSchema(
                        properties: [
                            "root_path": ExploreContract.schema(type: "string")
                        ],
                        requiredKeys: ["root_path"],
                        description: "Object payload alternative for configure root path."
                    )
                ],
                description: "Accepts either a raw path string or an object with `root_path`."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [
                    Self.configureSuccessSchema(),
                    Self.errorSchema(operation: "taxonomy.configure.rootPath")
                ],
                description: "Returns success on reconfiguration or a structured error response."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Configures the commons root directory used by the taxonomy resolver.")
        )

        await registerExploreContract(
            requester: requester,
            key: "taxonomy.resolve.term",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.schema(type: "string", description: "Term identifier shortcut."),
                    Self.termRequestSchema()
                ],
                description: "Accepts a term id string or a full term resolve request object."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [
                    Self.resultEnvelopeSchema(result: Self.resolvedTermSchema()),
                    Self.errorSchema(operation: "taxonomy.resolve.term")
                ],
                description: "Returns either a resolved taxonomy term or a structured error."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Resolves a single taxonomy term and returns localized label and source namespace.")
        )

        await registerExploreContract(
            requester: requester,
            key: "taxonomy.resolve.batchTerms",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.listSchema(
                        item: Self.termRequestSchema(),
                        description: "List of taxonomy term resolve requests."
                    ),
                    Self.termBatchRequestSchema()
                ],
                description: "Accepts a legacy list of term requests or an object with shared `locale`, `namespace`, and `terms`."
            ),
            returns: Self.batchTermsResponseSchema(),
            permissions: ["-w--"],
            required: true,
            description: .string("Resolves a batch of taxonomy term requests and returns localized labels with requested/resolved locale metadata.")
        )

        await registerExploreContract(
            requester: requester,
            key: "taxonomy.resolve.guidance",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.schema(type: "string", description: "Namespace shortcut."),
                    Self.namespaceRequestSchema()
                ],
                description: "Accepts a namespace string or an object with `namespace`."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [
                    Self.resultEnvelopeSchema(result: Self.guidanceSchema()),
                    Self.errorSchema(operation: "taxonomy.resolve.guidance")
                ],
                description: "Returns taxonomy guidance or a structured error response."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Resolves taxonomy guidance for a namespace, including mandatory inherited purposes and goal policy.")
        )

        await registerExploreContract(
            requester: requester,
            key: "taxonomy.validate.purposeTree",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.schema(type: "string", description: "Namespace shortcut."),
                    Self.namespaceRequestSchema()
                ],
                description: "Accepts a namespace string or an object with `namespace`."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [
                    Self.statusResultEnvelopeSchema(result: Self.purposeTreeValidationSchema()),
                    Self.errorSchema(operation: "taxonomy.validate.purposeTree")
                ],
                description: "Returns purpose-tree validation results or a structured error."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Validates that a taxonomy namespace satisfies purpose-tree governance rules.")
        )

        await registerExploreContract(
            requester: requester,
            key: "taxonomy.validate.localizationCoverage",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.schema(type: "string", description: "Namespace shortcut."),
                    Self.localizationCoverageRequestSchema()
                ],
                description: "Accepts a namespace string or an object with `namespace` and optional `required_locales`."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [
                    Self.statusResultEnvelopeSchema(result: Self.localizationCoverageSchema()),
                    Self.errorSchema(operation: "taxonomy.validate.localizationCoverage")
                ],
                description: "Returns localization coverage warnings for missing required labels."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Warns when active taxonomy terms are missing labels for required user-interface locales.")
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
            "cell": .string("CommonsTaxonomyCell"),
            "service_loaded": .bool(service != nil),
            "commons_root_path": .string(commonsRootPath ?? defaultCommonsRootPath()),
            "operations": .list([
                .string("taxonomy.resolve.term"),
                .string("taxonomy.resolve.batchTerms"),
                .string("taxonomy.resolve.guidance"),
                .string("taxonomy.validate.purposeTree"),
                .string("taxonomy.validate.localizationCoverage"),
                .string("taxonomy.samples.termRequests")
            ])
        ]

        if let lastLoadError {
            object["last_error"] = .string(lastLoadError)
        }

        if let service {
            object["taxonomy_packages"] = .integer(service.taxonomyResolver.registry.packages.count)
        }

        return .object(object)
    }

    private func termSamplesPayload() -> ValueType {
        let samples: ValueTypeList = [
            .object(["term_id": .string("purpose.human-equal-worth"), "lang": .string("en-US"), "namespace": .string("haven.core")]),
            .object(["term_id": .string("purpose.net-positive-contribution"), "lang": .string("nb-NO"), "namespace": .string("haven.conference")]),
            .object(["term_id": .string("goal.reduce-emissions"), "lang": .string("en-US"), "namespace": .string("haven.conference")]),
            .object(["term_id": .string("goal.support-local-community"), "lang": .string("nb-NO"), "namespace": .string("haven.conference")]),
            .object(["term_id": .string("conference.sponsor"), "lang": .string("en-US"), "namespace": .string("haven.conference")]),
            .object(["namespace": .string("haven.conference"), "mode": .string("guidance")]),
            .object(["namespace": .string("haven.core"), "mode": .string("validate.purposeTree")]),
            .object([
                "namespace": .string("haven.core"),
                "required_locales": .list([.string("nb-NO"), .string("en-US")]),
                "mode": .string("validate.localizationCoverage")
            ])
        ]

        return .object([
            "status": .string("ok"),
            "count": .integer(samples.count),
            "items": .list(samples)
        ])
    }

    private func resolveTerm(value: ValueType) -> ValueType {
        guard let service else {
            return CommonsCellCodec.error(
                message: "Commons service not loaded: \(lastLoadError ?? "unknown error")",
                operation: "taxonomy.resolve.term"
            )
        }

        do {
            let request = try parseTermRequest(from: value)
            guard let resolved = try service.getTaxonomyResolve(
                termId: request.termID,
                lang: request.lang ?? "nb-NO",
                namespace: request.namespace
            ) else {
                return CommonsCellCodec.error(
                    message: "Term not found: \(request.termID)",
                    operation: "taxonomy.resolve.term"
                )
            }

            return CommonsCellCodec.success(try CommonsCellCodec.encode(resolved))
        } catch {
            return CommonsCellCodec.error(error, operation: "taxonomy.resolve.term")
        }
    }

    private func resolveBatchTerms(value: ValueType) -> ValueType {
        guard let service else {
            return CommonsCellCodec.error(
                message: "Commons service not loaded: \(lastLoadError ?? "unknown error")",
                operation: "taxonomy.resolve.batchTerms"
            )
        }

        let batch: (items: ValueTypeList, locale: String?, namespace: String?)
        do {
            batch = try parseBatchTermRequest(from: value)
        } catch {
            return CommonsCellCodec.error(
                message: "Expected list of term resolve payloads or object with terms",
                operation: "taxonomy.resolve.batchTerms"
            )
        }

        var responses = ValueTypeList()

        for item in batch.items {
            do {
                let request = try parseTermRequest(
                    from: item,
                    defaultLang: batch.locale ?? "nb-NO",
                    defaultNamespace: batch.namespace
                )
                if let resolved = try service.getTaxonomyResolve(
                    termId: request.termID,
                    lang: request.lang ?? "nb-NO",
                    namespace: request.namespace
                ) {
                    responses.append(.object([
                        "status": .string("ok"),
                        "result": try CommonsCellCodec.encode(resolved)
                    ]))
                } else {
                    responses.append(.object([
                        "status": .string("error"),
                        "message": .string("Term not found: \(request.termID)")
                    ]))
                }
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

    private func resolveGuidance(value: ValueType) -> ValueType {
        guard let service else {
            return CommonsCellCodec.error(
                message: "Commons service not loaded: \(lastLoadError ?? "unknown error")",
                operation: "taxonomy.resolve.guidance"
            )
        }

        do {
            let request = try parseGuidanceRequest(from: value)

            guard let guidance = try service.getTaxonomyGuidance(namespace: request.namespace) else {
                return CommonsCellCodec.error(
                    message: "Guidance not found for namespace: \(request.namespace)",
                    operation: "taxonomy.resolve.guidance"
                )
            }

            return CommonsCellCodec.success(try CommonsCellCodec.encode(guidance))
        } catch {
            return CommonsCellCodec.error(error, operation: "taxonomy.resolve.guidance")
        }
    }

    private func validatePurposeTree(value: ValueType) -> ValueType {
        guard let service else {
            return CommonsCellCodec.error(
                message: "Commons service not loaded: \(lastLoadError ?? "unknown error")",
                operation: "taxonomy.validate.purposeTree"
            )
        }

        do {
            let request = try parseGuidanceRequest(from: value)
            let result = try service.getTaxonomyPurposeTreeValidation(namespace: request.namespace)
            return .object([
                "status": .string(result.isValid ? "ok" : "issues"),
                "result": try CommonsCellCodec.encode(result)
            ])
        } catch {
            return CommonsCellCodec.error(error, operation: "taxonomy.validate.purposeTree")
        }
    }

    private func validateLocalizationCoverage(value: ValueType) -> ValueType {
        guard let service else {
            return CommonsCellCodec.error(
                message: "Commons service not loaded: \(lastLoadError ?? "unknown error")",
                operation: "taxonomy.validate.localizationCoverage"
            )
        }

        do {
            let request = try parseLocalizationCoverageRequest(from: value)
            let requiredLocales = request.requiredLocales.isEmpty
                ? LocalizationDefaults.defaultRequiredLocales
                : request.requiredLocales
            let result = try service.getTaxonomyLocalizationCoverage(
                namespace: request.namespace,
                requiredLocales: requiredLocales
            )
            return .object([
                "status": .string(result.isComplete ? "ok" : "warnings"),
                "result": try CommonsCellCodec.encode(result)
            ])
        } catch {
            return CommonsCellCodec.error(error, operation: "taxonomy.validate.localizationCoverage")
        }
    }

    private func parseTermRequest(
        from value: ValueType,
        defaultLang: String = "nb-NO",
        defaultNamespace: String? = nil
    ) throws -> CommonsCellCodec.TermResolveRequest {
        if let termID = CommonsCellCodec.string(from: value) {
            return CommonsCellCodec.TermResolveRequest(termID: termID, lang: defaultLang, namespace: defaultNamespace)
        }

        let request = try CommonsCellCodec.decode(value, as: CommonsCellCodec.TermResolveRequest.self)
        return CommonsCellCodec.TermResolveRequest(
            termID: request.termID,
            lang: request.lang ?? defaultLang,
            namespace: request.namespace ?? defaultNamespace
        )
    }

    private func parseBatchTermRequest(from value: ValueType) throws -> (items: ValueTypeList, locale: String?, namespace: String?) {
        if case let .list(items) = value {
            return (items, nil, nil)
        }

        guard case let .object(object) = value,
              case let .list(items)? = object["terms"] else {
            throw NSError(
                domain: "CommonsTaxonomyCell",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected list or object with terms."]
            )
        }

        let locale = CommonsCellCodec.string(from: object["locale"])
            ?? CommonsCellCodec.string(from: object["lang"])
        let namespace = CommonsCellCodec.string(from: object["namespace"])
        return (items, locale, namespace)
    }

    private func parseGuidanceRequest(from value: ValueType) throws -> CommonsCellCodec.GuidanceRequest {
        if let namespace = CommonsCellCodec.string(from: value) {
            return CommonsCellCodec.GuidanceRequest(namespace: namespace)
        }

        return try CommonsCellCodec.decode(value, as: CommonsCellCodec.GuidanceRequest.self)
    }

    private func parseLocalizationCoverageRequest(from value: ValueType) throws -> CommonsCellCodec.LocalizationCoverageRequest {
        if let namespace = CommonsCellCodec.string(from: value) {
            return CommonsCellCodec.LocalizationCoverageRequest(namespace: namespace)
        }

        return try CommonsCellCodec.decode(value, as: CommonsCellCodec.LocalizationCoverageRequest.self)
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
                "taxonomy_packages": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["cell", "service_loaded", "commons_root_path", "operations"],
            description: "Taxonomy cell status payload."
        )
    }

    private static func termRequestSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "term_id": ExploreContract.schema(type: "string"),
                "lang": ExploreContract.schema(type: "string", description: "BCP-47 locale. Defaults to nb-NO when omitted."),
                "locale": ExploreContract.schema(type: "string", description: "Alias for lang."),
                "namespace": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["term_id"],
            description: "Taxonomy term resolve request."
        )
    }

    private static func termBatchRequestSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "terms": ExploreContract.listSchema(
                    item: ExploreContract.oneOfSchema(
                        options: [
                            ExploreContract.schema(type: "string", description: "Term identifier shortcut."),
                            Self.termRequestSchema()
                        ],
                        description: "Term id string or full term request."
                    )
                ),
                "locale": ExploreContract.schema(type: "string", description: "Shared BCP-47 locale for term requests without lang."),
                "lang": ExploreContract.schema(type: "string", description: "Alias for locale."),
                "namespace": ExploreContract.schema(type: "string", description: "Shared namespace for term requests without namespace.")
            ],
            requiredKeys: ["terms"],
            description: "Batch resolve request with shared locale and namespace defaults."
        )
    }

    private static func namespaceRequestSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "namespace": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["namespace"],
            description: "Namespace request payload."
        )
    }

    private static func localizationCoverageRequestSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "namespace": ExploreContract.schema(type: "string"),
                "required_locales": ExploreContract.listSchema(
                    item: ExploreContract.schema(type: "string"),
                    description: "Required BCP-47 locales. Defaults to nb-NO and en-US."
                )
            ],
            requiredKeys: ["namespace"],
            description: "Localization coverage validation request."
        )
    }

    private static func samplesSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "count": ExploreContract.schema(type: "integer"),
                "items": ExploreContract.listSchema(
                    item: ExploreContract.objectSchema(
                        properties: [
                            "term_id": ExploreContract.schema(type: "string"),
                            "lang": ExploreContract.schema(type: "string"),
                            "namespace": ExploreContract.schema(type: "string"),
                            "mode": ExploreContract.schema(type: "string")
                        ],
                        description: "Sample taxonomy request or mode selector."
                    )
                )
            ],
            requiredKeys: ["status", "count", "items"],
            description: "Sample taxonomy requests."
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
            description: "Successful taxonomy root path configuration response."
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
            description: "Structured taxonomy error response."
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

    private static func statusResultEnvelopeSchema(result: ValueType) -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string", description: "Typically `ok` or `issues`."),
                "result": result
            ],
            requiredKeys: ["status", "result"],
            description: "Result envelope where status can signal issues without being a transport error."
        )
    }

    private static func resolvedTermSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "term": ExploreContract.schema(type: "object", description: "Resolved taxonomy term record."),
                "source_namespace": ExploreContract.schema(type: "string"),
                "label": ExploreContract.schema(type: "string"),
                "requested_locale": ExploreContract.schema(type: "string"),
                "resolved_locale": ExploreContract.schema(type: "string"),
                "fallback_used": ExploreContract.schema(type: "bool"),
                "replacement_term": ExploreContract.schema(type: "object", description: "Replacement term when deprecated.")
            ],
            requiredKeys: ["term", "source_namespace", "label"],
            description: "Resolved taxonomy term payload."
        )
    }

    private static func guidanceSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "root_purpose_term_id": ExploreContract.schema(type: "string"),
                "contribution_purpose_term_id": ExploreContract.schema(type: "string"),
                "article_reference": ExploreContract.schema(type: "string"),
                "incentive_only": ExploreContract.schema(type: "bool"),
                "goal_policy": ExploreContract.objectSchema(
                    properties: [
                        "mode": ExploreContract.schema(type: "string"),
                        "description": ExploreContract.schema(type: "string")
                    ],
                    requiredKeys: ["mode", "description"]
                ),
                "mandatory_inherited_purposes": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "forbidden_relations_to_mandatory": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))
            ],
            requiredKeys: [
                "root_purpose_term_id",
                "contribution_purpose_term_id",
                "article_reference",
                "incentive_only",
                "goal_policy",
                "mandatory_inherited_purposes",
                "forbidden_relations_to_mandatory"
            ],
            description: "Taxonomy guidance payload."
        )
    }

    private static func purposeTreeValidationSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "namespace": ExploreContract.schema(type: "string"),
                "mandatory_purpose_term_ids": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "issues": ExploreContract.listSchema(
                    item: ExploreContract.objectSchema(
                        properties: [
                            "severity": ExploreContract.schema(type: "string"),
                            "code": ExploreContract.schema(type: "string"),
                            "message": ExploreContract.schema(type: "string"),
                            "term_id": ExploreContract.schema(type: "string"),
                            "related_term_id": ExploreContract.schema(type: "string")
                        ],
                        requiredKeys: ["severity", "code", "message"],
                        description: "Purpose-tree validation issue."
                    )
                ),
                "error_count": ExploreContract.schema(type: "integer"),
                "warning_count": ExploreContract.schema(type: "integer"),
                "is_valid": ExploreContract.schema(type: "bool")
            ],
            requiredKeys: [
                "namespace",
                "mandatory_purpose_term_ids",
                "issues",
                "error_count",
                "warning_count",
                "is_valid"
            ],
            description: "Purpose-tree validation result."
        )
    }

    private static func localizationCoverageSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "namespace": ExploreContract.schema(type: "string"),
                "requiredLocales": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "issues": ExploreContract.listSchema(
                    item: ExploreContract.objectSchema(
                        properties: [
                            "severity": ExploreContract.schema(type: "string"),
                            "namespace": ExploreContract.schema(type: "string"),
                            "termID": ExploreContract.schema(type: "string"),
                            "kind": ExploreContract.schema(type: "string"),
                            "locale": ExploreContract.schema(type: "string"),
                            "message": ExploreContract.schema(type: "string")
                        ],
                        requiredKeys: ["severity", "namespace", "termID", "kind", "locale", "message"],
                        description: "Missing localization label warning."
                    )
                ),
                "warningCount": ExploreContract.schema(type: "integer"),
                "isComplete": ExploreContract.schema(type: "bool")
            ],
            requiredKeys: ["namespace", "requiredLocales", "issues", "warningCount", "isComplete"],
            description: "Localization coverage validation result."
        )
    }

    private static func batchTermsResponseSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "count": ExploreContract.schema(type: "integer"),
                "items": ExploreContract.listSchema(
                    item: ExploreContract.oneOfSchema(
                        options: [
                            ExploreContract.objectSchema(
                                properties: [
                                    "status": ExploreContract.schema(type: "string"),
                                    "result": resolvedTermSchema()
                                ],
                                requiredKeys: ["status", "result"],
                                description: "Batch term success payload."
                            ),
                            ExploreContract.objectSchema(
                                properties: [
                                    "status": ExploreContract.schema(type: "string"),
                                    "message": ExploreContract.schema(type: "string")
                                ],
                                requiredKeys: ["status", "message"],
                                description: "Batch term error payload."
                            )
                        ],
                        description: "Per-item taxonomy batch result."
                    )
                )
            ],
            requiredKeys: ["status", "count", "items"],
            description: "Batch term resolution response."
        )
    }
}
