// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

#if canImport(SwiftUI) && canImport(ImageIO) && (os(macOS) || os(iOS))

import CellBase
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Rendrer et skjelett til et bilde utenfor skjermen, saa native og web kan
/// sammenlignes paa lik flate.
///
/// Motparten er playwright med `deviceScaleFactor` lik `Surface.scale` og et
/// viewport lik `Surface.width` x `Surface.height`. Begge sider maa faa samme
/// normaliserte JSON inn; se `SkeletonStyleParity`.
///
/// Maalet er ikke null avvik. Web og native rasteriserer tekst ulikt uansett -
/// subpiksel-posisjonering, hinting og gamma-korrigert blending gir noen faa
/// verdiers forskjell paa glyfkanter selv med samme skrift i samme stoerrelse.
/// Maalet er at *geometrien* stemmer og at avviket ellers holder seg til de
/// kantene.
@available(macOS 13.0, iOS 16.0, *)
public enum SkeletonParityRenderer {

    public struct Surface: Equatable, Sendable {
        public var width: CGFloat
        public var height: CGFloat
        /// 2 tilsvarer @2x og playwrights `deviceScaleFactor: 2`.
        public var scale: CGFloat
        public var isDarkMode: Bool
        /// Tegnes under skjelettet, saa gjennomsiktige omraader blir
        /// deterministiske i stedet for udefinerte.
        public var backgroundHex: String

        public init(
            width: CGFloat,
            height: CGFloat,
            scale: CGFloat = 2,
            isDarkMode: Bool = false,
            backgroundHex: String = "#FFFFFF"
        ) {
            self.width = width
            self.height = height
            self.scale = scale
            self.isDarkMode = isDarkMode
            self.backgroundHex = backgroundHex
        }
    }

    public enum RenderError: Error, LocalizedError {
        case decodingFailed(underlying: Error)
        case rasterizationFailed
        case encodingFailed

        public var errorDescription: String? {
            switch self {
            case .decodingFailed(let underlying):
                return "Kunne ikke dekode skjelettet: \(underlying)"
            case .rasterizationFailed:
                return "ImageRenderer ga ingen CGImage"
            case .encodingFailed:
                return "Kunne ikke kode bildet som PNG"
            }
        }
    }

    public struct Result: Sendable {
        public let png: Data
        public let pixelWidth: Int
        public let pixelHeight: Int
        /// Style-tokens som ble fjernet fordi de mangler felles kontrakt.
        /// Er denne ikke tom, maaler du en flate der de to rendrerne uansett
        /// ikke er enige - og tallet under maa leses med det i mente.
        public let strippedStyleTokens: [SkeletonStyleParity.Finding]
    }

    /// Rendrer skjelett-JSON til PNG.
    ///
    /// `defaultsSuiteName` finnes fordi `SkeletonElementView` bruker
    /// `@AppStorage`. Uten en egen suite leser rendringen brukerens lagrede
    /// verdier, og to kjoeringer kan gi ulikt bilde uten at noe er endret.
    /// Suiten toemmes foer rendring.
    @MainActor
    public static func renderPNG(
        skeletonJSON: Data,
        surface: Surface,
        normalizeStyleTokens: Bool = true,
        defaultsSuiteName: String = "haven.skeleton.parity"
    ) throws -> Result {

        var payload = skeletonJSON
        var findings: [SkeletonStyleParity.Finding] = []
        if normalizeStyleTokens {
            let normalized = try SkeletonStyleParity.normalizedForParity(jsonData: skeletonJSON)
            payload = normalized.normalized
            findings = normalized.findings
        }

        let element: SkeletonElement
        do {
            element = try JSONDecoder().decode(SkeletonElement.self, from: payload)
        } catch {
            throw RenderError.decodingFailed(underlying: error)
        }

        let defaults = UserDefaults(suiteName: defaultsSuiteName) ?? .standard
        defaults.removePersistentDomain(forName: defaultsSuiteName)

        let content = SkeletonView(element: element, showsKeyboardToolbar: false)
            .environmentObject(PortholeViewModel())
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, surface.isDarkMode ? .dark : .light)
            .frame(width: surface.width, height: surface.height, alignment: .topLeading)
            .background(parityBackgroundColor(surface.backgroundHex))

        let renderer = ImageRenderer(content: content)
        renderer.scale = surface.scale
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: surface.width, height: surface.height)

        guard let cgImage = renderer.cgImage else {
            throw RenderError.rasterizationFailed
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw RenderError.encodingFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.encodingFailed
        }

        return Result(
            png: data as Data,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            strippedStyleTokens: findings
        )
    }
}

/// Egen hex-tolkning med vilje: `Color(hex:)` i SkeletonView.swift ligger i en
/// `private extension` og er ikke synlig herfra. Bare bakgrunnsflaten bruker
/// denne - selve skjelettets farger tolkes av rendreren som vanlig.
@available(macOS 13.0, iOS 16.0, *)
private func parityBackgroundColor(_ hex: String) -> Color {
    var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6 || value.count == 8, let raw = UInt64(value, radix: 16) else {
        return Color.white
    }
    let hasAlpha = value.count == 8
    let r = Double((raw >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
    let g = Double((raw >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
    let b = Double((raw >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
    let a = hasAlpha ? Double(raw & 0xFF) / 255 : 1
    return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
}

#endif
