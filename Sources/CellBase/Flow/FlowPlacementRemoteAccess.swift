// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// PDD_flow-plassering_2026-11-07, WP5/WP10: how a linked venue reaches a
// remote host. Moved here from HavenAgentD with FlowPlacementRunner.

public enum FlowPlacementRemoteHosts {
    public static let route = RemoteCellHostRoute(
        websocketEndpoint: "bridgehead", schemePreference: .wss,
        pathLayout: .endpointThenPublisherUUID, connectionSharing: .multiplexedV2)

    /// `HAVEN_FLOW_PLACEMENT_BRIDGE=dedicated` uses one socket per cell
    /// (`/bridgehead/<cell>/<bridge>`) instead of the multiplexed session,
    /// for hosts that only serve that route.
    public static var configuredRoute: RemoteCellHostRoute {
        guard ProcessInfo.processInfo.environment["HAVEN_FLOW_PLACEMENT_BRIDGE"] == "dedicated" else { return route }
        var dedicated = route
        dedicated.connectionSharing = .dedicated
        return dedicated
    }

    @discardableResult
    public static func registerIfNeeded(for endpoint: String, resolver: CellResolver) -> Bool {
        guard let url = URL(string: endpoint), url.scheme == "cell",
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
              resolver.remoteCellHostRoutesSnapshot()[host.lowercased()] == nil else {
            return false
        }
        resolver.registerRemoteCellHost(host, route: configuredRoute)
        return true
    }
}

/// Identity-proof scopes a remote host names for a linked venue's own operations
/// (PDD flow-plassering WP5). CellBase bridges sign an identity-origin challenge
/// only for scopes the local caller pinned. Palazzo's `link.complete` asks for
/// two proofs (the link cell and the approving actor's entity, where the
/// contract is issued), and an identity-unique entity is reachable by uuid only
/// after a proof for that exact cell. The approval names those scopes; the agent
/// accepts only scopes in a domain it requested itself, keeps them per host, and
/// pins exactly one scope when it later opens that cell.
public enum FlowPlacementProofScopes {
    public static let maximumScopes = 4

    /// Scopes from an approval response (`identityProofScopes`, also under `value`),
    /// limited to `allowedDomains` and to uuid resources.
    public static func scopes(fromApproval approval: ValueType, allowedDomains: [String]) -> [BridgeIdentityProofScope] {
        guard case var .object(object) = approval else { return [] }
        if case let .object(inner)? = object["value"] { object = inner }
        guard case let .list(values)? = object["identityProofScopes"] else { return [] }
        let domains = Set(allowedDomains)
        var scopes: [BridgeIdentityProofScope] = []
        for value in values {
            guard case let .object(entry) = value,
                  case let .string(domain)? = entry["domain"], domains.contains(domain),
                  case let .string(resource)? = entry["resource"], UUID(uuidString: resource) != nil else { continue }
            let scope = BridgeIdentityProofScope(domain: domain, resource: resource)
            if !scopes.contains(scope) { scopes.append(scope) }
        }
        return Array(scopes.prefix(maximumScopes))
    }

    /// `cell://<host>/<path>` as the bridgehead WebSocket URL the resolver uses
    /// (`wss://<host>/bridgehead/<path>`; the resolver appends the bridge id).
    public static func websocketURL(for endpoint: String, route: RemoteCellHostRoute = FlowPlacementRemoteHosts.route) -> String? {
        guard let url = URL(string: endpoint), url.scheme == "cell",
              let host = url.host, !host.isEmpty else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }
        let scheme = route.schemePreference == .ws ? "ws" : "wss"
        let portPart = url.port.map { ":\($0)" } ?? ""
        let routePath = route.websocketEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(scheme)://\(host)\(portPart)/\(routePath.isEmpty ? "" : routePath + "/")\(path)"
    }

    /// Host -> scopes, persisted next to the venue's state so a later run can
    /// open the linked cells.
    public struct Store: Sendable {
        public let fileURL: URL
        public init(fileURL: URL) { self.fileURL = fileURL }

        public struct Entry: Codable, Equatable, Sendable { var domain: String; var resource: String }

        public func record(host: String, scopes: [BridgeIdentityProofScope]) throws {
            guard !scopes.isEmpty else { return }
            var all = (try? load()) ?? [:]
            var entries = all[host.lowercased()] ?? []
            for scope in scopes where !entries.contains(Entry(domain: scope.domain, resource: scope.resource)) {
                entries.append(Entry(domain: scope.domain, resource: scope.resource))
            }
            all[host.lowercased()] = entries
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(all).write(to: fileURL, options: .atomic)
        }

        public func load() throws -> [String: [Entry]] {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
            return try JSONDecoder().decode([String: [Entry]].self, from: Data(contentsOf: fileURL))
        }

        /// The one scope recorded for `cell://<host>/<uuid>`, if any.
        public func scope(for endpoint: String) -> BridgeIdentityProofScope? {
            guard let url = URL(string: endpoint), url.scheme == "cell", let host = url.host?.lowercased() else { return nil }
            let resource = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard UUID(uuidString: resource) != nil,
                  let entry = ((try? load()) ?? [:])[host]?.first(where: { $0.resource == resource }) else { return nil }
            return BridgeIdentityProofScope(domain: entry.domain, resource: entry.resource)
        }
    }
}
