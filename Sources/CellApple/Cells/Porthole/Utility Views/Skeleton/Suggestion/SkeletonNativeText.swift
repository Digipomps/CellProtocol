// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase
import CoreText
#if os(macOS)
import AppKit
private typealias NativeFont = NSFont
private typealias NativeColor = NSColor
#else
import UIKit
private typealias NativeFont = UIFont
private typealias NativeColor = UIColor
#endif

private struct NativeTextColorKey: EnvironmentKey { static let defaultValue: Color? = nil }
private struct NativeTypographyKey: EnvironmentKey { static let defaultValue = SkeletonModifiers() }
extension EnvironmentValues {
    var skeletonNativeTextColor: Color? {
        get { self[NativeTextColorKey.self] } set { self[NativeTextColorKey.self] = newValue }
    }
    var skeletonInheritedTypography: SkeletonModifiers {
        get { self[NativeTypographyKey.self] } set { self[NativeTypographyKey.self] = newValue }
    }
}

extension SkeletonModifiers {
    func inheritingTypography(_ parent: SkeletonModifiers) -> SkeletonModifiers {
        var value = self
        value.fontFamilies = fontFamilies ?? parent.fontFamilies
        value.fontSize = fontSize ?? parent.fontSize
        value.fontStyle = fontStyle ?? parent.fontStyle
        value.fontWeight = fontWeight ?? parent.fontWeight
        value.letterSpacing = letterSpacing ?? parent.letterSpacing
        value.lineHeightMultiple = lineHeightMultiple ?? parent.lineHeightMultiple
        value.numericVariant = numericVariant ?? parent.numericVariant
        value.textDecoration = textDecoration ?? parent.textDecoration
        return value
    }
}

struct SkeletonNativeButtonLabel: View {
    let label: String
    let modifiers: SkeletonModifiers?
    @Environment(\.skeletonInheritedTypography) private var inherited
    var body: some View {
        let m = (modifiers ?? .init()).inheritingTypography(inherited)
        if m.lineHeightMultiple != nil || m.fontFamilies?.isEmpty == false || m.numericVariant == .proportional {
            SkeletonNativeText(string: label, modifiers: m)
        } else {
            Text(label).tracking(m.letterSpacing ?? 0).underline(m.textDecoration == .underline)
        }
    }
}

enum SkeletonNativeTextAttributes {
    static func attributed(_ string: String, modifiers: SkeletonModifiers, color: Color?) -> NSAttributedString {
        let size = SkeletonNativeTypography.size(modifiers)
        let weight: NativeFont.Weight
        switch SkeletonNativeTypography.weightNumber(modifiers.fontWeight) {
        case 100: weight = .ultraLight; case 200: weight = .thin; case 300: weight = .light
        case 500: weight = .medium; case 600: weight = .semibold; case 700: weight = .bold
        case 800: weight = .heavy; case 900: weight = .black; default: weight = .regular
        }
        var font = SkeletonNativeTypography.family(modifiers.fontFamilies, size: size)
            .flatMap { NativeFont(name: $0, size: size) } ?? .systemFont(ofSize: size, weight: weight)
        if let numeric = modifiers.numericVariant {
            #if os(macOS)
            let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [
                [NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                 NSFontDescriptor.FeatureKey.selectorIdentifier: numeric == .tabular ? kMonospacedNumbersSelector : kProportionalNumbersSelector]
            ]])
            font = NSFont(descriptor: descriptor, size: size) ?? font
            #else
            let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [
                [UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                 UIFontDescriptor.FeatureKey.selector: numeric == .tabular ? kMonospacedNumbersSelector : kProportionalNumbersSelector]
            ]])
            font = UIFont(descriptor: descriptor, size: size)
            #endif
        }
        let paragraph = NSMutableParagraphStyle()
        if let multiple = modifiers.lineHeightMultiple {
            // Contract: fontSize × multiple is the line box, not extra spacing.
            paragraph.minimumLineHeight = size * multiple
            paragraph.maximumLineHeight = size * multiple
        }
        switch modifiers.multilineTextAlignment {
        case "center": paragraph.alignment = .center
        case "trailing": paragraph.alignment = .right
        default: paragraph.alignment = .natural
        }
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph, .kern: modifiers.letterSpacing ?? 0,
            .underlineStyle: modifiers.textDecoration == .underline ? NSUnderlineStyle.single.rawValue : 0
        ]
        if let color { attributes[.foregroundColor] = NativeColor(color) }
        return NSAttributedString(string: string, attributes: attributes)
    }
}

/// Platform text metrics are required for a specified line box. SwiftUI's
/// lineSpacing adds space *between* lines and cannot express this contract.
struct SkeletonNativeText: View {
    let string: String
    let modifiers: SkeletonModifiers
    @Environment(\.skeletonNativeTextColor) private var color
    var body: some View {
        SkeletonAttributedLabel(value: SkeletonNativeTextAttributes.attributed(string, modifiers: modifiers,
            color: color ?? Color(skeletonHex: modifiers.foregroundColor ?? "")), lineLimit: modifiers.lineLimit)
            .accessibilityLabel(Text(string))
    }
}

#if os(macOS)
/// Plain TextArea needs the same paragraph contract as display text. The
/// existing binding still owns submit/debounce and draft semantics.
struct SkeletonNativeParagraphEditor: NSViewRepresentable {
    @Binding var text: String
    let modifiers: SkeletonModifiers
    let focused: Bool
    let focusChanged: (Bool) -> Void
    @Environment(\.skeletonNativeTextColor) private var color
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let editor = NSTextView()
        editor.isRichText = false; editor.drawsBackground = false
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 5, height: 5)
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        let attributed = SkeletonNativeTextAttributes.attributed(text.isEmpty ? " " : text, modifiers: modifiers, color: color)
        let attributes = attributed.attributes(at: 0, effectiveRange: nil)
        let selection = editor.selectedRange()
        if editor.string != text { editor.string = text }
        editor.font = attributes[.font] as? NSFont
        editor.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        editor.typingAttributes = attributes
        editor.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: (text as NSString).length))
        let location = min(selection.location, (text as NSString).length)
        editor.setSelectedRange(NSRange(location: location, length: min(selection.length, (text as NSString).length - location)))
        if focused, let window = editor.window, window.firstResponder !== editor { window.makeFirstResponder(editor) }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SkeletonNativeParagraphEditor
        init(_ parent: SkeletonNativeParagraphEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focusChanged(true) }
        func textDidEndEditing(_ notification: Notification) { parent.focusChanged(false) }
    }
}

private struct SkeletonAttributedLabel: NSViewRepresentable {
    let value: NSAttributedString
    let lineLimit: Int?
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isSelectable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = value
        field.maximumNumberOfLines = lineLimit ?? 0
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? value.size().width
        nsView.preferredMaxLayoutWidth = width
        return nsView.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
    }
}
#else
private struct SkeletonAttributedLabel: UIViewRepresentable {
    let value: NSAttributedString
    let lineLimit: Int?
    func makeUIView(context: Context) -> UILabel { UILabel() }
    func updateUIView(_ label: UILabel, context: Context) { label.attributedText = value; label.numberOfLines = lineLimit ?? 0 }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        uiView.sizeThatFits(CGSize(width: proposal.width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    }
}
#endif
