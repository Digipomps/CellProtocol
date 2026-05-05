// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase
#if canImport(MapKit)
import MapKit
#endif
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if os(macOS)
private typealias VisualizationMapEdgeInsets = NSEdgeInsets
#else
private typealias VisualizationMapEdgeInsets = UIEdgeInsets
#endif

struct VisualizationMapView: View {
    let visualizationKind: String
    let spec: MapVisualizationSpec
    let selection: VisualizationSelectionState
    let activateFeature: ((ValueType, Int, String?, String?) -> Void)?

    var body: some View {
        Group {
            switch spec.coordinateSpace {
            case .geospatial:
#if canImport(MapKit)
                VisualizationGeospatialMapView(
                    spec: spec,
                    selection: selection,
                    activateFeature: activateFeature
                )
#else
                mapFallback(message: "MapKit er ikke tilgjengelig på denne plattformen.")
#endif
            case .planar:
                VisualizationPlanarMapView(
                    spec: spec,
                    selection: selection,
                    activateFeature: activateFeature
                )
            }
        }
    }

    @ViewBuilder
    private func mapFallback(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(visualizationKind.capitalized)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.04))
        .cornerRadius(12)
    }
}

private struct VisualizationResolvedMapFeature: Identifiable {
    enum Shape {
        case point(MapVisualizationCoordinate)
        case polyline([MapVisualizationCoordinate])
        case polygon([MapVisualizationCoordinate])
    }

    let id: String
    let index: Int
    let label: String?
    let selectable: Bool
    let style: MapVisualizationStyle
    let geometry: Shape
    let raw: ValueType
}

private struct VisualizationResolvedPlanarScene {
    let bounds: MapVisualizationBounds
    let imageBase: MapVisualizationImageBase?
    let viewport: MapVisualizationViewport?
    let features: [VisualizationResolvedMapFeature]
    let signature: String
}

private func resolvedMapFeatures(from spec: MapVisualizationSpec) -> [VisualizationResolvedMapFeature] {
    spec.features.enumerated().map { index, feature in
        let shape: VisualizationResolvedMapFeature.Shape
        switch feature.geometry {
        case .point(let coordinate):
            shape = .point(coordinate)
        case .polyline(let coordinates):
            shape = .polyline(coordinates)
        case .polygon(let coordinates):
            shape = .polygon(coordinates)
        }
        return VisualizationResolvedMapFeature(
            id: feature.id,
            index: index,
            label: feature.label,
            selectable: feature.selectable ?? true,
            style: feature.style ?? MapVisualizationStyle(),
            geometry: shape,
            raw: mapFeaturePayload(feature, coordinateSpace: spec.coordinateSpace)
        )
    }
}

private func mapVisualizationSignature(for spec: MapVisualizationSpec) -> String {
    if let revision = spec.revision?.trimmingCharacters(in: .whitespacesAndNewlines),
       revision.isEmpty == false {
        return revision
    }
    return (try? spec.valueType?.jsonString()) ?? UUID().uuidString
}

private func mapFeaturePayload(_ feature: MapVisualizationFeature, coordinateSpace: MapVisualizationSpec.CoordinateSpace) -> ValueType {
    var object = feature.properties ?? [:]
    object["id"] = .string(feature.id)
    if let label = feature.label, label.isEmpty == false {
        object["label"] = .string(label)
    }
    object["coordinateSpace"] = .string(coordinateSpace.rawValue)
    if let featureValue = feature.valueType {
        object["feature"] = featureValue
    }
    return .object(object)
}

private func planarScene(from spec: MapVisualizationSpec) -> VisualizationResolvedPlanarScene {
    let features = resolvedMapFeatures(from: spec)
    let imageBase: MapVisualizationImageBase?
    if case let .image(base)? = spec.base {
        imageBase = base
    } else {
        imageBase = nil
    }

    let fallbackBounds = inferredPlanarBounds(from: features) ?? MapVisualizationBounds(minX: 0, minY: 0, maxX: 100, maxY: 100)
    let bounds = imageBase?.bounds ?? spec.viewport?.bounds ?? fallbackBounds

    return VisualizationResolvedPlanarScene(
        bounds: bounds,
        imageBase: imageBase,
        viewport: spec.viewport,
        features: features,
        signature: mapVisualizationSignature(for: spec)
    )
}

private func inferredPlanarBounds(from features: [VisualizationResolvedMapFeature]) -> MapVisualizationBounds? {
    var xs: [Double] = []
    var ys: [Double] = []
    for feature in features {
        switch feature.geometry {
        case .point(let coordinate):
            xs.append(coordinate.x)
            ys.append(coordinate.y)
        case .polyline(let coordinates), .polygon(let coordinates):
            xs.append(contentsOf: coordinates.map(\.x))
            ys.append(contentsOf: coordinates.map(\.y))
        }
    }
    guard let minX = xs.min(),
          let maxX = xs.max(),
          let minY = ys.min(),
          let maxY = ys.max() else {
        return nil
    }

    let width = max(maxX - minX, 1)
    let height = max(maxY - minY, 1)
    return MapVisualizationBounds(
        minX: minX - width * 0.05,
        minY: minY - height * 0.05,
        maxX: maxX + width * 0.05,
        maxY: maxY + height * 0.05
    )
}

private func color(from styleHex: String?, fallback: Color) -> Color {
    guard let styleHex,
          let color = Color(hex: styleHex) else {
        return fallback
    }
    return color
}

private func opacityValue(_ value: Double?, fallback: Double) -> Double {
    guard let value, value.isFinite else {
        return fallback
    }
    return max(0, min(1, value))
}

private func pointRadius(for style: MapVisualizationStyle, selected: Bool) -> CGFloat {
    let base = CGFloat(style.radius ?? 8)
    return max(5, selected ? base + 2 : base)
}

private func strokeWidth(for style: MapVisualizationStyle, selected: Bool) -> CGFloat {
    let base = CGFloat(style.strokeWidth ?? 2)
    return max(1, selected ? base + 1 : base)
}

private extension Color {
    init?(hex: String) {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.hasPrefix("#") {
            sanitized.removeFirst()
        }

        var rgba: UInt64 = 0
        guard Scanner(string: sanitized).scanHexInt64(&rgba) else {
            return nil
        }

        switch sanitized.count {
        case 6:
            let red = Double((rgba & 0xFF0000) >> 16) / 255.0
            let green = Double((rgba & 0x00FF00) >> 8) / 255.0
            let blue = Double(rgba & 0x0000FF) / 255.0
            self = Color(red: red, green: green, blue: blue)
        case 8:
            let red = Double((rgba & 0xFF000000) >> 24) / 255.0
            let green = Double((rgba & 0x00FF0000) >> 16) / 255.0
            let blue = Double((rgba & 0x0000FF00) >> 8) / 255.0
            let alpha = Double(rgba & 0x000000FF) / 255.0
            self = Color(red: red, green: green, blue: blue).opacity(alpha)
        default:
            return nil
        }
    }
}

private struct VisualizationPlanarMapView: View {
    let spec: MapVisualizationSpec
    let selection: VisualizationSelectionState
    let activateFeature: ((ValueType, Int, String?, String?) -> Void)?

    @State private var committedScale: CGFloat = 1
    @State private var activeScale: CGFloat = 1
    @State private var committedOffset: CGSize = .zero
    @State private var activeOffset: CGSize = .zero
    @State private var initializedSceneSignature: String = ""

    private var scene: VisualizationResolvedPlanarScene {
        planarScene(from: spec)
    }

    private var aspectRatio: CGFloat {
        if let intrinsicSize = scene.imageBase?.intrinsicSize,
           intrinsicSize.width > 0, intrinsicSize.height > 0 {
            return CGFloat(intrinsicSize.width / intrinsicSize.height)
        }
        let width = max(scene.bounds.maxX - scene.bounds.minX, 1)
        let height = max(scene.bounds.maxY - scene.bounds.minY, 1)
        return CGFloat(width / height)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = max(240, width / max(aspectRatio, 0.25))
            let sceneSize = CGSize(width: width, height: height)

            ZStack {
                planarBackground
                    .frame(width: sceneSize.width, height: sceneSize.height)
                    .clipped()

                Canvas { context, size in
                    drawPlanarFeatures(in: &context, size: size)
                }
                .frame(width: sceneSize.width, height: sceneSize.height)
            }
            .frame(width: sceneSize.width, height: sceneSize.height)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.03))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .scaleEffect(activeScale)
            .offset(activeOffset)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let translation = value.translation
                        if abs(translation.width) > 3 || abs(translation.height) > 3 {
                            activeOffset = CGSize(
                                width: committedOffset.width + translation.width,
                                height: committedOffset.height + translation.height
                            )
                        }
                    }
                    .onEnded { value in
                        let translation = value.translation
                        if abs(translation.width) <= 3 && abs(translation.height) <= 3 {
                            handleTap(at: value.location, in: sceneSize)
                            activeOffset = committedOffset
                            return
                        }
                        committedOffset = CGSize(
                            width: committedOffset.width + translation.width,
                            height: committedOffset.height + translation.height
                        )
                        activeOffset = committedOffset
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        activeScale = clampScale(committedScale * value)
                    }
                    .onEnded { value in
                        committedScale = clampScale(committedScale * value)
                        activeScale = committedScale
                    }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                syncViewportIfNeeded(sceneSize: sceneSize)
            }
            .onChange(of: scene.signature) { _ in
                syncViewportIfNeeded(sceneSize: sceneSize, force: true)
            }
        }
        .frame(minHeight: 280)
    }

    @ViewBuilder
    private var planarBackground: some View {
        if let rawURL = scene.imageBase?.url,
           let url = URL(string: rawURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    backgroundGrid
                case .empty:
                    backgroundGrid
                @unknown default:
                    backgroundGrid
                }
            }
        } else {
            backgroundGrid
        }
    }

    private var backgroundGrid: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.03), Color.black.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Canvas { context, size in
                let spacing: CGFloat = 36
                for x in stride(from: 0, through: size.width, by: spacing) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(Color.black.opacity(0.06)), lineWidth: 1)
                }
                for y in stride(from: 0, through: size.height, by: spacing) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(Color.black.opacity(0.06)), lineWidth: 1)
                }
            }
        }
    }

    private func drawPlanarFeatures(in context: inout GraphicsContext, size: CGSize) {
        for feature in scene.features {
            let isSelected = selection.contains(id: feature.id, index: feature.index)
            switch feature.geometry {
            case .point(let coordinate):
                let center = planarPoint(for: coordinate, size: size)
                let radius = pointRadius(for: feature.style, selected: isSelected)
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                let fill = color(from: feature.style.fillColor ?? feature.style.tintColor, fallback: .accentColor)
                let stroke = color(from: feature.style.strokeColor, fallback: .white)
                context.fill(Path(ellipseIn: rect), with: .color(fill.opacity(isSelected ? 0.95 : 0.82)))
                context.stroke(Path(ellipseIn: rect), with: .color(stroke), lineWidth: strokeWidth(for: feature.style, selected: isSelected))

            case .polyline(let coordinates):
                guard coordinates.count > 1 else { continue }
                var path = Path()
                let points = coordinates.map { planarPoint(for: $0, size: size) }
                path.move(to: points[0])
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
                let stroke = color(from: feature.style.strokeColor ?? feature.style.tintColor, fallback: .accentColor)
                context.stroke(
                    path,
                    with: .color(stroke.opacity(opacityValue(feature.style.strokeOpacity, fallback: isSelected ? 0.95 : 0.82))),
                    lineWidth: strokeWidth(for: feature.style, selected: isSelected)
                )

            case .polygon(let coordinates):
                guard coordinates.count > 2 else { continue }
                let points = coordinates.map { planarPoint(for: $0, size: size) }
                var path = Path()
                path.move(to: points[0])
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
                path.closeSubpath()
                let fill = color(from: feature.style.fillColor ?? feature.style.tintColor, fallback: .accentColor)
                let stroke = color(from: feature.style.strokeColor, fallback: .accentColor)
                context.fill(
                    path,
                    with: .color(fill.opacity(opacityValue(feature.style.fillOpacity, fallback: isSelected ? 0.28 : 0.20)))
                )
                context.stroke(
                    path,
                    with: .color(stroke.opacity(opacityValue(feature.style.strokeOpacity, fallback: 0.9))),
                    lineWidth: strokeWidth(for: feature.style, selected: isSelected)
                )
            }
        }
    }

    private func planarPoint(for coordinate: MapVisualizationCoordinate, size: CGSize) -> CGPoint {
        let width = max(scene.bounds.maxX - scene.bounds.minX, 1)
        let height = max(scene.bounds.maxY - scene.bounds.minY, 1)
        let normalizedX = (coordinate.x - scene.bounds.minX) / width
        let normalizedY = (coordinate.y - scene.bounds.minY) / height
        return CGPoint(
            x: CGFloat(normalizedX) * size.width,
            y: CGFloat(normalizedY) * size.height
        )
    }

    private func handleTap(at location: CGPoint, in sceneSize: CGSize) {
        guard let feature = hitTestFeature(at: location, in: sceneSize),
              feature.selectable else {
            return
        }
        activateFeature?(feature.raw, feature.index, feature.id, feature.label)
    }

    private func hitTestFeature(at location: CGPoint, in sceneSize: CGSize) -> VisualizationResolvedMapFeature? {
        let local = inverseTransformedLocation(location, sceneSize: sceneSize)
        let pointThreshold: CGFloat = 24
        let lineThreshold: CGFloat = 16

        for feature in scene.features {
            switch feature.geometry {
            case .point(let coordinate):
                let point = planarPoint(for: coordinate, size: sceneSize)
                if hypot(point.x - local.x, point.y - local.y) <= pointThreshold {
                    return feature
                }
            case .polygon(let coordinates):
                let path = polygonPath(for: coordinates, size: sceneSize)
                if path.contains(local) {
                    return feature
                }
            case .polyline(let coordinates):
                if distanceToPolyline(local, coordinates: coordinates, size: sceneSize) <= lineThreshold {
                    return feature
                }
            }
        }
        return nil
    }

    private func polygonPath(for coordinates: [MapVisualizationCoordinate], size: CGSize) -> Path {
        var path = Path()
        let points = coordinates.map { planarPoint(for: $0, size: size) }
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    private func distanceToPolyline(
        _ point: CGPoint,
        coordinates: [MapVisualizationCoordinate],
        size: CGSize
    ) -> CGFloat {
        let points = coordinates.map { planarPoint(for: $0, size: size) }
        guard points.count > 1 else { return .greatestFiniteMagnitude }
        var minimum = CGFloat.greatestFiniteMagnitude
        for index in 0 ..< (points.count - 1) {
            minimum = min(minimum, distanceFrom(point, toSegmentFrom: points[index], to: points[index + 1]))
        }
        return minimum
    }

    private func inverseTransformedLocation(_ location: CGPoint, sceneSize: CGSize) -> CGPoint {
        let center = CGPoint(x: sceneSize.width / 2, y: sceneSize.height / 2)
        return CGPoint(
            x: center.x + ((location.x - center.x - activeOffset.width) / max(activeScale, 0.01)),
            y: center.y + ((location.y - center.y - activeOffset.height) / max(activeScale, 0.01))
        )
    }

    private func syncViewportIfNeeded(sceneSize: CGSize, force: Bool = false) {
        guard force || initializedSceneSignature != scene.signature else {
            return
        }
        initializedSceneSignature = scene.signature

        let nextScale = clampScale(CGFloat(scene.viewport?.zoom ?? 1))
        committedScale = nextScale
        activeScale = nextScale

        if let centerCoordinate = scene.viewport?.center {
            let localPoint = planarPoint(for: centerCoordinate, size: sceneSize)
            let center = CGPoint(x: sceneSize.width / 2, y: sceneSize.height / 2)
            let offset = CGSize(
                width: (center.x - localPoint.x) * nextScale,
                height: (center.y - localPoint.y) * nextScale
            )
            committedOffset = offset
            activeOffset = offset
        } else {
            committedOffset = .zero
            activeOffset = .zero
        }
    }

    private func clampScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 1), 6)
    }

    private func distanceFrom(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = max(0, min(1, ((point.x - start.x) * deltaX + (point.y - start.y) * deltaY) / lengthSquared))
        let projection = CGPoint(x: start.x + t * deltaX, y: start.y + t * deltaY)
        return hypot(point.x - projection.x, point.y - projection.y)
    }
}

#if canImport(MapKit)
private struct VisualizationGeospatialMapView: View {
    let spec: MapVisualizationSpec
    let selection: VisualizationSelectionState
    let activateFeature: ((ValueType, Int, String?, String?) -> Void)?

    var body: some View {
        VisualizationGeospatialMapRepresentable(
            spec: spec,
            selection: selection,
            activateFeature: activateFeature
        )
        .frame(minHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private final class VisualizationMapFeatureAnnotation: NSObject, MKAnnotation {
    let feature: VisualizationResolvedMapFeature
    dynamic var coordinate: CLLocationCoordinate2D

    init(feature: VisualizationResolvedMapFeature, coordinate: CLLocationCoordinate2D) {
        self.feature = feature
        self.coordinate = coordinate
        super.init()
    }

    var title: String? {
        feature.label
    }
}

private enum VisualizationMapOverlayKind {
    case polyline
    case polygon
}

private struct VisualizationMapOverlayMetadata {
    let feature: VisualizationResolvedMapFeature
    let kind: VisualizationMapOverlayKind
    let coordinates: [CLLocationCoordinate2D]
}

#if os(macOS)
private struct VisualizationGeospatialMapRepresentable: NSViewRepresentable {
    let spec: MapVisualizationSpec
    let selection: VisualizationSelectionState
    let activateFeature: ((ValueType, Int, String?, String?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        configure(mapView, coordinator: context.coordinator)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(mapView)
    }
}
#else
private struct VisualizationGeospatialMapRepresentable: UIViewRepresentable {
    let spec: MapVisualizationSpec
    let selection: VisualizationSelectionState
    let activateFeature: ((ValueType, Int, String?, String?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        configure(mapView, coordinator: context.coordinator)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(mapView)
    }
}
#endif

private extension VisualizationGeospatialMapRepresentable {
    func configure(_ mapView: MKMapView, coordinator: Coordinator) {
        mapView.delegate = coordinator
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsCompass = false
        mapView.showsScale = false
#if os(macOS)
        let recognizer = NSClickGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleMapTap(_:)))
        mapView.addGestureRecognizer(recognizer)
#else
        let recognizer = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleMapTap(_:)))
        recognizer.cancelsTouchesInView = false
        mapView.addGestureRecognizer(recognizer)
#endif
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: VisualizationGeospatialMapRepresentable
        private var lastSceneSignature: String = ""
        private var lastSelectionSignature: String = ""
        private var overlayMetadata: [ObjectIdentifier: VisualizationMapOverlayMetadata] = [:]
        private var tileOverlay: MKTileOverlay?

        init(parent: VisualizationGeospatialMapRepresentable) {
            self.parent = parent
        }

        func update(_ mapView: MKMapView) {
            let sceneSignature = mapVisualizationSignature(for: parent.spec)
            let selectionSignature = mapSelectionSignature(parent.selection)
            let sceneChanged = sceneSignature != lastSceneSignature

            if sceneChanged {
                rebuildScene(on: mapView)
                lastSceneSignature = sceneSignature
            }

            if sceneChanged || selectionSignature != lastSelectionSignature {
                refreshSelection(on: mapView)
                lastSelectionSignature = selectionSignature
            }
        }

        private func rebuildScene(on mapView: MKMapView) {
            overlayMetadata.removeAll()
            if mapView.annotations.isEmpty == false {
                mapView.removeAnnotations(mapView.annotations)
            }
            if mapView.overlays.isEmpty == false {
                mapView.removeOverlays(mapView.overlays)
            }

            tileOverlay = nil
            if case let .tiles(base)? = parent.spec.base {
                let overlay = MKTileOverlay(urlTemplate: base.urlTemplate)
                overlay.canReplaceMapContent = false
                overlay.minimumZ = Int(base.minZoom ?? 0)
                overlay.maximumZ = Int(base.maxZoom ?? 20)
                tileOverlay = overlay
                mapView.addOverlay(overlay, level: .aboveLabels)
            }

            let features = resolvedMapFeatures(from: parent.spec)
            var annotations: [VisualizationMapFeatureAnnotation] = []
            var overlays: [MKOverlay] = []

            for feature in features {
                switch feature.geometry {
                case .point(let coordinate):
                    annotations.append(
                        VisualizationMapFeatureAnnotation(
                            feature: feature,
                            coordinate: CLLocationCoordinate2D(latitude: coordinate.lat, longitude: coordinate.lng)
                        )
                    )
                case .polyline(let coordinates):
                    let coords = coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
                    let overlay = MKPolyline(coordinates: coords, count: coords.count)
                    overlayMetadata[ObjectIdentifier(overlay)] = VisualizationMapOverlayMetadata(
                        feature: feature,
                        kind: .polyline,
                        coordinates: coords
                    )
                    overlays.append(overlay)
                case .polygon(let coordinates):
                    let coords = coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
                    let overlay = MKPolygon(coordinates: coords, count: coords.count)
                    overlayMetadata[ObjectIdentifier(overlay)] = VisualizationMapOverlayMetadata(
                        feature: feature,
                        kind: .polygon,
                        coordinates: coords
                    )
                    overlays.append(overlay)
                }
            }

            if annotations.isEmpty == false {
                mapView.addAnnotations(annotations)
            }
            if overlays.isEmpty == false {
                mapView.addOverlays(overlays)
            }

            applyViewportOrFit(on: mapView, features: features)
        }

        private func applyViewportOrFit(on mapView: MKMapView, features: [VisualizationResolvedMapFeature]) {
            if let bounds = parent.spec.viewport?.bounds {
                let topLeft = CLLocationCoordinate2D(latitude: bounds.minY, longitude: bounds.minX)
                let bottomRight = CLLocationCoordinate2D(latitude: bounds.maxY, longitude: bounds.maxX)
                let rect = MKMapRect(origin: MKMapPoint(topLeft), size: .init(width: 0, height: 0))
                    .union(MKMapRect(origin: MKMapPoint(bottomRight), size: .init(width: 0, height: 0)))
                if rect.isNull == false {
                    mapView.setVisibleMapRect(rect, edgePadding: mapInsets, animated: false)
                    return
                }
            }

            if let center = parent.spec.viewport?.center {
                let coordinate = CLLocationCoordinate2D(latitude: center.lat, longitude: center.lng)
                let zoom = parent.spec.viewport?.zoom ?? 5
                mapView.setRegion(region(center: coordinate, zoom: zoom), animated: false)
                return
            }

            switch parent.spec.fit ?? .fitFeatures {
            case .manual:
                break
            case .fitBase, .fitFeatures:
                let rect = featureMapRect(features)
                if rect.isNull == false {
                    mapView.setVisibleMapRect(rect, edgePadding: mapInsets, animated: false)
                }
            }
        }

        private var mapInsets: VisualizationMapEdgeInsets {
#if os(macOS)
            NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
#else
            UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
#endif
        }

        private func featureMapRect(_ features: [VisualizationResolvedMapFeature]) -> MKMapRect {
            var rect = MKMapRect.null
            for feature in features {
                switch feature.geometry {
                case .point(let coordinate):
                    let point = MKMapPoint(CLLocationCoordinate2D(latitude: coordinate.lat, longitude: coordinate.lng))
                    rect = rect.union(MKMapRect(origin: point, size: .init(width: 0, height: 0)))
                case .polyline(let coordinates), .polygon(let coordinates):
                    for coordinate in coordinates {
                        let point = MKMapPoint(CLLocationCoordinate2D(latitude: coordinate.lat, longitude: coordinate.lng))
                        rect = rect.union(MKMapRect(origin: point, size: .init(width: 0, height: 0)))
                    }
                }
            }
            return rect
        }

        private func region(center: CLLocationCoordinate2D, zoom: Double) -> MKCoordinateRegion {
            let normalizedZoom = max(1, min(zoom, 20))
            let metersPerTile = 40_075_016.686 / pow(2, normalizedZoom)
            let meters = max(metersPerTile * 2.5, 50)
            return MKCoordinateRegion(center: center, latitudinalMeters: meters, longitudinalMeters: meters)
        }

        private func refreshSelection(on mapView: MKMapView) {
            for annotation in mapView.annotations {
                guard let featureAnnotation = annotation as? VisualizationMapFeatureAnnotation,
                      let view = mapView.view(for: featureAnnotation) as? MKMarkerAnnotationView else {
                    continue
                }
                applyStyle(to: view, feature: featureAnnotation.feature)
            }
            for overlay in mapView.overlays {
                guard let renderer = mapView.renderer(for: overlay) else { continue }
                renderer.setNeedsDisplay()
            }
        }

        private func applyStyle(to view: MKMarkerAnnotationView, feature: VisualizationResolvedMapFeature) {
            let selected = parent.selection.contains(id: feature.id, index: feature.index)
            view.canShowCallout = false
            view.glyphText = nil
            view.markerTintColor = platformColor(
                from: feature.style.fillColor ?? feature.style.tintColor,
                fallback: selected ? .systemBlue : .systemTeal
            )
            view.displayPriority = .required
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let featureAnnotation = annotation as? VisualizationMapFeatureAnnotation else {
                return nil
            }
            let identifier = "VisualizationFeatureAnnotation"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            applyStyle(to: view, feature: featureAnnotation.feature)
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            guard let metadata = overlayMetadata[ObjectIdentifier(overlay as AnyObject)] else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let selected = parent.selection.contains(id: metadata.feature.id, index: metadata.feature.index)
            switch metadata.kind {
            case .polyline:
                let renderer = MKPolylineRenderer(overlay: overlay)
                renderer.strokeColor = platformColor(
                    from: metadata.feature.style.strokeColor ?? metadata.feature.style.tintColor,
                    fallback: selected ? .systemBlue : .systemTeal
                ).withAlphaComponent(CGFloat(opacityValue(metadata.feature.style.strokeOpacity, fallback: 0.9)))
                renderer.lineWidth = strokeWidth(for: metadata.feature.style, selected: selected)
                return renderer
            case .polygon:
                let renderer = MKPolygonRenderer(overlay: overlay)
                renderer.strokeColor = platformColor(
                    from: metadata.feature.style.strokeColor ?? metadata.feature.style.tintColor,
                    fallback: selected ? .systemBlue : .systemTeal
                ).withAlphaComponent(CGFloat(opacityValue(metadata.feature.style.strokeOpacity, fallback: 0.9)))
                renderer.lineWidth = strokeWidth(for: metadata.feature.style, selected: selected)
                renderer.fillColor = platformColor(
                    from: metadata.feature.style.fillColor ?? metadata.feature.style.tintColor,
                    fallback: selected ? .systemBlue : .systemTeal
                ).withAlphaComponent(CGFloat(opacityValue(metadata.feature.style.fillOpacity, fallback: selected ? 0.28 : 0.2)))
                return renderer
            }
        }

#if os(macOS)
        @objc func handleMapTap(_ recognizer: NSClickGestureRecognizer) {
            guard let mapView = recognizer.view as? MKMapView else { return }
            handleTap(at: recognizer.location(in: mapView), in: mapView)
        }
#else
        @objc func handleMapTap(_ recognizer: UITapGestureRecognizer) {
            guard let mapView = recognizer.view as? MKMapView else { return }
            handleTap(at: recognizer.location(in: mapView), in: mapView)
        }
#endif

        private func handleTap(at location: CGPoint, in mapView: MKMapView) {
            guard let feature = hitTestFeature(at: location, in: mapView),
                  feature.selectable else {
                return
            }
            parent.activateFeature?(feature.raw, feature.index, feature.id, feature.label)
        }

        private func hitTestFeature(at location: CGPoint, in mapView: MKMapView) -> VisualizationResolvedMapFeature? {
            let pointThreshold: CGFloat = 24
            let lineThreshold: CGFloat = 16

            for annotation in mapView.annotations {
                guard let featureAnnotation = annotation as? VisualizationMapFeatureAnnotation else { continue }
                let point = mapView.convert(featureAnnotation.coordinate, toPointTo: mapView)
                if hypot(point.x - location.x, point.y - location.y) <= pointThreshold {
                    return featureAnnotation.feature
                }
            }

            for metadata in overlayMetadata.values where metadata.kind == .polygon {
                let path = polygonPath(for: metadata.coordinates, in: mapView)
                if path.contains(location) {
                    return metadata.feature
                }
            }

            for metadata in overlayMetadata.values where metadata.kind == .polyline {
                let distance = distanceToPolyline(location, coordinates: metadata.coordinates, in: mapView)
                if distance <= lineThreshold {
                    return metadata.feature
                }
            }
            return nil
        }

        private func polygonPath(for coordinates: [CLLocationCoordinate2D], in mapView: MKMapView) -> CGPath {
            let path = CGMutablePath()
            let points = coordinates.map { mapView.convert($0, toPointTo: mapView) }
            guard let first = points.first else {
                return path
            }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
            return path
        }

        private func distanceToPolyline(
            _ point: CGPoint,
            coordinates: [CLLocationCoordinate2D],
            in mapView: MKMapView
        ) -> CGFloat {
            let points = coordinates.map { mapView.convert($0, toPointTo: mapView) }
            guard points.count > 1 else { return .greatestFiniteMagnitude }
            var minimum = CGFloat.greatestFiniteMagnitude
            for index in 0 ..< (points.count - 1) {
                minimum = min(minimum, distanceFrom(point, toSegmentFrom: points[index], to: points[index + 1]))
            }
            return minimum
        }

        private func distanceFrom(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
            let deltaX = end.x - start.x
            let deltaY = end.y - start.y
            let lengthSquared = deltaX * deltaX + deltaY * deltaY
            guard lengthSquared > 0 else {
                return hypot(point.x - start.x, point.y - start.y)
            }
            let t = max(0, min(1, ((point.x - start.x) * deltaX + (point.y - start.y) * deltaY) / lengthSquared))
            let projection = CGPoint(x: start.x + t * deltaX, y: start.y + t * deltaY)
            return hypot(point.x - projection.x, point.y - projection.y)
        }

        private func mapSelectionSignature(_ selection: VisualizationSelectionState) -> String {
            let selectedID = selection.selectedID ?? ""
            let selectedIndex = selection.selectedIndex.map(String.init) ?? ""
            let selectedIDs = selection.selectedIDs.sorted().joined(separator: "|")
            return [selectedID, selectedIndex, selectedIDs].joined(separator: "::")
        }

        private func platformColor(from hex: String?, fallback: PlatformColor) -> PlatformColor {
#if os(macOS)
            if let hex, let color = Color(hex: hex) {
                return NSColor(color)
            }
            return fallback
#else
            if let hex, let color = Color(hex: hex) {
                return UIColor(color)
            }
            return fallback
#endif
        }
    }
}

#if os(macOS)
private typealias PlatformColor = NSColor
#else
private typealias PlatformColor = UIColor
#endif
#endif
