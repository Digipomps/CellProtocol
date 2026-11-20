// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Spec for `SkeletonVisualization(kind: "argumentmap")`: an argument map
/// (argumentkart) with conclusions on the first row and each claim placed
/// below the claim it supports, attacks or rebuts.
///
/// The renderer draws what the cell sends and never infers relations. The
/// layout is computed here, in CellBase, so the web renderer and CellApple
/// place every box in the same row and order. Contract:
/// `CellProtocolDocuments/Deliverables/PDD_dokument-argumentanalyse_2026-11-14/contract/argumentmap.v1.schema.json`.
public struct ArgumentMapVisualizationSpec: Codable, Equatable, Sendable {
    public static let kind = "argumentmap"
    public static let maximumNodes = 200
    public static let maximumEdges = 400

    public enum Role: String, Codable, CaseIterable, Sendable {
        case conclusion, premise, counter, rebuttal, assumption, context

        /// Norwegian label shown in the box title when the cell sends none.
        public var label: String {
            switch self {
            case .conclusion: return "Konklusjon"
            case .premise: return "Premiss"
            case .counter: return "Motargument"
            case .rebuttal: return "Tilbakevisning"
            case .assumption: return "Antakelse"
            case .context: return "Kontekst"
            }
        }
    }

    public enum Relation: String, Codable, CaseIterable, Sendable {
        case supports, attacks, rebuts, context

        public var label: String {
            switch self {
            case .supports: return "støtter"
            case .attacks: return "angriper"
            case .rebuts: return "tilbakeviser"
            case .context: return "kontekst"
            }
        }
    }

    public enum StatusTone: String, Codable, CaseIterable, Sendable {
        case neutral, warning, ok, alert
    }

    public struct Node: Codable, Equatable, Sendable {
        public var id: String
        public var role: Role
        public var title: String
        public var body: String?
        public var status: String?
        public var statusTone: StatusTone?
        public var detail: String?
        public var inferred: Bool

        public init(id: String, role: Role, title: String, body: String? = nil, status: String? = nil,
                    statusTone: StatusTone? = nil, detail: String? = nil, inferred: Bool = false) {
            self.id = id
            self.role = role
            self.title = title
            self.body = body
            self.status = status
            self.statusTone = statusTone
            self.detail = detail
            self.inferred = inferred
        }

        private enum CodingKeys: String, CodingKey { case id, role, title, body, status, statusTone, detail, inferred }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            // Unknown roles fall back to premise rather than failing the whole map.
            role = (try? c.decode(String.self, forKey: .role)).flatMap(Role.init(rawValue:)) ?? .premise
            title = (try? c.decode(String.self, forKey: .title)) ?? id
            body = try? c.decodeIfPresent(String.self, forKey: .body)
            status = try? c.decodeIfPresent(String.self, forKey: .status)
            statusTone = (try? c.decodeIfPresent(String.self, forKey: .statusTone)).flatMap { $0 }.flatMap(StatusTone.init(rawValue:))
            detail = try? c.decodeIfPresent(String.self, forKey: .detail)
            inferred = ((try? c.decodeIfPresent(Bool.self, forKey: .inferred)) ?? nil) ?? false
        }
    }

    public struct Edge: Codable, Equatable, Sendable {
        public var source: String
        public var target: String
        public var relation: Relation
        public var label: String?
        public var inferred: Bool

        public init(source: String, target: String, relation: Relation, label: String? = nil, inferred: Bool = false) {
            self.source = source
            self.target = target
            self.relation = relation
            self.label = label
            self.inferred = inferred
        }

        /// The text drawn on the edge.
        public var displayLabel: String {
            if let label, !label.isEmpty { return label }
            return relation.label
        }

        private enum CodingKeys: String, CodingKey { case source, target, relation, label, inferred }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decode(String.self, forKey: .source)
            target = try c.decode(String.self, forKey: .target)
            relation = (try? c.decode(String.self, forKey: .relation)).flatMap(Relation.init(rawValue:)) ?? .context
            label = try? c.decodeIfPresent(String.self, forKey: .label)
            inferred = ((try? c.decodeIfPresent(Bool.self, forKey: .inferred)) ?? nil) ?? false
        }
    }

    /// Where a node is drawn: `row` 0 is the top row, `order` is the position
    /// in that row from the left, `rowCount` is how many nodes share the row.
    public struct Placement: Codable, Equatable, Sendable {
        public var id: String
        public var row: Int
        public var order: Int
        public var rowCount: Int
    }

    public var nodes: [Node]
    public var edges: [Edge]
    public var legend: String?
    public var selectedID: String?
    public var revision: String?

    public init(nodes: [Node], edges: [Edge], legend: String? = nil, selectedID: String? = nil, revision: String? = nil) {
        self.nodes = nodes
        self.edges = edges
        self.legend = legend
        self.selectedID = selectedID
        self.revision = revision
    }

    /// Decodes a spec and normalizes it: duplicate node ids keep the first,
    /// edges to unknown nodes and self-loops are dropped, and both lists are
    /// capped. Returns nil when the value is not an object with `nodes`.
    public static func decode(from value: ValueType?) -> ArgumentMapVisualizationSpec? {
        guard let value, let data = try? JSONEncoder().encode(value),
              let raw = try? JSONDecoder().decode(ArgumentMapVisualizationSpec.self, from: data) else {
            return nil
        }
        return raw.normalized()
    }

    public func normalized() -> ArgumentMapVisualizationSpec {
        var seen = Set<String>()
        let keptNodes = nodes.filter { seen.insert($0.id).inserted }.prefix(Self.maximumNodes)
        let ids = Set(keptNodes.map(\.id))
        let keptEdges = edges.filter { ids.contains($0.source) && ids.contains($0.target) && $0.source != $0.target }
            .prefix(Self.maximumEdges)
        return ArgumentMapVisualizationSpec(nodes: Array(keptNodes), edges: Array(keptEdges), legend: legend,
                                            selectedID: selectedID, revision: revision)
    }

    public var valueType: ValueType? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(ValueType.self, from: data)
    }

    /// Deterministic layered layout, shared by every renderer.
    ///
    /// - Edges point from a claim (source) to the claim it acts on (target).
    /// - A node's row is the length of its longest outgoing path to a node
    ///   with no outgoing edges. Edges that would close a cycle are ignored
    ///   for layering (they are still drawn).
    /// - Row 0 keeps input order. Every lower row is ordered by the mean
    ///   order of its targets in the rows above, ties by input order.
    ///
    /// `Tests/CellBaseTests/Fixtures/ArgumentMapLayoutVectors.v1.json` holds
    /// the vectors the web renderer is tested against too.
    public func layout() -> [Placement] {
        let spec = normalized()
        let index = Dictionary(uniqueKeysWithValues: spec.nodes.enumerated().map { ($1.id, $0) })
        var outgoing: [String: [String]] = [:]
        for edge in spec.edges { outgoing[edge.source, default: []].append(edge.target) }

        var depth: [String: Int] = [:]
        var onStack = Set<String>()
        func rowOf(_ id: String) -> Int {
            if let known = depth[id] { return known }
            onStack.insert(id)
            var best = 0
            for target in outgoing[id] ?? [] where !onStack.contains(target) {
                best = max(best, rowOf(target) + 1)
            }
            onStack.remove(id)
            depth[id] = best
            return best
        }
        for node in spec.nodes { _ = rowOf(node.id) }

        let maxRow = depth.values.max() ?? 0
        var orderOf: [String: Double] = [:]
        var placements: [Placement] = []
        for row in 0...maxRow {
            let members = spec.nodes.filter { depth[$0.id] == row }
            let keyed = members.map { node -> (Node, Double, Int) in
                let targets = (outgoing[node.id] ?? []).compactMap { orderOf[$0] }
                let key = row == 0 || targets.isEmpty ? Double(index[node.id] ?? 0) : targets.reduce(0, +) / Double(targets.count)
                return (node, key, index[node.id] ?? 0)
            }
            // Row 0 and nodes without placed targets sort by input order; others by barycenter.
            let sorted = keyed.sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.2 < rhs.2
            }
            for (position, entry) in sorted.enumerated() {
                orderOf[entry.0.id] = Double(position)
                placements.append(Placement(id: entry.0.id, row: row, order: position, rowCount: sorted.count))
            }
        }
        return placements
    }
}
