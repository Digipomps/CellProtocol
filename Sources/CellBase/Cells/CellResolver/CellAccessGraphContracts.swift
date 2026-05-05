// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CellAccessGraphContract {
    public static let rootKeypath = "atlas.entityGraph"
    public static let stateKeypath = "\(rootKeypath).state"
    public static let syncRuntimeCellsKeypath = "\(rootKeypath).syncRuntimeCells"
    public static let queryKeypath = "\(rootKeypath).query"
    public static let mermaidKeypath = "\(rootKeypath).mermaid"

    public static let runtimeResolverSourceID = "source:runtime-resolver"
    public static let localScaffoldID = "scaffold:local"
}

public enum CellAccessGraphNodeKind: String, Codable, Sendable {
    case entityContext
    case identity
    case cell
    case scaffold
    case proof
    case source
}

public struct CellAccessGraphNode: Codable, Equatable, Sendable {
    public var id: String
    public var kind: CellAccessGraphNodeKind
    public var label: String?
    public var visibility: String
    public var domain: String?
    public var sourceRef: String?
    public var payloadHash: String?
    public var payloadJSON: String?
    public var firstSeenAt: Date
    public var lastSeenAt: Date

    public init(
        id: String,
        kind: CellAccessGraphNodeKind,
        label: String? = nil,
        visibility: String = "private",
        domain: String? = nil,
        sourceRef: String? = nil,
        payloadHash: String? = nil,
        payloadJSON: String? = nil,
        firstSeenAt: Date,
        lastSeenAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.visibility = visibility
        self.domain = domain
        self.sourceRef = sourceRef
        self.payloadHash = payloadHash
        self.payloadJSON = payloadJSON
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }
}

public enum CellAccessGraphEdgeKind: String, Codable, Sendable {
    case ownsCell
    case hasAccessToCell
    case sameEntityAs
    case runsOnScaffold
    case publishesProjection
    case referencesCell
    case derivedFromAgreement
    case observedViaFlow
    case authorizedByGrant
    case revokedBy
}

public struct CellAccessGraphEdge: Codable, Equatable, Sendable {
    public var id: String
    public var fromNodeID: String
    public var toNodeID: String
    public var kind: CellAccessGraphEdgeKind
    public var scope: String
    public var confidence: Double
    public var sourceRef: String?
    public var proofRef: String?
    public var observedAt: Date
    public var expiresAt: Date?
    public var revokedAt: Date?
    public var payloadJSON: String?

    public init(
        id: String,
        fromNodeID: String,
        toNodeID: String,
        kind: CellAccessGraphEdgeKind,
        scope: String = "local",
        confidence: Double = 1,
        sourceRef: String? = nil,
        proofRef: String? = nil,
        observedAt: Date,
        expiresAt: Date? = nil,
        revokedAt: Date? = nil,
        payloadJSON: String? = nil
    ) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.kind = kind
        self.scope = scope
        self.confidence = confidence
        self.sourceRef = sourceRef
        self.proofRef = proofRef
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.payloadJSON = payloadJSON
    }
}

public struct CellAccessGraphProof: Codable, Equatable, Sendable {
    public var id: String
    public var proofType: String
    public var issuerPublicKey: String?
    public var subjectPublicKey: String?
    public var payloadHash: String
    public var payloadJSON: String
    public var verifiedAt: Date?
    public var revokedAt: Date?

    public init(
        id: String,
        proofType: String,
        issuerPublicKey: String? = nil,
        subjectPublicKey: String? = nil,
        payloadHash: String,
        payloadJSON: String,
        verifiedAt: Date? = nil,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.proofType = proofType
        self.issuerPublicKey = issuerPublicKey
        self.subjectPublicKey = subjectPublicKey
        self.payloadHash = payloadHash
        self.payloadJSON = payloadJSON
        self.verifiedAt = verifiedAt
        self.revokedAt = revokedAt
    }
}

public struct CellAccessGraphSource: Codable, Equatable, Sendable {
    public var id: String
    public var sourceType: String
    public var endpoint: String?
    public var scaffoldDomain: String?
    public var trustLevel: String
    public var lastSyncAt: Date?

    public init(
        id: String,
        sourceType: String,
        endpoint: String? = nil,
        scaffoldDomain: String? = nil,
        trustLevel: String,
        lastSyncAt: Date? = nil
    ) {
        self.id = id
        self.sourceType = sourceType
        self.endpoint = endpoint
        self.scaffoldDomain = scaffoldDomain
        self.trustLevel = trustLevel
        self.lastSyncAt = lastSyncAt
    }
}

public struct CellAccessGraphEvent: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var occurredAt: Date
    public var payloadJSON: String

    public init(id: String, kind: String, occurredAt: Date, payloadJSON: String) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.payloadJSON = payloadJSON
    }
}

public struct CellAccessGraphSnapshot: Codable, Equatable, Sendable {
    public var nodes: [CellAccessGraphNode]
    public var edges: [CellAccessGraphEdge]
    public var proofs: [CellAccessGraphProof]
    public var sources: [CellAccessGraphSource]

    public init(
        nodes: [CellAccessGraphNode],
        edges: [CellAccessGraphEdge],
        proofs: [CellAccessGraphProof],
        sources: [CellAccessGraphSource]
    ) {
        self.nodes = nodes
        self.edges = edges
        self.proofs = proofs
        self.sources = sources
    }
}

public struct CellAccessGraphQueryRequest: Codable, Hashable, Sendable {
    public var cluster: String
    public var includeRevoked: Bool
    public var limit: Int

    public static let `default` = CellAccessGraphQueryRequest(cluster: "all", includeRevoked: false, limit: 200)

    public init(cluster: String = "all", includeRevoked: Bool = false, limit: Int = 200) {
        self.cluster = cluster
        self.includeRevoked = includeRevoked
        self.limit = limit
    }
}

public struct CellAccessGraphRuntimeMaterialization: Equatable, Sendable {
    public var sources: [CellAccessGraphSource]
    public var nodes: [CellAccessGraphNode]
    public var edges: [CellAccessGraphEdge]
    public var events: [CellAccessGraphEvent]
    public var registeredCellTypes: Int
    public var activeCells: Int
    public var persistentCellTypes: Int
    public var remoteScaffolds: Int

    public init(
        sources: [CellAccessGraphSource],
        nodes: [CellAccessGraphNode],
        edges: [CellAccessGraphEdge],
        events: [CellAccessGraphEvent],
        registeredCellTypes: Int,
        activeCells: Int,
        persistentCellTypes: Int,
        remoteScaffolds: Int
    ) {
        self.sources = sources
        self.nodes = nodes
        self.edges = edges
        self.events = events
        self.registeredCellTypes = registeredCellTypes
        self.activeCells = activeCells
        self.persistentCellTypes = persistentCellTypes
        self.remoteScaffolds = remoteScaffolds
    }
}

public enum CellAccessGraphRuntimeMaterializer {
    public static func materializeRuntimeCells(
        registry: CellResolverRegistrySnapshot,
        remoteRoutes: [String: RemoteCellHostRoute] = [:],
        requesterIdentityUUID: String? = nil,
        now: Date
    ) -> CellAccessGraphRuntimeMaterialization {
        let sourceID = CellAccessGraphContract.runtimeResolverSourceID
        let localScaffoldID = CellAccessGraphContract.localScaffoldID
        let requesterIdentityUUID = normalizedOptional(requesterIdentityUUID)

        var sources: [CellAccessGraphSource] = [
            CellAccessGraphSource(
                id: sourceID,
                sourceType: "runtimeResolver",
                endpoint: "cell:///EntityCellGraph",
                scaffoldDomain: "local",
                trustLevel: "local",
                lastSyncAt: now
            )
        ]
        var nodes: [CellAccessGraphNode] = [
            CellAccessGraphNode(
                id: sourceID,
                kind: .source,
                label: "Runtime resolver",
                visibility: "private",
                domain: "local",
                sourceRef: sourceID,
                payloadJSON: jsonObjectString([
                    "runtimeState": "source",
                    "sourceType": "runtimeResolver",
                    "endpoint": "cell:///EntityCellGraph"
                ]),
                firstSeenAt: now,
                lastSeenAt: now
            ),
            CellAccessGraphNode(
                id: localScaffoldID,
                kind: .scaffold,
                label: "Local scaffold",
                visibility: "private",
                domain: "local",
                sourceRef: sourceID,
                payloadJSON: jsonObjectString([
                    "runtimeState": "localScaffold",
                    "cluster": "local"
                ]),
                firstSeenAt: now,
                lastSeenAt: now
            )
        ]
        var edges: [CellAccessGraphEdge] = []

        var registeredCount = 0
        var persistentTypeCount = 0
        for resolve in registry.resolves {
            registeredCount += 1
            let isPersistent = String(describing: resolve.persistancy) == "persistant"
            if isPersistent { persistentTypeCount += 1 }
            let state = isPersistent ? "registeredPersistent" : "registeredEphemeral"
            let nodeID = registeredCellNodeID(resolve.name)
            let domainIdentityID = "identity:domain:\(safeKey(resolve.identityDomain))"
            nodes.append(
                CellAccessGraphNode(
                    id: domainIdentityID,
                    kind: .identity,
                    label: resolve.identityDomain,
                    visibility: "private",
                    domain: resolve.identityDomain,
                    sourceRef: sourceID,
                    payloadJSON: jsonObjectString([
                        "runtimeState": "identityDomain",
                        "identityDomain": resolve.identityDomain
                    ]),
                    firstSeenAt: now,
                    lastSeenAt: now
                )
            )
            nodes.append(
                CellAccessGraphNode(
                    id: nodeID,
                    kind: .cell,
                    label: resolve.name,
                    visibility: "private",
                    domain: resolve.identityDomain,
                    sourceRef: sourceID,
                    payloadJSON: jsonObjectString([
                        "runtimeState": state,
                        "cellName": resolve.name,
                        "cellType": resolve.cellType,
                        "cellScope": String(describing: resolve.cellScope),
                        "persistancy": String(describing: resolve.persistancy)
                    ]),
                    firstSeenAt: now,
                    lastSeenAt: now
                )
            )
            edges.append(
                CellAccessGraphEdge(
                    id: "edge:runs:\(nodeID):\(localScaffoldID)",
                    fromNodeID: nodeID,
                    toNodeID: localScaffoldID,
                    kind: .runsOnScaffold,
                    scope: "local",
                    sourceRef: sourceID,
                    observedAt: now
                )
            )
            edges.append(
                CellAccessGraphEdge(
                    id: "edge:grant:\(domainIdentityID):\(nodeID)",
                    fromNodeID: domainIdentityID,
                    toNodeID: nodeID,
                    kind: .authorizedByGrant,
                    scope: resolve.identityDomain,
                    sourceRef: sourceID,
                    observedAt: now
                )
            )
        }

        var activeCount = 0
        for instance in registry.sharedNamedInstances {
            activeCount += 1
            upsertActiveInstance(
                instanceName: instance.name,
                uuid: instance.uuid,
                identityUUID: nil,
                sourceID: sourceID,
                localScaffoldID: localScaffoldID,
                nodes: &nodes,
                edges: &edges,
                now: now
            )
        }
        for instance in registry.identityNamedInstances where shouldInclude(instanceIdentityUUID: instance.identityUUID, requesterIdentityUUID: requesterIdentityUUID) {
            activeCount += 1
            upsertActiveInstance(
                instanceName: instance.name,
                uuid: instance.uuid,
                identityUUID: instance.identityUUID,
                sourceID: sourceID,
                localScaffoldID: localScaffoldID,
                nodes: &nodes,
                edges: &edges,
                now: now
            )
        }

        for (host, route) in remoteRoutes.sorted(by: { $0.key < $1.key }) {
            let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let sourceRef = "source:remote:\(safeKey(normalizedHost))"
            let scaffoldID = "scaffold:\(safeKey(normalizedHost))"
            sources.append(
                CellAccessGraphSource(
                    id: sourceRef,
                    sourceType: "remoteCellHost",
                    endpoint: route.websocketEndpoint,
                    scaffoldDomain: normalizedHost,
                    trustLevel: "registeredRoute",
                    lastSyncAt: now
                )
            )
            nodes.append(
                CellAccessGraphNode(
                    id: sourceRef,
                    kind: .source,
                    label: normalizedHost,
                    visibility: "remote",
                    domain: normalizedHost,
                    sourceRef: sourceRef,
                    payloadJSON: jsonObjectString([
                        "runtimeState": "remoteKnown",
                        "sourceType": "remoteCellHost",
                        "endpoint": route.websocketEndpoint
                    ]),
                    firstSeenAt: now,
                    lastSeenAt: now
                )
            )
            nodes.append(
                CellAccessGraphNode(
                    id: scaffoldID,
                    kind: .scaffold,
                    label: normalizedHost,
                    visibility: "remote",
                    domain: normalizedHost,
                    sourceRef: sourceRef,
                    payloadJSON: jsonObjectString([
                        "runtimeState": "remoteKnown",
                        "websocketEndpoint": route.websocketEndpoint,
                        "schemePreference": String(describing: route.schemePreference)
                    ]),
                    firstSeenAt: now,
                    lastSeenAt: now
                )
            )
            edges.append(
                CellAccessGraphEdge(
                    id: "edge:remote-source:\(sourceRef):\(scaffoldID)",
                    fromNodeID: sourceRef,
                    toNodeID: scaffoldID,
                    kind: .referencesCell,
                    scope: "remote",
                    sourceRef: sourceRef,
                    observedAt: now
                )
            )
        }

        let event = CellAccessGraphEvent(
            id: "event:runtime-sync:\(Int(now.timeIntervalSince1970 * 1000))",
            kind: "runtimeCellSync",
            occurredAt: now,
            payloadJSON: jsonObjectString([
                "registeredCellTypes": registeredCount,
                "activeCells": activeCount,
                "persistentCellTypes": persistentTypeCount,
                "remoteScaffolds": remoteRoutes.count
            ])
        )

        return CellAccessGraphRuntimeMaterialization(
            sources: deduplicatedSources(sources),
            nodes: deduplicatedNodes(nodes),
            edges: deduplicatedEdges(edges),
            events: [event],
            registeredCellTypes: registeredCount,
            activeCells: activeCount,
            persistentCellTypes: persistentTypeCount,
            remoteScaffolds: remoteRoutes.count
        )
    }

    public static func registeredCellNodeID(_ name: String) -> String {
        "cell:registered:\(safeKey(name))"
    }

    public static func activeCellNodeID(uuid: String, fallbackName: String) -> String {
        let source = uuid.isEmpty ? fallbackName : uuid
        return "cell:active:\(safeKey(source))"
    }

    public static func endpoint(for name: String) -> String {
        if name.hasPrefix("cell:///") || name.contains("://") {
            return name
        }
        return "cell:///\(name)"
    }

    public static func safeKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { char in
                char.isLetter || char.isNumber || char == "-" || char == "_" || char == "." ? char : "_"
            }
            .reduce(into: "") { $0.append($1) }
    }

    public static func jsonObjectString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func upsertActiveInstance(
        instanceName: String,
        uuid: String,
        identityUUID: String?,
        sourceID: String,
        localScaffoldID: String,
        nodes: inout [CellAccessGraphNode],
        edges: inout [CellAccessGraphEdge],
        now: Date
    ) {
        let nodeID = activeCellNodeID(uuid: uuid, fallbackName: instanceName)
        nodes.append(
            CellAccessGraphNode(
                id: nodeID,
                kind: .cell,
                label: instanceName,
                visibility: "private",
                sourceRef: sourceID,
                payloadJSON: jsonObjectString([
                    "runtimeState": "active",
                    "cellName": instanceName,
                    "endpoint": endpoint(for: instanceName),
                    "uuid": uuid,
                    "identityUUID": identityUUID ?? ""
                ]),
                firstSeenAt: now,
                lastSeenAt: now
            )
        )
        edges.append(
            CellAccessGraphEdge(
                id: "edge:runs:\(nodeID):\(localScaffoldID)",
                fromNodeID: nodeID,
                toNodeID: localScaffoldID,
                kind: .runsOnScaffold,
                scope: "local",
                sourceRef: sourceID,
                observedAt: now
            )
        )
        let registeredID = registeredCellNodeID(instanceName)
        edges.append(
            CellAccessGraphEdge(
                id: "edge:instance-of:\(registeredID):\(nodeID)",
                fromNodeID: registeredID,
                toNodeID: nodeID,
                kind: .referencesCell,
                scope: "runtime",
                sourceRef: sourceID,
                observedAt: now
            )
        )
        if let identityUUID, !identityUUID.isEmpty {
            let identityID = "identity:\(safeKey(identityUUID))"
            nodes.append(
                CellAccessGraphNode(
                    id: identityID,
                    kind: .identity,
                    label: identityUUID,
                    visibility: "private",
                    sourceRef: sourceID,
                    payloadJSON: jsonObjectString([
                        "runtimeState": "activeIdentity",
                        "identityUUID": identityUUID
                    ]),
                    firstSeenAt: now,
                    lastSeenAt: now
                )
            )
            edges.append(
                CellAccessGraphEdge(
                    id: "edge:owns:\(identityID):\(nodeID)",
                    fromNodeID: identityID,
                    toNodeID: nodeID,
                    kind: .ownsCell,
                    scope: "identity",
                    sourceRef: sourceID,
                    observedAt: now
                )
            )
            edges.append(
                CellAccessGraphEdge(
                    id: "edge:access:\(identityID):\(nodeID)",
                    fromNodeID: identityID,
                    toNodeID: nodeID,
                    kind: .hasAccessToCell,
                    scope: "identity",
                    sourceRef: sourceID,
                    observedAt: now
                )
            )
        }
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func shouldInclude(instanceIdentityUUID: String?, requesterIdentityUUID: String?) -> Bool {
        guard let requesterIdentityUUID else { return true }
        return instanceIdentityUUID == requesterIdentityUUID
    }

    private static func deduplicatedNodes(_ nodes: [CellAccessGraphNode]) -> [CellAccessGraphNode] {
        var byID = [String: CellAccessGraphNode]()
        for node in nodes {
            byID[node.id] = node
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private static func deduplicatedEdges(_ edges: [CellAccessGraphEdge]) -> [CellAccessGraphEdge] {
        var byID = [String: CellAccessGraphEdge]()
        for edge in edges {
            byID[edge.id] = edge
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private static func deduplicatedSources(_ sources: [CellAccessGraphSource]) -> [CellAccessGraphSource] {
        var byID = [String: CellAccessGraphSource]()
        for source in sources {
            byID[source.id] = source
        }
        return byID.values.sorted { $0.id < $1.id }
    }
}
