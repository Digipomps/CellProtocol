// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import HavenCoreSchemas
import TaxonomyResolver

public struct ResolveKeyPathRequest: Codable, Hashable, Sendable {
    public var entityId: String
    public var path: String
    public var context: RequesterContext
    public var binding: EntityAnchorBinding?

    public init(entityId: String, path: String, context: RequesterContext, binding: EntityAnchorBinding? = nil) {
        self.entityId = entityId
        self.path = path
        self.context = context
        self.binding = binding
    }

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case path
        case context
        case binding
    }
}

public final class CommonsLocalService: @unchecked Sendable {
    public let taxonomyResolver: TaxonomyTermResolver
    public let keyPathResolver: KeyPathResolver

    public init(commonsRoot: URL = CommonsPaths.defaultRootURL()) throws {
        let taxonomyRegistry = try TaxonomyRegistry.load(from: CommonsPaths.taxonomiesURL(root: commonsRoot))
        let keyPathRegistry = try KeyPathRegistry.load(from: CommonsPaths.keypathsURL(root: commonsRoot))

        self.taxonomyResolver = TaxonomyTermResolver(registry: taxonomyRegistry)
        self.keyPathResolver = KeyPathResolver(registry: keyPathRegistry)
    }

    public init(taxonomyResolver: TaxonomyTermResolver, keyPathResolver: KeyPathResolver) {
        self.taxonomyResolver = taxonomyResolver
        self.keyPathResolver = keyPathResolver
    }

    public func postResolveKeyPath(_ request: ResolveKeyPathRequest) throws -> ResolvedKeyPath {
        let binding = request.binding ?? EntityAnchorBinding.seeded(entityId: request.entityId)

        return try keyPathResolver.resolve(
            entityId: request.entityId,
            path: request.path,
            context: request.context,
            binding: binding
        )
    }

    public func getTaxonomyTerm(id termId: String, namespace: String? = nil) throws -> Term? {
        try taxonomyResolver.term(termID: termId, namespace: namespace)
    }

    public func getTaxonomyResolve(
        termId: String,
        lang: String,
        namespace: String? = nil
    ) throws -> ResolvedTaxonomyTerm? {
        try taxonomyResolver.resolve(termID: termId, lang: lang, namespace: namespace)
    }

    public func getTaxonomyLocalizedTerm(
        termId: String,
        lang: String,
        namespace: String? = nil
    ) throws -> ResolvedLocalizedTerm? {
        try taxonomyResolver.resolveLocalizedTerm(termID: termId, lang: lang, namespace: namespace)
    }

    public func getTaxonomyGuidance(namespace: String) throws -> TaxonomyPackage.Guidance? {
        try taxonomyResolver.guidance(namespace: namespace)
    }

    public func getTaxonomyPurposeTreeValidation(namespace: String) throws -> PurposeTreeValidationResult {
        try taxonomyResolver.validatePurposeTree(namespace: namespace)
    }

    public func getTaxonomyLocalizationCoverage(
        namespace: String,
        requiredLocales: [String] = LocalizationDefaults.defaultRequiredLocales
    ) throws -> TaxonomyLocalizationCoverageResult {
        try taxonomyResolver.validateLocalizationCoverage(namespace: namespace, requiredLocales: requiredLocales)
    }
}
