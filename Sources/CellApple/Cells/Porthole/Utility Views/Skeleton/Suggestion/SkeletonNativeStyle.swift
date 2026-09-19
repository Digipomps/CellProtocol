// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension SkeletonInsets {
    var nativeInsets: EdgeInsets {
        EdgeInsets(top: top ?? 0, leading: leading ?? 0, bottom: bottom ?? 0, trailing: trailing ?? 0)
    }
}

enum SkeletonNativeTypography {
    static func weightNumber(_ value: String?) -> Int {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let names = ["ultralight": 100, "thin": 200, "light": 300, "regular": 400, "normal": 400,
                     "medium": 500, "semibold": 600, "bold": 700, "heavy": 800, "black": 900]
        if let weight = names[text] { return weight }
        if let weight = Int(text), (100...900).contains(weight), weight % 100 == 0 { return weight }
        return 400
    }
    static func weight(_ value: String?) -> Font.Weight {
        switch weightNumber(value) {
        case 100: return .ultraLight
        case 200: return .thin
        case 300: return .light
        case 500: return .medium
        case 600: return .semibold
        case 700: return .bold
        case 800: return .heavy
        case 900: return .black
        default: return .regular
        }
    }
    static func size(_ modifiers: SkeletonModifiers) -> Double {
        if let size = modifiers.fontSize { return size }
        #if os(macOS)
        let styles: [String: NSFont.TextStyle] = ["largeTitle": .largeTitle, "title": .title1, "title2": .title2,
            "title3": .title3, "headline": .headline, "subheadline": .subheadline, "body": .body,
            "callout": .callout, "footnote": .footnote, "caption": .caption1, "caption2": .caption2]
        return Double(NSFont.preferredFont(forTextStyle: styles[modifiers.fontStyle ?? "body"] ?? .body).pointSize)
        #else
        let styles: [String: UIFont.TextStyle] = ["largeTitle": .largeTitle, "title": .title1, "title2": .title2,
            "title3": .title3, "headline": .headline, "subheadline": .subheadline, "body": .body,
            "callout": .callout, "footnote": .footnote, "caption": .caption1, "caption2": .caption2]
        return Double(UIFont.preferredFont(forTextStyle: styles[modifiers.fontStyle ?? "body"] ?? .body).pointSize)
        #endif
    }
    static func family(_ families: [String]?, size: Double) -> String? {
        families?.first { name in
            #if os(macOS)
            NSFont(name: name, size: size) != nil
            #else
            UIFont(name: name, size: size) != nil
            #endif
        }
    }
    static func font(_ modifiers: SkeletonModifiers) -> Font? {
        guard modifiers.fontSize != nil || modifiers.fontFamilies != nil || modifiers.fontStyle != nil || modifiers.numericVariant != nil else { return nil }
        if modifiers.fontSize == nil, modifiers.fontFamilies == nil, modifiers.numericVariant == nil, let style = modifiers.fontStyle {
            return fontFromStyle(style)
        }
        #if os(macOS)
        if modifiers.numericVariant != nil {
            let text = SkeletonNativeTextAttributes.attributed("0", modifiers: modifiers, color: nil)
            if let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { return Font(font) }
        }
        #endif
        let size = size(modifiers)
        if let family = family(modifiers.fontFamilies, size: size) {
            return .custom(family, size: size).weight(weight(modifiers.fontWeight))
        }
        return .system(size: size, weight: weight(modifiers.fontWeight))
    }
}

struct SkeletonNativeStyleModifier: ViewModifier {
    let modifiers: SkeletonModifiers
    var focusVisible: Bool? = nil
    @Environment(\.layoutDirection) private var direction
    @Environment(\.isFocused) private var focused
    @Environment(\.skeletonNativeElementID) private var elementID
    @Environment(\.skeletonNativeDragContext) private var drag
    @State private var hovered = false

    func body(content: Content) -> some View {
        if let drag {
            SkeletonDragStyledContent(content: content, modifiers: modifiers, hovered: hovered,
                focused: focusVisible ?? focused, elementID: elementID, drag: drag)
                .onHover { hovered = $0 }
        } else {
            styled(content, dragStyle: nil, accepting: false).onHover { hovered = $0 }
        }
    }

    private func styled(_ content: Content, dragStyle: SkeletonInteractionStyle?, accepting: Bool) -> some View {
        content.modifier(SkeletonNativeBoxStyle(modifiers: modifiers,
            interaction: interactionStyle(modifiers.interactionStyles, hovered: hovered, focused: focusVisible ?? focused, drag: dragStyle),
            accepting: accepting))
    }
}

private func interactionStyle(_ styles: SkeletonInteractionStyles?, hovered: Bool, focused: Bool,
                              drag: SkeletonInteractionStyle?) -> SkeletonInteractionStyle {
    var result = SkeletonInteractionStyle()
    for style in [hovered ? styles?.hover : nil, focused ? styles?.focusVisible : nil, drag] {
        result.background = style?.background ?? result.background
        result.foregroundColor = style?.foregroundColor ?? result.foregroundColor
        result.opacity = style?.opacity ?? result.opacity
    }
    return result
}

private struct SkeletonDragStyledContent<Content: View>: View {
    let content: Content
    let modifiers: SkeletonModifiers
    let hovered: Bool
    let focused: Bool
    let elementID: String
    @ObservedObject var drag: SkeletonNativeDragContext
    var body: some View {
        content.modifier(SkeletonNativeBoxStyle(modifiers: modifiers,
            interaction: interactionStyle(modifiers.interactionStyles, hovered: hovered, focused: focused,
                drag: modifiers.interactionStyles?.dragStyle(isSource: drag.isActive && drag.sourceID == elementID, isActive: drag.isActive)),
            accepting: modifiers.dropActionKeypath != nil && drag.accepts(modifiers.acceptedDragRoles)))
    }
}

private struct SkeletonNativeBoxStyle: ViewModifier {
    let modifiers: SkeletonModifiers
    let interaction: SkeletonInteractionStyle
    let accepting: Bool
    @Environment(\.layoutDirection) private var direction
    @Environment(\.skeletonInheritedTypography) private var inheritedTypography
    @Environment(\.font) private var inheritedFont
    @Environment(\.skeletonNativeTextColor) private var inheritedTextColor

    private var radius: CGFloat { modifiers.cornerRadius ?? 0 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius) }
    private var color: Color? { Color(skeletonHex: interaction.foregroundColor ?? modifiers.foregroundColor ?? "") ?? inheritedTextColor }

    func body(content: Content) -> some View {
        let m = modifiers
        let typography = content
            .environment(\.skeletonInheritedTypography, m.inheritingTypography(inheritedTypography))
            .environment(\.skeletonNativeTextColor, color)
            .font(SkeletonNativeTypography.font(m.inheritingTypography(inheritedTypography)) ?? inheritedFont)
            .fontWeight(m.fontWeight.map { SkeletonNativeTypography.weight($0) })
            .foregroundColor(color)
            .modifier(SkeletonNumericStyle(variant: m.numericVariant))
        let alignment = Alignment(horizontal: SkeletonNativeLayout.horizontalAlignment(m.hAlignment),
                                  vertical: SkeletonNativeLayout.verticalAlignment(m.vAlignment))
        let minWidth: CGFloat? = m.minWidth.map { CGFloat($0) }
        let minHeight: CGFloat? = m.minHeight.map { CGFloat($0) }
        let maxWidth: CGFloat? = m.maxWidthInfinity == true ? CGFloat.infinity : nil
        let maxHeight: CGFloat? = m.maxHeightInfinity == true ? CGFloat.infinity : m.maxHeight.map { CGFloat($0) }
        let width: CGFloat? = m.width.map { CGFloat($0) }
        let height: CGFloat? = m.height.map { CGFloat($0) }
        let box = typography
            .padding((m.paddingInsets ?? .init()).resolved(padding: m.padding).nativeInsets)
            .frame(minWidth: minWidth, maxWidth: maxWidth, minHeight: minHeight, maxHeight: maxHeight, alignment: alignment)
            .frame(width: width, height: height, alignment: alignment)
            .layoutValue(key: SkeletonFlexGrowKey.self, value: m.flexGrow ?? 0)
        let decorated = box
            .background(shape.fill(Color(skeletonHex: interaction.background ?? m.background ?? "") ?? .clear))
            .modifier(SkeletonContentClip(enabled: m.contentClip == true, radius: radius))
            .overlay(border)
            .background(shadow)
            .overlay(alignment: .leading) { marker }
        return decorated
            .overlay { if accepting { shape.stroke(Color.accentColor, lineWidth: 1).allowsHitTesting(false).accessibilityHidden(true) } }
            .opacity(m.hidden == true ? 0 : (interaction.opacity ?? m.opacity ?? 1))
            .accessibilityHidden(m.hidden == true)
            .allowsHitTesting(m.hidden != true)
            .rotationEffect(.degrees(m.textRotationDegrees ?? 0))
            .modifier(SkeletonControlStyleModifier(plain: m.controlStyle == .plain))
            .modifier(SkeletonAccessibleLabel(label: m.accessibilityLabel))
    }

    private var border: some View {
        let width = CGFloat(modifiers.borderWidth ?? 0)
        let dash: [CGFloat] = modifiers.borderStyle == .dashed ? [width * 3, width * 3]
            : modifiers.borderStyle == .dotted ? [width, width] : []
        return SkeletonBorderShape(radius: max(0, radius - width / 2), edges: modifiers.borderEdges, rtl: direction == .rightToLeft)
            .stroke(Color(skeletonHex: modifiers.borderColor ?? "#00000033") ?? .clear,
                    style: StrokeStyle(lineWidth: width, dash: dash))
            .padding(width / 2).allowsHitTesting(false).accessibilityHidden(true)
    }
    @ViewBuilder private var shadow: some View {
        if modifiers.shadowRadius != nil || modifiers.shadowSpread != nil {
            shape.inset(by: -(modifiers.shadowSpread ?? 0))
                .fill(Color(skeletonHex: modifiers.shadowColor ?? "#00000033") ?? .clear)
                .blur(radius: modifiers.shadowRadius ?? 0)
                .offset(x: modifiers.shadowX ?? 0, y: modifiers.shadowY ?? 0)
                .mask(SkeletonOutsideShape(radius: radius).fill(style: FillStyle(eoFill: true)))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    @ViewBuilder private var marker: some View {
        if let marker = modifiers.leadingMarker {
            RoundedRectangle(cornerRadius: marker.cornerRadius)
                .fill(Color(skeletonHex: marker.color) ?? .clear).frame(width: marker.width)
                .padding(.top, marker.insetTop).padding(.bottom, marker.insetBottom)
                .offset(x: marker.offset * (direction == .rightToLeft ? -1 : 1))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private struct SkeletonAccessibleLabel: ViewModifier {
    let label: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let label { content.accessibilityLabel(Text(label)) } else { content }
    }
}
private struct SkeletonControlStyleModifier: ViewModifier {
    let plain: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if plain { content.buttonStyle(.plain).textFieldStyle(.plain) } else { content }
    }
}
private struct SkeletonNumericStyle: ViewModifier {
    let variant: SkeletonNumericVariant?
    @ViewBuilder func body(content: Content) -> some View {
        if variant == .tabular { content.monospacedDigit() } else { content }
    }
}
private struct SkeletonContentClip: ViewModifier {
    let enabled: Bool
    let radius: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.clipShape(RoundedRectangle(cornerRadius: radius))
                .contentShape(RoundedRectangle(cornerRadius: radius))
        } else { content }
    }
}

private struct SkeletonOutsideShape: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -4096, dy: -4096))
        path.addPath(RoundedRectangle(cornerRadius: radius).path(in: rect))
        return path
    }
}

struct SkeletonBorderShape: Shape {
    let radius: CGFloat
    let edges: [SkeletonEdge]?
    let rtl: Bool
    func path(in rect: CGRect) -> Path {
        guard let edges, Set(edges.map(\.rawValue)).count < 4 else { return RoundedRectangle(cornerRadius: radius).path(in: rect) }
        var path = Path()
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        let tl = CGPoint(x: rect.minX + r, y: rect.minY + r)
        let tr = CGPoint(x: rect.maxX - r, y: rect.minY + r)
        let bl = CGPoint(x: rect.minX + r, y: rect.maxY - r)
        let br = CGPoint(x: rect.maxX - r, y: rect.maxY - r)
        for edge in edges {
            let physical: SkeletonEdge = rtl && edge == .leading ? .trailing : rtl && edge == .trailing ? .leading : edge
            var side = Path()
            switch physical {
            case .top:
                side.addArc(center: tl, radius: r, startAngle: .degrees(225), endAngle: .degrees(270), clockwise: false)
                side.addLine(to: CGPoint(x: tr.x, y: rect.minY))
                side.addArc(center: tr, radius: r, startAngle: .degrees(270), endAngle: .degrees(315), clockwise: false)
            case .trailing:
                side.addArc(center: tr, radius: r, startAngle: .degrees(315), endAngle: .degrees(360), clockwise: false)
                side.addLine(to: CGPoint(x: rect.maxX, y: br.y))
                side.addArc(center: br, radius: r, startAngle: .degrees(0), endAngle: .degrees(45), clockwise: false)
            case .bottom:
                side.addArc(center: br, radius: r, startAngle: .degrees(45), endAngle: .degrees(90), clockwise: false)
                side.addLine(to: CGPoint(x: bl.x, y: rect.maxY))
                side.addArc(center: bl, radius: r, startAngle: .degrees(90), endAngle: .degrees(135), clockwise: false)
            case .leading:
                side.addArc(center: bl, radius: r, startAngle: .degrees(135), endAngle: .degrees(180), clockwise: false)
                side.addLine(to: CGPoint(x: rect.minX, y: tl.y))
                side.addArc(center: tl, radius: r, startAngle: .degrees(180), endAngle: .degrees(225), clockwise: false)
            }
            path.addPath(side)
        }
        return path
    }
}

struct SkeletonFlexGrowKey: LayoutValueKey { static let defaultValue: Double = 0 }

/// Uses one stable Layout type across horizontal/vertical variants. Flex growth
/// distributes remaining space proportionally, without measuring via GeometryReader.
struct SkeletonLinearLayout: Layout {
    var axis: Axis
    var spacing: CGFloat
    var horizontal: HorizontalAlignment
    var vertical: VerticalAlignment
    var rtl: Bool = false

    private func sizes(_ proposal: ProposedViewSize, _ subviews: Subviews) -> [CGSize] {
        var sizes = subviews.map { $0.sizeThatFits(axis == .horizontal
            ? ProposedViewSize(width: nil, height: proposal.height)
            : ProposedViewSize(width: proposal.width, height: nil)) }
        let occupied = sizes.reduce(CGFloat(0)) { $0 + (axis == .horizontal ? $1.width : $1.height) } + spacing * CGFloat(max(0, subviews.count - 1))
        let available = (axis == .horizontal ? proposal.width : proposal.height) ?? occupied
        let total = subviews.reduce(0.0) { $0 + $1[SkeletonFlexGrowKey.self] }
        if total > 0, available > occupied {
            for i in sizes.indices {
                let extra = (available - occupied) * subviews[i][SkeletonFlexGrowKey.self] / total
                if axis == .horizontal { sizes[i].width += extra } else { sizes[i].height += extra }
            }
        }
        if axis == .horizontal {
            for index in sizes.indices {
                sizes[index].height = subviews[index].sizeThatFits(ProposedViewSize(width: sizes[index].width, height: proposal.height)).height
            }
        }
        return sizes
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = sizes(proposal, subviews)
        let main = sizes.reduce(CGFloat(0)) { $0 + (axis == .horizontal ? $1.width : $1.height) } + spacing * CGFloat(max(0, sizes.count - 1))
        var cross = sizes.map { axis == .horizontal ? $0.height : $0.width }.max() ?? 0
        if axis == .horizontal && (vertical == .firstTextBaseline || vertical == .lastTextBaseline) {
            let dimensions = subviews.indices.map { subviews[$0].dimensions(in: ProposedViewSize(sizes[$0])) }
            let above = dimensions.map { $0[vertical] }.max() ?? 0
            let below = dimensions.map { $0.height - $0[vertical] }.max() ?? 0
            cross = above + below
        }
        return axis == .horizontal ? CGSize(width: main, height: cross) : CGSize(width: cross, height: main)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(ProposedViewSize(bounds.size), subviews)
        let dimensions = subviews.indices.map { subviews[$0].dimensions(in: ProposedViewSize(sizes[$0])) }
        let baseline = dimensions.map { $0[vertical] }.max() ?? 0
        var cursor: CGFloat = 0
        for index in subviews.indices {
            let size = sizes[index]
            let point: CGPoint
            if axis == .horizontal {
                let y: CGFloat = vertical == .firstTextBaseline || vertical == .lastTextBaseline ? baseline - dimensions[index][vertical]
                    : vertical == .top ? 0 : vertical == .bottom ? bounds.height - size.height : (bounds.height - size.height) / 2
                point = CGPoint(x: rtl ? bounds.maxX - cursor - size.width : bounds.minX + cursor, y: bounds.minY + y)
                cursor += size.width + spacing
            } else {
                let x: CGFloat = horizontal == .trailing ? bounds.width - size.width : horizontal == .center ? (bounds.width - size.width) / 2 : 0
                point = CGPoint(x: rtl ? bounds.maxX - x - size.width : bounds.minX + x, y: bounds.minY + cursor)
                cursor += size.height + spacing
            }
            subviews[index].place(at: point, proposal: ProposedViewSize(size))
        }
    }
}
