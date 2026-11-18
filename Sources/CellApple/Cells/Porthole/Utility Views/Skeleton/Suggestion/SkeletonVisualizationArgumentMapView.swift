// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase

/// Native renderer for `kind: "argumentmap"`. Rows and order come from
/// `ArgumentMapVisualizationSpec.layout()` in CellBase, the same placement the
/// web renderer uses, so a claim sits in the same row and position on both.
/// Wide maps scroll horizontally instead of shrinking the boxes.
struct VisualizationArgumentMapView: View {
    let spec: ArgumentMapVisualizationSpec
    let selection: VisualizationSelectionState
    let activateNode: ((ValueType, Int, String?, String?) -> Void)?

    static let boxWidth: CGFloat = 200
    static let boxHeight: CGFloat = 92
    static let columnGap: CGFloat = 16
    static let rowGap: CGFloat = 72
    static let margin: CGFloat = 16

    private struct Box {
        let node: ArgumentMapVisualizationSpec.Node
        let index: Int
        let frame: CGRect
    }

    private var boxes: [String: Box] {
        let placements = spec.layout()
        let widest = placements.map(\.rowCount).max() ?? 1
        let canvasWidth = Self.canvasWidth(columns: widest)
        let nodeIndex = Dictionary(uniqueKeysWithValues: spec.nodes.enumerated().map { ($1.id, ($0, $1)) })
        var result: [String: Box] = [:]
        for placement in placements {
            guard let entry = nodeIndex[placement.id] else { continue }
            let (index, node) = entry
            let rowWidth = CGFloat(placement.rowCount) * Self.boxWidth + CGFloat(max(placement.rowCount - 1, 0)) * Self.columnGap
            let x = (canvasWidth - rowWidth) / 2 + CGFloat(placement.order) * (Self.boxWidth + Self.columnGap)
            let y = Self.margin + CGFloat(placement.row) * (Self.boxHeight + Self.rowGap)
            result[placement.id] = Box(node: node, index: index, frame: CGRect(x: x, y: y, width: Self.boxWidth, height: Self.boxHeight))
        }
        return result
    }

    static func canvasWidth(columns: Int) -> CGFloat {
        margin * 2 + CGFloat(columns) * boxWidth + CGFloat(max(columns - 1, 0)) * columnGap
    }

    var body: some View {
        let boxes = self.boxes
        let rows = (spec.layout().map(\.row).max() ?? 0) + 1
        let width = Self.canvasWidth(columns: spec.layout().map(\.rowCount).max() ?? 1)
        let height = Self.margin * 2 + CGFloat(rows) * Self.boxHeight + CGFloat(rows - 1) * Self.rowGap
        VStack(alignment: .leading, spacing: 8) {
            if let legend = spec.legend, legend.isEmpty == false {
                Text(legend)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(spec.edges.enumerated()), id: \.offset) { _, edge in
                        if let source = boxes[edge.source], let target = boxes[edge.target] {
                            ArgumentMapEdgeView(edge: edge, from: source.frame, to: target.frame)
                        }
                    }
                    ForEach(spec.nodes, id: \.id) { node in
                        if let box = boxes[node.id] {
                            ArgumentMapBoxView(node: node, selected: selection.contains(id: node.id, index: box.index))
                                .frame(width: box.frame.width, height: box.frame.height)
                                .position(x: box.frame.midX, y: box.frame.midY)
                                .onTapGesture {
                                    activateNode?(.object(["id": .string(node.id), "selectedID": .string(node.id)]), box.index, node.id, node.title)
                                }
                        }
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
            }
        }
    }
}

private enum ArgumentMapPalette {
    static func fill(_ role: ArgumentMapVisualizationSpec.Role) -> Color {
        switch role {
        case .conclusion: return Color(red: 0.996, green: 0.953, blue: 0.780)
        case .counter: return Color(red: 0.996, green: 0.949, blue: 0.949)
        case .rebuttal: return Color(red: 0.961, green: 0.953, blue: 1.0)
        case .premise, .assumption, .context: return Color(red: 0.937, green: 0.965, blue: 1.0)
        }
    }

    static func stroke(_ role: ArgumentMapVisualizationSpec.Role) -> Color {
        switch role {
        case .conclusion: return Color(red: 0.961, green: 0.620, blue: 0.043)
        case .counter: return Color(red: 0.973, green: 0.443, blue: 0.443)
        case .rebuttal: return Color(red: 0.655, green: 0.545, blue: 0.980)
        case .premise, .assumption, .context: return Color(red: 0.376, green: 0.647, blue: 0.980)
        }
    }

    static func edge(_ relation: ArgumentMapVisualizationSpec.Relation, inferred: Bool) -> Color {
        if inferred { return Color(red: 0.580, green: 0.639, blue: 0.722) }
        switch relation {
        case .supports: return Color(red: 0.020, green: 0.588, blue: 0.412)
        case .attacks: return Color(red: 0.863, green: 0.149, blue: 0.149)
        case .rebuts: return Color(red: 0.486, green: 0.227, blue: 0.929)
        case .context: return Color(red: 0.580, green: 0.639, blue: 0.722)
        }
    }

    static func tone(_ tone: ArgumentMapVisualizationSpec.StatusTone?) -> Color {
        switch tone {
        case .ok?: return Color(red: 0.059, green: 0.463, blue: 0.431)
        case .warning?: return Color(red: 0.706, green: 0.325, blue: 0.035)
        case .alert?: return Color(red: 0.863, green: 0.149, blue: 0.149)
        case .neutral?, nil: return Color(red: 0.392, green: 0.455, blue: 0.545)
        }
    }
}

private struct ArgumentMapBoxView: View {
    let node: ArgumentMapVisualizationSpec.Node
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.title)
                .font(.caption.weight(.bold))
                .lineLimit(1)
            if let body = node.body, body.isEmpty == false {
                Text(body)
                    .font(.caption)
                    .lineLimit(2)
            }
            if let status = node.status, status.isEmpty == false {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(ArgumentMapPalette.tone(node.statusTone))
                    .lineLimit(1)
            }
            if let detail = node.detail, detail.isEmpty == false {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Color(red: 0.090, green: 0.125, blue: 0.200))
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(ArgumentMapPalette.fill(node.role)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(ArgumentMapPalette.stroke(node.role),
                        style: StrokeStyle(lineWidth: selected || node.role == .conclusion ? 2 : 1, dash: node.inferred ? [6, 4] : []))
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// Edge from the top of the source box to the bottom of the target box, as a
/// cubic curve with an arrowhead and the relation label at its middle.
private struct ArgumentMapEdgeView: View {
    let edge: ArgumentMapVisualizationSpec.Edge
    let from: CGRect
    let to: CGRect

    var body: some View {
        let start = CGPoint(x: from.midX, y: from.minY)
        let end = CGPoint(x: to.midX, y: to.maxY)
        let bend = max(abs(start.y - end.y) / 2, 24)
        let color = ArgumentMapPalette.edge(edge.relation, inferred: edge.inferred)
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        ZStack {
            Path { path in
                path.move(to: start)
                path.addCurve(to: end,
                              control1: CGPoint(x: start.x, y: start.y - bend),
                              control2: CGPoint(x: end.x, y: end.y + bend))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: edge.inferred ? [6, 5] : []))
            Path { path in
                path.move(to: CGPoint(x: end.x - 6, y: end.y + 10))
                path.addLine(to: end)
                path.addLine(to: CGPoint(x: end.x + 6, y: end.y + 10))
                path.closeSubpath()
            }
            .fill(color)
            Text(edge.displayLabel)
                .font(.caption2)
                .foregroundStyle(color)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.85))
                .position(middle)
        }
    }
}
