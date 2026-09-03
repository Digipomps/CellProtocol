// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  RadarVisualizationView.swift
//  CellApple
//
//  `Visualization(kind: "radar")`: a motion tracker, not a list. Concentric
//  range rings with metres on them, a sweep while scanning, blips that burn
//  bright when just heard and fade as they go quiet, and the nearest
//  distance as one large number — the thing you read from across the room.
//  Fed by the spec `RadarEntityLedger.radarSpec()` produces, so it knows
//  nothing about Bluetooth, UWB or the scanner.
//

import SwiftUI
import CellBase

struct RadarBlip: Identifiable, Equatable {
    var id: String
    var label: String
    var status: String
    var connected: Bool
    var x: Double
    var y: Double
    var strength: Double
    var distanceText: String
    var hasDirection: Bool
    var matchScore: Double
}

struct RadarVisualizationSpec: Equatable {
    var status: String
    var rangeMeters: Double
    var rings: [Double]
    var ringLabels: [String]
    var sweep: Bool
    var blips: [RadarBlip]
    var nearestText: String
    var selectedID: String?
    var connectedCount: Int

    static func decode(from value: ValueType?) -> RadarVisualizationSpec? {
        guard case let .object(object)? = value else { return nil }
        func text(_ key: String, _ fallback: String = "") -> String {
            if case let .string(value)? = object[key] { return value }
            return fallback
        }
        func number(_ key: String, _ fallback: Double = 0) -> Double {
            switch object[key] {
            case let .float(value)?: return value
            case let .integer(value)?: return Double(value)
            default: return fallback
            }
        }
        func flag(_ key: String) -> Bool { if case let .bool(value)? = object[key] { return value } else { return false } }
        let rings: [Double] = {
            guard case let .list(values)? = object["rings"] else { return [0.25, 0.5, 0.75, 1.0] }
            return values.compactMap { if case let .float(v) = $0 { return v } else { return nil } }
        }()
        let ringLabels: [String] = {
            guard case let .list(values)? = object["ringLabels"] else { return [] }
            return values.compactMap { if case let .string(v) = $0 { return v } else { return nil } }
        }()
        let blips: [RadarBlip] = {
            guard case let .list(values)? = object["blips"] else { return [] }
            return values.compactMap { item in
                guard case let .object(blip) = item, case let .string(id)? = blip["id"] else { return nil }
                func btext(_ key: String, _ fallback: String = "") -> String { if case let .string(v)? = blip[key] { return v } else { return fallback } }
                func bnum(_ key: String, _ fallback: Double = 0) -> Double {
                    switch blip[key] { case let .float(v)?: return v; case let .integer(v)?: return Double(v); default: return fallback }
                }
                func bflag(_ key: String) -> Bool { if case let .bool(v)? = blip[key] { return v } else { return false } }
                return RadarBlip(
                    id: id, label: btext("label", id), status: btext("status", "found"), connected: bflag("connected"),
                    x: bnum("x"), y: bnum("y"), strength: bnum("strength", 1), distanceText: btext("distanceText", "—"),
                    hasDirection: bflag("hasDirection"), matchScore: bnum("matchScore")
                )
            }
        }()
        return RadarVisualizationSpec(
            status: text("status", "idle"),
            rangeMeters: number("rangeMeters", 8),
            rings: rings,
            ringLabels: ringLabels,
            sweep: flag("sweep"),
            blips: blips,
            nearestText: text("nearestText", "--.-"),
            selectedID: { if case let .string(v)? = object["selectedID"] { return v } else { return nil } }(),
            connectedCount: Int(number("connectedCount"))
        )
    }
}

struct VisualizationRadarView: View {
    var spec: RadarVisualizationSpec
    var selection: VisualizationSelectionState
    var activateBlip: ((ValueType, Int, String?, String?) -> Void)?

    private let phosphor = Color(red: 0.55, green: 1.0, blue: 0.62)
    private let phosphorDim = Color(red: 0.25, green: 0.62, blue: 0.36)
    private let ground = Color(red: 0.015, green: 0.055, blue: 0.045)

    private var selectedID: String? {
        selection.selectedID ?? spec.selectedID
    }

    var body: some View {
        VStack(spacing: 10) {
            readout
            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                let radius = side * 0.46
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                ZStack {
                    Circle()
                        .fill(RadialGradient(
                            colors: [Color(red: 0.03, green: 0.16, blue: 0.11), ground],
                            center: .center, startRadius: 6, endRadius: side * 0.5
                        ))
                        .frame(width: radius * 2, height: radius * 2)
                    rings(center: center, radius: radius)
                    ticks(center: center, radius: radius)
                    if spec.sweep {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                            let period = 3.2
                            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                            RadarSweepShape(angle: .radians(phase * 2 * .pi - .pi / 2), width: .degrees(28))
                                .fill(AngularGradient(
                                    colors: [phosphor.opacity(0.0), phosphor.opacity(0.42)],
                                    center: .center,
                                    startAngle: .radians(phase * 2 * .pi - .pi / 2 - 0.5),
                                    endAngle: .radians(phase * 2 * .pi - .pi / 2 + 0.25)
                                ))
                                .frame(width: radius * 2, height: radius * 2)
                                .blur(radius: 1.2)
                                .clipShape(Circle())
                        }
                    }
                    ForEach(spec.blips) { blip in
                        blipView(blip, center: center, radius: radius)
                    }
                    Circle()
                        .fill(phosphor)
                        .frame(width: 7, height: 7)
                        .shadow(color: phosphor.opacity(0.8), radius: 5)
                    if spec.blips.isEmpty {
                        Text(spec.sweep ? "SØKER" : "STOPPET")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(phosphorDim)
                            .offset(y: radius * 0.55)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 260, maxHeight: 360)
            .aspectRatio(1, contentMode: .fit)
            legend
        }
        .padding(14)
        .background(ground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(phosphorDim.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Radar, \(spec.blips.count) enheter i nærheten")
    }

    // The large number. On the film it is the only thing anyone looks at.
    private var readout: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NÆRMESTE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(phosphorDim)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(spec.nearestText)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .foregroundStyle(phosphor)
                        .contentTransition(.numericText())
                        .shadow(color: phosphor.opacity(0.55), radius: 6)
                    Text("m")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(phosphorDim)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(spec.status.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(spec.sweep ? phosphor : phosphorDim)
                Text("\(spec.blips.count) SIGNAL · \(spec.connectedCount) KOBLET")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(phosphorDim)
                Text(String(format: "REKKEVIDDE %.0f m", spec.rangeMeters))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(phosphorDim)
            }
        }
    }

    private func rings(center: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            ForEach(Array(spec.rings.enumerated()), id: \.offset) { index, ring in
                Circle()
                    .stroke(phosphorDim.opacity(ring >= 0.99 ? 0.8 : 0.4), lineWidth: ring >= 0.99 ? 1.2 : 0.8)
                    .frame(width: radius * 2 * ring, height: radius * 2 * ring)
                if index < spec.ringLabels.count {
                    Text(spec.ringLabels[index])
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(phosphorDim)
                        .position(x: center.x + 4, y: center.y - radius * ring + 8)
                }
            }
            Path { path in
                path.move(to: CGPoint(x: center.x - radius, y: center.y))
                path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                path.move(to: CGPoint(x: center.x, y: center.y - radius))
                path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            }
            .stroke(phosphorDim.opacity(0.35), style: StrokeStyle(lineWidth: 0.8, dash: [3, 4]))
        }
    }

    private func ticks(center: CGPoint, radius: CGFloat) -> some View {
        Path { path in
            for degree in stride(from: 0, to: 360, by: 10) {
                let angle = Double(degree) * .pi / 180 - .pi / 2
                let long = degree % 30 == 0
                let inner = radius - (long ? 9 : 5)
                path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                path.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
            }
        }
        .stroke(phosphorDim.opacity(0.7), lineWidth: 1)
    }

    private func blipView(_ blip: RadarBlip, center: CGPoint, radius: CGFloat) -> some View {
        let isSelected = blip.id == selectedID
        let point = CGPoint(x: center.x + blip.x * radius, y: center.y + blip.y * radius)
        let alpha = blip.status == "lost" ? 0.25 : max(0.3, blip.strength)
        let size: CGFloat = blip.connected ? 13 : 10
        return ZStack {
            if isSelected {
                Circle()
                    .stroke(phosphor.opacity(0.9), lineWidth: 1.2)
                    .frame(width: size + 14, height: size + 14)
            }
            if !blip.hasDirection {
                // Bearing unknown: draw the arc the entity could be on, so a
                // guessed angle is never mistaken for a measured one.
                Circle()
                    .trim(from: 0.42, to: 0.58)
                    .stroke(phosphorDim.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .frame(width: hypot(blip.x, blip.y) * radius * 2, height: hypot(blip.x, blip.y) * radius * 2)
                    .rotationEffect(.radians(atan2(blip.y, blip.x) - .pi))
                    .position(center)
            }
            Circle()
                .fill(phosphor.opacity(alpha))
                .frame(width: size, height: size)
                .shadow(color: phosphor.opacity(alpha * 0.9), radius: blip.connected ? 8 : 5)
                .position(point)
            Text(isSelected || blip.connected ? "\(blip.label) · \(blip.distanceText)" : blip.distanceText)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(phosphor.opacity(min(1, alpha + 0.3)))
                .lineLimit(1)
                .position(x: point.x, y: point.y + size + 4)
        }
        .contentShape(Circle().size(width: size + 20, height: size + 20))
        .onTapGesture {
            activateBlip?(.string(blip.id), spec.blips.firstIndex(of: blip) ?? 0, blip.id, blip.label)
        }
        .accessibilityLabel("\(blip.label), \(blip.distanceText), \(blip.status)")
        .accessibilityAddTraits(.isButton)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: phosphor, text: "koblet", filled: true)
            legendItem(color: phosphor.opacity(0.6), text: "hørt nylig", filled: true)
            legendItem(color: phosphor.opacity(0.25), text: "mistet", filled: true)
            Spacer()
            Text("stiplet bue = retning ukjent")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(phosphorDim)
        }
    }

    private func legendItem(color: Color, text: String, filled: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 9, design: .monospaced)).foregroundStyle(phosphorDim)
        }
    }
}
