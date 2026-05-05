// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import HavenCoreSchemas

public struct KeyPathResolver: Sendable {
    public let registry: KeyPathRegistry
    public let permissionEvaluator: PermissionEvaluator

    public init(registry: KeyPathRegistry, permissionEvaluator: PermissionEvaluator = PermissionEvaluator()) {
        self.registry = registry
        self.permissionEvaluator = permissionEvaluator
    }

    public func resolve(
        entityId: String,
        path: String,
        context: RequesterContext,
        binding: EntityAnchorBinding? = nil
    ) throws -> ResolvedKeyPath {
        let normalizedInput = JSONPointer.normalize(path)
        let canonical = registry.canonicalize(path: normalizedInput)
        let route = registry.route(for: canonical.path)
        let matchedSpec = registry.spec(for: canonical.path)
        let spec = matchedSpec ?? inferredOpenSpec(for: canonical.path, route: route)

        let routePrefix = route?.prefix
        let relation = relationForRoute(route, spec: spec, canonicalPath: canonical.path, binding: binding)

        let resolvedCellType = route?.cellType ?? spec.owner
        let resolvedCellId = relation?.cellId ?? binding?.anchorCellId ?? "anchor:\(entityId)"
        let resolvedLocalPath: String

        if let route {
            resolvedLocalPath = JSONPointer.applyPrefix(
                path: canonical.path,
                prefix: route.prefix,
                localPrefix: route.localPrefix
            )
        } else {
            resolvedLocalPath = canonical.path
        }

        let permission = permissionEvaluator.evaluate(
            permissionClass: spec.visibilityClass,
            context: context,
            path: canonical.path
        )

        let inputSpec = registry.spec(for: normalizedInput)

        return ResolvedKeyPath(
            entityId: entityId,
            inputPath: normalizedInput,
            canonicalPath: canonical.path,
            resolvedCellId: resolvedCellId,
            resolvedCellType: resolvedCellType,
            resolvedLocalPath: resolvedLocalPath,
            typeRef: spec.typeRef,
            permission: permission,
            auditInfo: KeyPathResolutionAudit(
                aliasApplied: canonical.aliasApplied,
                routePrefix: routePrefix,
                routeResolution: route?.resolution,
                deprecatedPath: inputSpec?.deprecated ?? false,
                registryMatched: matchedSpec != nil
            ),
            storageDomain: spec.storageDomain
        )
    }

    private func relationForRoute(
        _ route: PathRoute?,
        spec: KeyPathSpec,
        canonicalPath: String,
        binding: EntityAnchorBinding?
    ) -> EntityAnchorBinding.CellBinding? {
        guard let binding else {
            return nil
        }

        if let route {
            return binding.cellBinding(for: route.cellType, matching: canonicalPath)
        }

        return binding.cellBinding(for: spec.owner, matching: canonicalPath)
    }

    private func inferredOpenSpec(for canonicalPath: String, route: PathRoute?) -> KeyPathSpec {
        let owner = route?.cellType ?? "EntityAnchorCell"

        return KeyPathSpec(
            path: canonicalPath,
            typeRef: "haven.core#/OpenValue",
            owner: owner,
            visibilityClass: inferredVisibilityClass(for: canonicalPath, route: route),
            storageDomain: owner == "ChronicleCell" ? "chronicle-store" : nil
        )
    }

    private func inferredVisibilityClass(for canonicalPath: String, route: PathRoute?) -> PermissionClass {
        if canonicalPath.hasPrefix("#/representations") {
            return .aggregated
        }

        let routedPrefix = route?.prefix ?? ""
        if routedPrefix.hasPrefix("#/credentials") || routedPrefix.hasPrefix("#/proofs") || routedPrefix.hasPrefix("#/perspective") {
            return .consent
        }

        return .private
    }
}
