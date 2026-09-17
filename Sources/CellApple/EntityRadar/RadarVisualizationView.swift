// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  RadarVisualizationView.swift
//  CellApple
//
//  `Visualization(kind: "radar")`: measured positions grouped on range rings,
//  with a searchable list for all detections and owner-selected public details.
//  Fed by the spec `RadarEntityLedger.radarSpec()` produces, so it knows
//  nothing about Bluetooth, UWB or the scanner.
//

import SwiftUI
import CellBase
import ImageIO

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
    var selectedAdvertisement: NearbyAdvertisement? = nil
    var advertisementStatus: String = ""

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
            rangeMeters: number("rangeMeters", 8).isFinite ? min(max(number("rangeMeters", 8), 1), 100_000) : 8,
            rings: rings,
            ringLabels: ringLabels,
            sweep: flag("sweep"),
            blips: blips,
            nearestText: text("nearestText", "--.-"),
            selectedID: { if case let .string(v)? = object["selectedID"] { return v } else { return nil } }(),
            connectedCount: Int(number("connectedCount").isFinite ? min(max(number("connectedCount"), 0), 100_000) : 0),
            selectedAdvertisement: {
                guard let value = object["selectedAdvertisement"],
                      let data = try? JSONEncoder().encode(value),
                      let ad = try? JSONDecoder().decode(NearbyAdvertisement.self, from: data),
                      (try? ad.validate()) != nil else { return nil }
                return ad
            }(),
            advertisementStatus: text("advertisementStatus")
        )
    }
}

/// Shared with the skeleton Visualization renderer; the native scanner uses the same surface.
public struct NearbyRadarSurface: View {
    private let value: ValueType
    private let onSelect: (String) -> Void
    public init(value: ValueType, onSelect: @escaping (String) -> Void) {
        self.value = value; self.onSelect = onSelect
    }
    public var body: some View {
        if let spec = RadarVisualizationSpec.decode(from: value) {
            RadarOverview(spec: spec, selectedID: spec.selectedID, onSelect: onSelect)
        } else { ProgressView("Henter radar …") }
    }
}

struct VisualizationRadarView: View {
    var spec: RadarVisualizationSpec
    var selection: VisualizationSelectionState
    var activateBlip: ((ValueType, Int, String?, String?) -> Void)?
    var body: some View {
        RadarOverview(spec: spec, selectedID: selection.selectedID ?? spec.selectedID) { id in
            guard let index = spec.blips.firstIndex(where: { $0.id == id }) else { return }
            activateBlip?(.string(id), index, id, spec.blips[index].label)
        }
    }
}

private struct RadarOverview: View {
    let spec: RadarVisualizationSpec
    let selectedID: String?
    let onSelect: (String) -> Void
    @State private var query = ""
    @State private var groupIDs: Set<String>?
    @State private var showingList = false
    @State private var onlyUnknown = false
    @State private var followed = Set<String>()
    @State private var onlyFollowed = false

    private var filtered: [RadarBlip] {
        spec.blips.filter {
            (query.isEmpty || $0.label.localizedCaseInsensitiveContains(query)) &&
            (!onlyFollowed || followed.contains($0.id))
        }
    }
    private var uncertain: [RadarBlip] { filtered.filter { !$0.hasDirection } }
    private var selected: RadarBlip? { spec.blips.first { $0.id == selectedID } }
    private var active: Bool { !["stopped", "idle"].contains(spec.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(active ? "Søker i nærheten" : "Scanner stoppet", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(spec.blips.count) enheter").monospacedDigit()
            }
            .font(.subheadline)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Søk blant treff", text: $query).textFieldStyle(.plain)
                    .accessibilityIdentifier("nearby.search")
                Toggle("Følger", isOn: $onlyFollowed).toggleStyle(.button)
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            GeometryReader { geometry in
                let size = geometry.size
                let radius = max(1, min(size.width, size.height) / 2 - 28)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let groups = RadarClustering.groups(filtered, radius: radius)
                ZStack {
                    Canvas { context, canvasSize in
                        for scale in [0.25, 0.5, 0.75, 1.0] {
                            let r = radius * scale
                            context.stroke(Path(ellipseIn: CGRect(x: center.x-r, y: center.y-r, width: r*2, height: r*2)),
                                           with: .color(.secondary.opacity(0.17)), lineWidth: 1)
                            context.draw(Text(String(format: "%.0f m", spec.rangeMeters * scale)).font(.caption2).foregroundColor(.secondary),
                                         at: CGPoint(x: center.x, y: center.y-r-8))
                        }
                    }
                    ForEach(groups) { group in
                        Button {
                            if group.members.count == 1 { onSelect(group.members[0].id) }
                            else { groupIDs = Set(group.members.map(\.id)); onlyUnknown = false; showingList = true }
                        } label: {
                            if group.members.count > 1 {
                                Text("\(group.members.count)").font(.caption.weight(.medium)).monospacedDigit()
                                    .frame(width: 34, height: 34)
                                    .background(Color.accentColor.opacity(0.15), in: Circle())
                                    .overlay(Circle().stroke(Color.accentColor.opacity(0.6)))
                            } else {
                                let node = group.members[0]
                                Circle().fill(Color.accentColor.opacity(node.status == "lost" ? 0.3 : 0.9))
                                    .frame(width: followed.contains(node.id) ? 12 : 8, height: followed.contains(node.id) ? 12 : 8)
                                    .padding(8)
                                    .overlay(Circle().stroke(node.id == selectedID ? Color.accentColor : .clear, lineWidth: 2))
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .position(x: center.x + group.x * radius, y: center.y + group.y * radius)
                        .accessibilityLabel(group.members.count == 1 ? group.members[0].label : "Åpne gruppe med \(group.members.count) enheter")
                    }
                    VStack(spacing: 4) {
                        Circle().fill(.primary).frame(width: 6, height: 6)
                        Text("Du").font(.caption2).foregroundStyle(.secondary)
                    }.position(x: center.x, y: center.y + 8).allowsHitTesting(false)
                    if groups.isEmpty {
                        Text(spec.blips.isEmpty ? (active ? "Venter på treff" : "Start scanneren for å finne enheter") : "Ingen målt posisjon i dette utvalget")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: max(80, size.width - 40))
                            .position(x: center.x, y: center.y + radius * 0.64)
                    }
                }
            }
            .frame(height: 320)
            .accessibilityIdentifier("nearby.radar")
            HStack {
                Button("\(uncertain.count) uten posisjon") { groupIDs = nil; onlyUnknown = true; showingList = true }
                Spacer()
                Button("Alle treff (\(filtered.count))") { groupIDs = nil; onlyUnknown = false; showingList = true }
            }.font(.subheadline).buttonStyle(.borderless)
            Text("Skala \(Int(spec.rangeMeters)) m · Avstand og retning vises bare når de er målt.")
                .font(.caption).foregroundStyle(.secondary)
            if let selected {
                Divider()
                HStack {
                    Text(spec.selectedAdvertisement?.displayName ?? selected.label).font(.headline)
                    Spacer()
                    Button(followed.contains(selected.id) ? "Slutt å følge" : "Følg") {
                        if followed.contains(selected.id) { followed.remove(selected.id) } else { followed.insert(selected.id) }
                    }.buttonStyle(.borderless)
                }
                if let ad = spec.selectedAdvertisement {
                    AdvertisementDetails(advertisement: ad)
                } else {
                    Text(spec.advertisementStatus.isEmpty ? "Ingen annonserte detaljer." : spec.advertisementStatus)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showingList) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(groupIDs == nil ? (onlyUnknown ? "Uten målt posisjon" : "Alle treff") : "Treff i gruppen").font(.headline)
                    Spacer()
                    Button("Ferdig") { showingList = false }
                }
                TextField("Søk blant treff", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered.filter { (groupIDs?.contains($0.id) ?? true) && (!onlyUnknown || !$0.hasDirection) }) { node in
                            Button {
                                onSelect(node.id); showingList = false
                            } label: {
                                HStack {
                                    Text(node.label)
                                    Spacer()
                                    Text(node.hasDirection ? node.distanceText : "Posisjon ukjent").foregroundStyle(.secondary)
                                }.padding(.vertical, 12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 280, idealWidth: 420, maxWidth: 560, minHeight: 320, idealHeight: 500)
        }
    }
}

private struct AdvertisementDetails: View {
    let advertisement: NearbyAdvertisement
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let data = advertisement.thumbnail,
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Bilde valgt av deltakeren")
            }
            entries("Formål", advertisement.purposes)
            entries("Interesser", advertisement.interests)
            Text(advertisement.scope == .nearby ? "Åpent for alle i nærheten · selvoppgitt" : "Delt etter vilkår: \(advertisement.accessAgreement?.title ?? "Agreement") · selvoppgitt")
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("nearby.advertisedDetails")
    }
    @ViewBuilder private func entries(_ title: String, _ values: [String: String]) -> some View {
        if !values.isEmpty {
            Text(title).font(.subheadline.weight(.medium))
            ForEach(values.keys.sorted(), id: \.self) { key in Text(values[key] ?? "").font(.subheadline) }
        }
    }
}
