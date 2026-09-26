import Foundation
import ImageIO

/// An explicitly published, bounded read model. Never populated from a full profile.
public struct NearbyAdvertisement: Codable, Equatable {
    public enum Scope: String, Codable, CaseIterable, Sendable { case nearby, conference, agreement }
    public var displayName: String
    public var purposes: [String: String]
    public var interests: [String: String]
    public var scope: Scope
    public var scopeID: String?
    public var thumbnail: Data?
    public var expiresAt: TimeInterval
    public var accessAgreement: NearbyAccessAgreement?

    public static let maximumEntries = 6
    public static let maximumImageBytes = 32_768
    public static let maximumWireBytes = 131_072
    public static let maximumLifetime: TimeInterval = 8 * 60 * 60

    public init(displayName: String, purposes: [String: String], interests: [String: String],
                scope: Scope = .nearby, scopeID: String? = nil, thumbnail: Data? = nil,
                expiresAt: TimeInterval, accessAgreement: NearbyAccessAgreement? = nil) {
        self.displayName = displayName; self.purposes = purposes; self.interests = interests
        self.scope = scope; self.scopeID = scopeID; self.thumbnail = thumbnail; self.expiresAt = expiresAt
        self.accessAgreement = accessAgreement
    }

    public func validate(now: TimeInterval = Date().timeIntervalSince1970) throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.utf8.count <= 80,
              expiresAt.isFinite, expiresAt > now, expiresAt <= now + Self.maximumLifetime + 5 else {
            throw ValidationError.invalidPublication
        }
        for (axis, entries) in [("purpose", purposes), ("interest", interests)] {
            guard entries.count <= Self.maximumEntries,
                  entries.allSatisfy({ key, value in
                      key.hasPrefix(axis + "://") && key.utf8.count <= 160 &&
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 100
                  }) else { throw ValidationError.invalidEntries }
        }
        if scope != .nearby {
            guard let scopeID, !scopeID.isEmpty, scopeID.utf8.count <= 160 else { throw ValidationError.invalidScope }
            guard let accessAgreement, scopeID == accessAgreement.domain else { throw ValidationError.invalidScope }
            try accessAgreement.validate()
        } else if scopeID != nil || accessAgreement != nil { throw ValidationError.invalidScope }
        if let thumbnail { try Self.validateThumbnail(thumbnail) }
        guard try JSONEncoder().encode(self).count <= Self.maximumWireBytes else { throw ValidationError.tooLarge }
    }

    public static func validateThumbnail(_ data: Data) throws {
        guard data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, ["public.jpeg", "public.png"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 256, height <= 256 else { throw ValidationError.invalidImage }
    }

    public enum ValidationError: Error { case invalidPublication, invalidEntries, invalidScope, invalidImage, tooLarge }
}

/// Request binding prevents a late response to a previous selection replacing the current one.
struct NearbyAdvertisementEnvelope: Codable {
    static let protocolName = "haven-advertisement-v1"
    var protocolName: String = Self.protocolName
    var requestID: UUID
    var advertisement: NearbyAdvertisement?
}
