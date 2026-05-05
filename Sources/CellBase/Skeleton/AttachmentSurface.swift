// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct AttachmentValue: Codable, Equatable {
    public var id: String
    public var kind: String
    public var displayName: String?
    public var mimeType: String?
    public var byteSize: Int?
    public var previewURL: String?
    public var assetReference: String?
    public var metadata: Object?

    public init(
        id: String,
        kind: String,
        displayName: String? = nil,
        mimeType: String? = nil,
        byteSize: Int? = nil,
        previewURL: String? = nil,
        assetReference: String? = nil,
        metadata: Object? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.previewURL = previewURL
        self.assetReference = assetReference
        self.metadata = metadata
    }
}

public enum AttachmentTransferPhase: String, Codable {
    case idle
    case dragTargeted
    case picking
    case uploading
    case attached
    case failed
}

public struct AttachmentFieldState: Codable, Equatable {
    public var phase: AttachmentTransferPhase
    public var progressFraction: Double?
    public var errorMessage: String?
    public var canOpen: Bool?
    public var canReplace: Bool?
    public var canRemove: Bool?

    public init(
        phase: AttachmentTransferPhase,
        progressFraction: Double? = nil,
        errorMessage: String? = nil,
        canOpen: Bool? = nil,
        canReplace: Bool? = nil,
        canRemove: Bool? = nil
    ) {
        self.phase = phase
        self.progressFraction = progressFraction
        self.errorMessage = errorMessage
        self.canOpen = canOpen
        self.canReplace = canReplace
        self.canRemove = canRemove
    }
}

public enum AttachmentFieldActionKind: String, Codable {
    case pick
    case drop
    case remove
    case replace
    case retry
    case openPreview
}

public struct AttachmentFieldAction: Codable, Equatable {
    public var kind: AttachmentFieldActionKind
    public var fieldID: String?
    public var temporaryPayload: Object?

    public init(
        kind: AttachmentFieldActionKind,
        fieldID: String? = nil,
        temporaryPayload: Object? = nil
    ) {
        self.kind = kind
        self.fieldID = fieldID
        self.temporaryPayload = temporaryPayload
    }
}

private enum AttachmentSurfaceValueTypeBridge {
    static func decode<T: Decodable>(_ type: T.Type, from valueType: ValueType?) -> T? {
        guard let valueType,
              let data = try? JSONEncoder().encode(valueType) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) -> ValueType? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return try? JSONDecoder().decode(ValueType.self, from: data)
    }
}

public extension AttachmentValue {
    init?(valueType: ValueType?) {
        guard let decoded: AttachmentValue = AttachmentSurfaceValueTypeBridge.decode(AttachmentValue.self, from: valueType) else {
            return nil
        }
        self = decoded
    }

    var valueType: ValueType? {
        AttachmentSurfaceValueTypeBridge.encode(self)
    }
}

public extension AttachmentFieldState {
    init?(valueType: ValueType?) {
        guard let decoded: AttachmentFieldState = AttachmentSurfaceValueTypeBridge.decode(AttachmentFieldState.self, from: valueType) else {
            return nil
        }
        self = decoded
    }

    var valueType: ValueType? {
        AttachmentSurfaceValueTypeBridge.encode(self)
    }
}

public extension AttachmentFieldAction {
    init?(valueType: ValueType?) {
        guard let decoded: AttachmentFieldAction = AttachmentSurfaceValueTypeBridge.decode(AttachmentFieldAction.self, from: valueType) else {
            return nil
        }
        self = decoded
    }

    var valueType: ValueType? {
        AttachmentSurfaceValueTypeBridge.encode(self)
    }
}

public struct SkeletonAttachmentField: Codable, Identifiable {
    public var id = UUID()
    public var title: String?
    public var subtitle: String?
    public var helperText: String?
    public var valueKeypath: String?
    public var stateKeypath: String?
    public var actionKeypath: String?
    public var acceptedContentTypes: [String]?
    public var preferredKinds: [String]?
    public var allowsMultiple: Bool?
    public var isRequired: Bool?
    public var supportsDrop: Bool?
    public var previewStyle: String?
    public var emptyTitle: String?
    public var emptyMessage: String?
    public var maxSizeBytes: Int?
    public var uploadMode: String?
    public var submitOnSelection: Bool?
    public var modifiers: SkeletonModifiers?

    public enum CodingKeys: CodingKey {
        case title
        case label
        case subtitle
        case helperText
        case valueKeypath
        case sourceKeypath
        case stateKeypath
        case actionKeypath
        case targetKeypath
        case acceptedContentTypes
        case accept
        case preferredKinds
        case allowsMultiple
        case multiple
        case isRequired
        case supportsDrop
        case previewStyle
        case emptyTitle
        case emptyMessage
        case maxSizeBytes
        case uploadMode
        case submitOnSelection
        case modifiers
    }

    enum ElementKey: CodingKey { case AttachmentField }

    public init(
        title: String? = nil,
        subtitle: String? = nil,
        helperText: String? = nil,
        valueKeypath: String? = nil,
        stateKeypath: String? = nil,
        actionKeypath: String? = nil,
        acceptedContentTypes: [String]? = nil,
        preferredKinds: [String]? = nil,
        allowsMultiple: Bool? = nil,
        isRequired: Bool? = nil,
        supportsDrop: Bool? = nil,
        previewStyle: String? = nil,
        emptyTitle: String? = nil,
        emptyMessage: String? = nil,
        maxSizeBytes: Int? = nil,
        uploadMode: String? = nil,
        submitOnSelection: Bool? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.helperText = helperText
        self.valueKeypath = valueKeypath
        self.stateKeypath = stateKeypath
        self.actionKeypath = actionKeypath
        self.acceptedContentTypes = acceptedContentTypes
        self.preferredKinds = preferredKinds
        self.allowsMultiple = allowsMultiple
        self.isRequired = isRequired
        self.supportsDrop = supportsDrop
        self.previewStyle = previewStyle
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.maxSizeBytes = maxSizeBytes
        self.uploadMode = uploadMode
        self.submitOnSelection = submitOnSelection
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .label)
        self.subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        self.helperText = try container.decodeIfPresent(String.self, forKey: .helperText)
        self.valueKeypath = try container.decodeIfPresent(String.self, forKey: .valueKeypath)
            ?? container.decodeIfPresent(String.self, forKey: .sourceKeypath)
        self.stateKeypath = try container.decodeIfPresent(String.self, forKey: .stateKeypath)
        self.actionKeypath = try container.decodeIfPresent(String.self, forKey: .actionKeypath)
            ?? container.decodeIfPresent(String.self, forKey: .targetKeypath)
        self.acceptedContentTypes = try container.decodeIfPresent([String].self, forKey: .acceptedContentTypes)
            ?? container.decodeIfPresent([String].self, forKey: .accept)
        self.preferredKinds = try container.decodeIfPresent([String].self, forKey: .preferredKinds)
        self.allowsMultiple = try container.decodeIfPresent(Bool.self, forKey: .allowsMultiple)
            ?? container.decodeIfPresent(Bool.self, forKey: .multiple)
        self.isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired)
        self.supportsDrop = try container.decodeIfPresent(Bool.self, forKey: .supportsDrop)
        self.previewStyle = try container.decodeIfPresent(String.self, forKey: .previewStyle)
        self.emptyTitle = try container.decodeIfPresent(String.self, forKey: .emptyTitle)
        self.emptyMessage = try container.decodeIfPresent(String.self, forKey: .emptyMessage)
        self.maxSizeBytes = try container.decodeIfPresent(Int.self, forKey: .maxSizeBytes)
        self.uploadMode = try container.decodeIfPresent(String.self, forKey: .uploadMode)
        self.submitOnSelection = try container.decodeIfPresent(Bool.self, forKey: .submitOnSelection)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .AttachmentField)
        try elementContainer.encodeIfPresent(self.title, forKey: .title)
        try elementContainer.encodeIfPresent(self.subtitle, forKey: .subtitle)
        try elementContainer.encodeIfPresent(self.helperText, forKey: .helperText)
        try elementContainer.encodeIfPresent(self.valueKeypath, forKey: .valueKeypath)
        try elementContainer.encodeIfPresent(self.stateKeypath, forKey: .stateKeypath)
        try elementContainer.encodeIfPresent(self.actionKeypath, forKey: .actionKeypath)
        try elementContainer.encodeIfPresent(self.acceptedContentTypes, forKey: .acceptedContentTypes)
        try elementContainer.encodeIfPresent(self.preferredKinds, forKey: .preferredKinds)
        try elementContainer.encodeIfPresent(self.allowsMultiple, forKey: .allowsMultiple)
        try elementContainer.encodeIfPresent(self.isRequired, forKey: .isRequired)
        try elementContainer.encodeIfPresent(self.supportsDrop, forKey: .supportsDrop)
        try elementContainer.encodeIfPresent(self.previewStyle, forKey: .previewStyle)
        try elementContainer.encodeIfPresent(self.emptyTitle, forKey: .emptyTitle)
        try elementContainer.encodeIfPresent(self.emptyMessage, forKey: .emptyMessage)
        try elementContainer.encodeIfPresent(self.maxSizeBytes, forKey: .maxSizeBytes)
        try elementContainer.encodeIfPresent(self.uploadMode, forKey: .uploadMode)
        try elementContainer.encodeIfPresent(self.submitOnSelection, forKey: .submitOnSelection)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonFileUpload: Codable, Identifiable {
    public var id = UUID()
    public var title: String?
    public var subtitle: String?
    public var helperText: String?
    public var valueKeypath: String?
    public var stateKeypath: String?
    public var actionKeypath: String?
    public var acceptedContentTypes: [String]?
    public var preferredKinds: [String]?
    public var allowsMultiple: Bool?
    public var isRequired: Bool?
    public var supportsDrop: Bool?
    public var previewStyle: String?
    public var emptyTitle: String?
    public var emptyMessage: String?
    public var maxSizeBytes: Int?
    public var uploadMode: String?
    public var submitOnSelection: Bool?
    public var modifiers: SkeletonModifiers?

    public enum CodingKeys: CodingKey {
        case title
        case label
        case subtitle
        case helperText
        case valueKeypath
        case sourceKeypath
        case stateKeypath
        case actionKeypath
        case targetKeypath
        case acceptedContentTypes
        case accept
        case preferredKinds
        case allowsMultiple
        case multiple
        case isRequired
        case supportsDrop
        case previewStyle
        case emptyTitle
        case emptyMessage
        case maxSizeBytes
        case uploadMode
        case submitOnSelection
        case modifiers
    }

    enum ElementKey: CodingKey { case FileUpload }

    public init(
        title: String? = nil,
        subtitle: String? = nil,
        helperText: String? = nil,
        valueKeypath: String? = nil,
        stateKeypath: String? = nil,
        actionKeypath: String? = nil,
        acceptedContentTypes: [String]? = nil,
        preferredKinds: [String]? = nil,
        allowsMultiple: Bool? = nil,
        isRequired: Bool? = nil,
        supportsDrop: Bool? = nil,
        previewStyle: String? = nil,
        emptyTitle: String? = nil,
        emptyMessage: String? = nil,
        maxSizeBytes: Int? = nil,
        uploadMode: String? = nil,
        submitOnSelection: Bool? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.helperText = helperText
        self.valueKeypath = valueKeypath
        self.stateKeypath = stateKeypath
        self.actionKeypath = actionKeypath
        self.acceptedContentTypes = acceptedContentTypes
        self.preferredKinds = preferredKinds
        self.allowsMultiple = allowsMultiple
        self.isRequired = isRequired
        self.supportsDrop = supportsDrop
        self.previewStyle = previewStyle
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.maxSizeBytes = maxSizeBytes
        self.uploadMode = uploadMode
        self.submitOnSelection = submitOnSelection
        self.modifiers = modifiers
    }

    public init(attachmentField: SkeletonAttachmentField) {
        self.id = attachmentField.id
        self.title = attachmentField.title
        self.subtitle = attachmentField.subtitle
        self.helperText = attachmentField.helperText
        self.valueKeypath = attachmentField.valueKeypath
        self.stateKeypath = attachmentField.stateKeypath
        self.actionKeypath = attachmentField.actionKeypath
        self.acceptedContentTypes = attachmentField.acceptedContentTypes
        self.preferredKinds = attachmentField.preferredKinds
        self.allowsMultiple = attachmentField.allowsMultiple
        self.isRequired = attachmentField.isRequired
        self.supportsDrop = attachmentField.supportsDrop
        self.previewStyle = attachmentField.previewStyle
        self.emptyTitle = attachmentField.emptyTitle
        self.emptyMessage = attachmentField.emptyMessage
        self.maxSizeBytes = attachmentField.maxSizeBytes
        self.uploadMode = attachmentField.uploadMode
        self.submitOnSelection = attachmentField.submitOnSelection
        self.modifiers = attachmentField.modifiers
    }

    public init(from decoder: any Decoder) throws {
        let attachmentField = try SkeletonAttachmentField(from: decoder)
        self.init(attachmentField: attachmentField)
    }

    public var attachmentField: SkeletonAttachmentField {
        var field = SkeletonAttachmentField(
            title: title,
            subtitle: subtitle,
            helperText: helperText,
            valueKeypath: valueKeypath,
            stateKeypath: stateKeypath,
            actionKeypath: actionKeypath,
            acceptedContentTypes: acceptedContentTypes,
            preferredKinds: preferredKinds,
            allowsMultiple: allowsMultiple,
            isRequired: isRequired,
            supportsDrop: supportsDrop,
            previewStyle: previewStyle,
            emptyTitle: emptyTitle,
            emptyMessage: emptyMessage,
            maxSizeBytes: maxSizeBytes,
            uploadMode: uploadMode,
            submitOnSelection: submitOnSelection,
            modifiers: modifiers
        )
        field.id = id
        return field
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .FileUpload)
        try elementContainer.encodeIfPresent(self.title, forKey: .title)
        try elementContainer.encodeIfPresent(self.subtitle, forKey: .subtitle)
        try elementContainer.encodeIfPresent(self.helperText, forKey: .helperText)
        try elementContainer.encodeIfPresent(self.valueKeypath, forKey: .valueKeypath)
        try elementContainer.encodeIfPresent(self.stateKeypath, forKey: .stateKeypath)
        try elementContainer.encodeIfPresent(self.actionKeypath, forKey: .actionKeypath)
        try elementContainer.encodeIfPresent(self.acceptedContentTypes, forKey: .acceptedContentTypes)
        try elementContainer.encodeIfPresent(self.preferredKinds, forKey: .preferredKinds)
        try elementContainer.encodeIfPresent(self.allowsMultiple, forKey: .allowsMultiple)
        try elementContainer.encodeIfPresent(self.isRequired, forKey: .isRequired)
        try elementContainer.encodeIfPresent(self.supportsDrop, forKey: .supportsDrop)
        try elementContainer.encodeIfPresent(self.previewStyle, forKey: .previewStyle)
        try elementContainer.encodeIfPresent(self.emptyTitle, forKey: .emptyTitle)
        try elementContainer.encodeIfPresent(self.emptyMessage, forKey: .emptyMessage)
        try elementContainer.encodeIfPresent(self.maxSizeBytes, forKey: .maxSizeBytes)
        try elementContainer.encodeIfPresent(self.uploadMode, forKey: .uploadMode)
        try elementContainer.encodeIfPresent(self.submitOnSelection, forKey: .submitOnSelection)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}
