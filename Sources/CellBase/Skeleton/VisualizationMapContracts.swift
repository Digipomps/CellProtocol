// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct MapVisualizationSpec: Codable {
    public enum CoordinateSpace: String, Codable, CaseIterable {
        case geospatial
        case planar
    }

    public enum FitMode: String, Codable, CaseIterable {
        case manual
        case fitBase
        case fitFeatures
    }

    public var coordinateSpace: CoordinateSpace
    public var base: MapVisualizationBase?
    public var viewport: MapVisualizationViewport?
    public var fit: FitMode?
    public var features: [MapVisualizationFeature]
    public var revision: String?

    public init(
        coordinateSpace: CoordinateSpace,
        base: MapVisualizationBase? = nil,
        viewport: MapVisualizationViewport? = nil,
        fit: FitMode? = nil,
        features: [MapVisualizationFeature] = [],
        revision: String? = nil
    ) {
        self.coordinateSpace = coordinateSpace
        self.base = base
        self.viewport = viewport
        self.fit = fit
        self.features = features
        self.revision = revision
    }

    public static func decode(from value: ValueType?) -> MapVisualizationSpec? {
        MapVisualizationValueCodec.decode(MapVisualizationSpec.self, from: value)
    }

    public var valueType: ValueType? {
        MapVisualizationValueCodec.encode(self)
    }
}

public enum MapVisualizationBase: Codable {
    case tiles(MapVisualizationTileBase)
    case image(MapVisualizationImageBase)

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    private enum Kind: String, Codable {
        case tiles
        case image
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .tiles:
            self = .tiles(try MapVisualizationTileBase(from: decoder))
        case .image:
            self = .image(try MapVisualizationImageBase(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .tiles(let base):
            try base.encode(to: encoder)
        case .image(let base):
            try base.encode(to: encoder)
        }
    }
}

public struct MapVisualizationTileBase: Codable {
    public var kind: String = "tiles"
    public var urlTemplate: String
    public var attribution: String?
    public var minZoom: Double?
    public var maxZoom: Double?
    public var tileSize: Double?
    public var subdomains: [String]?

    public init(
        urlTemplate: String,
        attribution: String? = nil,
        minZoom: Double? = nil,
        maxZoom: Double? = nil,
        tileSize: Double? = nil,
        subdomains: [String]? = nil
    ) {
        self.urlTemplate = urlTemplate
        self.attribution = attribution
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.tileSize = tileSize
        self.subdomains = subdomains
    }
}

public struct MapVisualizationImageBase: Codable {
    public var kind: String = "image"
    public var url: String
    public var bounds: MapVisualizationBounds
    public var intrinsicSize: MapVisualizationSize?
    public var opacity: Double?

    public init(
        url: String,
        bounds: MapVisualizationBounds,
        intrinsicSize: MapVisualizationSize? = nil,
        opacity: Double? = nil
    ) {
        self.url = url
        self.bounds = bounds
        self.intrinsicSize = intrinsicSize
        self.opacity = opacity
    }
}

public struct MapVisualizationViewport: Codable {
    public var center: MapVisualizationCoordinate?
    public var zoom: Double?
    public var bounds: MapVisualizationBounds?

    public init(
        center: MapVisualizationCoordinate? = nil,
        zoom: Double? = nil,
        bounds: MapVisualizationBounds? = nil
    ) {
        self.center = center
        self.zoom = zoom
        self.bounds = bounds
    }
}

public struct MapVisualizationFeature: Codable {
    public var id: String
    public var geometry: MapVisualizationGeometry
    public var label: String?
    public var properties: Object?
    public var selectable: Bool?
    public var style: MapVisualizationStyle?

    public init(
        id: String,
        geometry: MapVisualizationGeometry,
        label: String? = nil,
        properties: Object? = nil,
        selectable: Bool? = nil,
        style: MapVisualizationStyle? = nil
    ) {
        self.id = id
        self.geometry = geometry
        self.label = label
        self.properties = properties
        self.selectable = selectable
        self.style = style
    }

    public var valueType: ValueType? {
        MapVisualizationValueCodec.encode(self)
    }
}

public enum MapVisualizationGeometry: Codable {
    case point(MapVisualizationCoordinate)
    case polyline([MapVisualizationCoordinate])
    case polygon([MapVisualizationCoordinate])

    private enum CodingKeys: String, CodingKey {
        case type
        case coordinates
    }

    private enum Kind: String, Codable {
        case point
        case polyline
        case polygon
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .point:
            self = .point(try container.decode(MapVisualizationCoordinate.self, forKey: .coordinates))
        case .polyline:
            self = .polyline(try container.decode([MapVisualizationCoordinate].self, forKey: .coordinates))
        case .polygon:
            self = .polygon(try container.decode([MapVisualizationCoordinate].self, forKey: .coordinates))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .point(let coordinate):
            try container.encode(Kind.point, forKey: .type)
            try container.encode(coordinate, forKey: .coordinates)
        case .polyline(let coordinates):
            try container.encode(Kind.polyline, forKey: .type)
            try container.encode(coordinates, forKey: .coordinates)
        case .polygon(let coordinates):
            try container.encode(Kind.polygon, forKey: .type)
            try container.encode(coordinates, forKey: .coordinates)
        }
    }
}

public struct MapVisualizationCoordinate: Codable {
    public var first: Double
    public var second: Double

    public init(_ first: Double, _ second: Double) {
        self.first = first
        self.second = second
    }

    public var x: Double { first }
    public var y: Double { second }
    public var lng: Double { first }
    public var lat: Double { second }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.first = try container.decode(Double.self)
        self.second = try container.decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(first)
        try container.encode(second)
    }
}

public struct MapVisualizationBounds: Codable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}

public struct MapVisualizationSize: Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct MapVisualizationStyle: Codable {
    public var strokeColor: String?
    public var strokeWidth: Double?
    public var strokeOpacity: Double?
    public var fillColor: String?
    public var fillOpacity: Double?
    public var tintColor: String?
    public var radius: Double?

    public init(
        strokeColor: String? = nil,
        strokeWidth: Double? = nil,
        strokeOpacity: Double? = nil,
        fillColor: String? = nil,
        fillOpacity: Double? = nil,
        tintColor: String? = nil,
        radius: Double? = nil
    ) {
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.strokeOpacity = strokeOpacity
        self.fillColor = fillColor
        self.fillOpacity = fillOpacity
        self.tintColor = tintColor
        self.radius = radius
    }
}

private enum MapVisualizationValueCodec {
    static func encode<T: Encodable>(_ value: T) -> ValueType? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return try? JSONDecoder().decode(ValueType.self, from: data)
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: ValueType?) -> T? {
        guard let value,
              let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}
