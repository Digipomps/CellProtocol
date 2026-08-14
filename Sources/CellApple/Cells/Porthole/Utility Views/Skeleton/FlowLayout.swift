// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI

/// A left-to-right, top-to-bottom flow layout: children wrap onto new rows
/// when they don't fit the available width, each sized to its own content
/// (not a fixed-track grid). Mirrors the web renderer's `flex-wrap: wrap`
/// behavior for elements with `SkeletonModifiers.wrap == true` (e.g. HStack
/// or List used for interest/tag chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: maxWidth.isFinite ? min(width, maxWidth) : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct RowItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let projectedWidth = currentRow.width + (currentRow.items.isEmpty ? 0 : spacing) + size.width
            if currentRow.items.isEmpty == false, maxWidth.isFinite, projectedWidth > maxWidth {
                rows.append(currentRow)
                currentRow = Row()
            }
            currentRow.width += (currentRow.items.isEmpty ? 0 : spacing) + size.width
            currentRow.height = max(currentRow.height, size.height)
            currentRow.items.append(RowItem(subview: subview, size: size))
        }
        if currentRow.items.isEmpty == false {
            rows.append(currentRow)
        }
        return rows
    }
}
