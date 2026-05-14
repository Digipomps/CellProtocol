// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  SkeletonDescription.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 22/10/2024.
//
import Foundation

public typealias SkeletonElementList = [SkeletonElement]
public typealias SkeletonElementObject = [String: SkeletonElement]

public enum SkeletonMotionHint: String, Codable, CaseIterable {
    case appear
    case expand
    case collapse
    case minimize
    case restore
    case replace
    case emphasize
}

public struct SkeletonModifiers: Codable {
    public var padding: Double?
    public var maxWidthInfinity: Bool?
    public var maxHeightInfinity: Bool?
    public var width: Double?
    public var height: Double?
    public var hAlignment: String? // leading, center, trailing
    public var vAlignment: String? // top, center, bottom
    public var background: String? // hex color like #RRGGBBAA or #RRGGBB
    public var cornerRadius: Double?
    public var shadowRadius: Double?
    public var shadowX: Double?
    public var shadowY: Double?
    public var shadowColor: String?
    public var borderWidth: Double?
    public var borderColor: String?
    public var opacity: Double?
    public var hidden: Bool?
    
    public var foregroundColor: String?
    public var fontStyle: String?
    public var fontSize: Double?
    public var fontWeight: String?
    public var lineLimit: Int?
    public var multilineTextAlignment: String?
    public var minimumScaleFactor: Double?
    public var styleRole: String?
    public var styleClasses: [String]?
    public var motionHint: SkeletonMotionHint?
    public var motionSourceRole: String?
    public var draggableRole: String?
    public var dragPayloadKeypath: String?
    public var dragPreviewRole: String?
    public var accessibilityDragLabel: String?
    public var dropTargetRole: String?
    public var acceptedDragRoles: [String]?
    public var dropActionKeypath: String?
    public var dropIntents: [String]?
    public var dropValidationStateKeypath: String?
    public var dropDeniedReasonKeypath: String?
    public var accessibilityDropLabel: String?

    public init() {}
}

public struct SkeletonImage : Codable, Identifiable {
    public var id = UUID()
    
    public var url: URL?
    public var name: String?
    public var type: String? // png, jpeg, gif
    public var resizable = false
    public var scaledToFit = false
    public var padding: Double?
    public var modifiers: SkeletonModifiers?
    
    public init(name: String) {
        self.name = name
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let urlString = try container.decodeIfPresent(String.self, forKey: .url) {
            self.url = URL(string: urlString)
        }
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        
        if container.contains(.resizable) {
            resizable = try container.decode(Bool.self, forKey: .resizable)
        }
        
        if container.contains(.scaledToFit) {
            scaledToFit = try container.decode(Bool.self, forKey: .scaledToFit)
        }
        
        if container.contains(.padding) {
            self.padding = try container.decode(Double.self, forKey: .padding)
        }
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public enum CodingKeys: CodingKey {
        //        case id
        case url
        case name
        case type
        case resizable
        case scaledToFit
        case padding
        case modifiers
        case Image
    }
    
    enum ElementKey: CodingKey { case Image }

    
    public func encode(to encoder: any Encoder) throws {
//        print("Encode SkeletonImage")
        var container = encoder.container(keyedBy: ElementKey.self)
        
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self,
                                                              forKey: .Image)
        //        try container.encode(self.id, forKey: .id)
        try elementContainer.encodeIfPresent(self.url, forKey: .url)
        try elementContainer.encodeIfPresent(self.name, forKey: .name)
        try elementContainer.encodeIfPresent(self.type, forKey: .type)
        if self.resizable {
            try elementContainer.encode(self.resizable, forKey: .resizable)
        }
        if self.scaledToFit {
            try elementContainer.encode(self.scaledToFit, forKey: .scaledToFit)
        }
        try elementContainer.encodeIfPresent(self.padding, forKey: .padding)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonSpacer : Codable, Identifiable {
    public var id = UUID()
    public var width: Double?
    public var modifiers: SkeletonModifiers?
    
    public enum CodingKeys: CodingKey {
        //        case id
        case width
        case modifiers
    }
    enum ElementKey: CodingKey { case Spacer }
    
    public init() {
        
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.width = try container.decodeIfPresent(Double.self, forKey: .width)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public func encode(to encoder: any Encoder) throws {
//        print("Encode SkeletonSpacer")
        var container = encoder.container(keyedBy: ElementKey.self)
        
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self,
                                                         forKey: .Spacer)
        if width != nil {
            
            try elementContainer.encode(self.width, forKey: .width)
            
        }
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
    
}


public struct SkeletonText: Codable, Identifiable {
    public var id = UUID()
    public var text: String?
    public var url: URL?
    public var keypath: String?
    public var modifiers: SkeletonModifiers?
      
    public enum CodingKeys: CodingKey {
        //        case id
        case url
        case text
        case resizable
        case scaledToFit
        case keypath
        case modifiers
    }
    enum ElementKey: CodingKey { case Text }
    
    public init(text: String) {
        self.text = text
    }
    
    public init(url: URL) {
        self.url = url
    }
    
    public init(keypath: String) {
        self.keypath = keypath
    }
    
    private func stringValue(from value: ValueType) -> String {
        switch value {
        case .string(let string):
            return string
        case .integer(let integer):
            return String(integer)
        case .number(let number):
            return String(number)
        case .float(let float):
            return String(float)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return "null"
        default:
            return (try? value.jsonString()) ?? "Unsupported value"
        }
    }

    private func asyncContentFailureMessage(for error: Error) -> String {
        let detail = String(describing: error)
        let normalized = detail.lowercased()

        if normalized.contains("bad response from the server") ||
            normalized.contains("502") ||
            normalized.contains("notconnected") ||
            normalized.contains("transportunavailable") {
            return "Tjenesten er midlertidig utilgjengelig. Prøv igjen om litt."
        }

        if normalized.contains("timeout") {
            return "Det tok for lang tid å hente innhold. Prøv igjen."
        }

        if normalized.contains("notfound") {
            return "Innholdet er ikke tilgjengelig akkurat nå."
        }

        return "Getting content failed with error: \(error)"
    }

    public func asyncContent(userInfoValue: ValueType? = nil, requester explicitRequester: Identity? = nil) async -> String {
        
        if userInfoValue != nil && keypath != nil {
            switch userInfoValue {
            case .string(let string):
                return string
            case .float(let float):
                return String(float)
            case .integer(let integer):
                return String(integer)
            case .number(let integer):
                return String(integer)
            case .object(let object):
                if let keypath {
                    if let returnObjectValue = try? object.get(keypath: keypath),
                    let responseString = try? returnObjectValue.jsonString() {
                        return responseString
                    } else {
                        return "get \(keypath) failed"
                    }
                    
                }
            default:
                return "Text asyncContent case not implemented. userInfoValue: \(String(describing: userInfoValue))"
            }
            
            
        } else if text != nil {
            return text ?? "err"
        } else if url != nil || keypath != nil {
            if let resolver = CellBase.defaultCellResolver,
               let vault = CellBase.defaultIdentityVault {
                
                do {
                    let fetchURL: URL?
                    if let url {
                        fetchURL = url
                    } else if let keypath, keypath.hasPrefix("cell://") {
                        fetchURL = URL(string: keypath)
                    } else {
                        fetchURL = URL(string: "cell:///Porthole")
                    }

                    let identity: Identity?
                    if let explicitRequester {
                        identity = explicitRequester
                    } else {
                        identity = await vault.identity(for: "private", makeNewIfNotFound: true)
                    }

                    if let fetchURL,
                       let identity {
                        let pathComponents = fetchURL.pathComponents
                        guard pathComponents.count > 1 else {
                            return "failure"
                        }

                        let cellName = pathComponents[1]
                        let endpoint: String
                        if let host = fetchURL.host, host.isEmpty == false {
                            endpoint = "cell://\(host)/\(cellName)"
                        } else {
                            endpoint = "cell:///\(cellName)"
                        }
                        CellBase.diagnosticLog("SkeletonText loading cellName=\(cellName) components=\(pathComponents)", domain: .skeleton)
                        let porthole = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: identity)
                        if let meddlePorthole = porthole as? Meddle {
                            let resolvedKeypath: String?
                            if url != nil {
                                resolvedKeypath = pathComponents.count > 2 ? fetchURL.lastPathComponent : nil
                            } else if let keypath, keypath.hasPrefix("cell://") {
                                resolvedKeypath = pathComponents.count > 2 ? fetchURL.lastPathComponent : nil
                            } else {
                                resolvedKeypath = keypath
                            }

                            if let resolvedKeypath, resolvedKeypath.isEmpty == false {
                                CellBase.diagnosticLog("SkeletonText loading keypath=\(resolvedKeypath)", domain: .skeleton)
                                let fetchedValue = try await meddlePorthole.get(keypath: resolvedKeypath, requester: identity)
                                CellBase.diagnosticLog("SkeletonText fetched content for keypath=\(resolvedKeypath)", domain: .skeleton)
                                return stringValue(from: fetchedValue)
                            }
                        }
                    }
                } catch {
                    CellBase.diagnosticLog("SkeletonText asyncContent failed with error: \(error)", domain: .skeleton)
                    return asyncContentFailureMessage(for: error)
                }
            } else {
                CellBase.diagnosticLog("SkeletonText asyncContent missing resolver or vault", domain: .skeleton)
            }
        }
        return "failure"
    }
    
    
    public init(from decoder: any Decoder) throws {
//        print("Decode SkeletonText")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        if let urlString = try container.decodeIfPresent(String.self, forKey: .url) {
            self.url = URL(string: urlString)
        }
        self.keypath = try container.decodeIfPresent(String.self, forKey: .keypath)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        //        try container.encode(self.id, forKey: .id)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self,
                                                         forKey: .Text)
        
        try elementContainer.encodeIfPresent(self.url, forKey: .url)
        try elementContainer.encodeIfPresent(self.text, forKey: .text)
        try elementContainer.encodeIfPresent(self.keypath, forKey: .keypath)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
    
}

public struct SkeletonAutocomplete: Codable, Equatable {
    public var queryActionKeypath: String?
    public var suggestionsKeypath: String?
    public var optionLabelKeypath: String?
    public var optionValueKeypath: String?
    public var optionDetailKeypaths: [String]?
    public var selectionActionKeypath: String?
    public var debounceMilliseconds: Int
    public var minCharacters: Int
    public var allowsCustomValue: Bool

    enum CodingKeys: CodingKey {
        case queryActionKeypath
        case suggestionsKeypath
        case optionLabelKeypath
        case optionValueKeypath
        case optionDetailKeypaths
        case selectionActionKeypath
        case debounceMilliseconds
        case minCharacters
        case allowsCustomValue
    }

    public init(
        queryActionKeypath: String? = nil,
        suggestionsKeypath: String? = nil,
        optionLabelKeypath: String? = nil,
        optionValueKeypath: String? = nil,
        optionDetailKeypaths: [String]? = nil,
        selectionActionKeypath: String? = nil,
        debounceMilliseconds: Int = 250,
        minCharacters: Int = 0,
        allowsCustomValue: Bool = true
    ) {
        self.queryActionKeypath = queryActionKeypath
        self.suggestionsKeypath = suggestionsKeypath
        self.optionLabelKeypath = optionLabelKeypath
        self.optionValueKeypath = optionValueKeypath
        self.optionDetailKeypaths = optionDetailKeypaths
        self.selectionActionKeypath = selectionActionKeypath
        self.debounceMilliseconds = debounceMilliseconds
        self.minCharacters = minCharacters
        self.allowsCustomValue = allowsCustomValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.queryActionKeypath = try container.decodeIfPresent(String.self, forKey: .queryActionKeypath)
        self.suggestionsKeypath = try container.decodeIfPresent(String.self, forKey: .suggestionsKeypath)
        self.optionLabelKeypath = try container.decodeIfPresent(String.self, forKey: .optionLabelKeypath)
        self.optionValueKeypath = try container.decodeIfPresent(String.self, forKey: .optionValueKeypath)
        self.optionDetailKeypaths = try container.decodeIfPresent([String].self, forKey: .optionDetailKeypaths)
        self.selectionActionKeypath = try container.decodeIfPresent(String.self, forKey: .selectionActionKeypath)
        self.debounceMilliseconds = try container.decodeIfPresent(Int.self, forKey: .debounceMilliseconds) ?? 250
        self.minCharacters = try container.decodeIfPresent(Int.self, forKey: .minCharacters) ?? 0
        self.allowsCustomValue = try container.decodeIfPresent(Bool.self, forKey: .allowsCustomValue) ?? true
    }
}

public struct SkeletonTextField: Codable, Identifiable {
    public var id = UUID()
    public var text: String?
    public var sourceKeypath: String?
    public var targetKeypath: String?
    public var placeholder: String?
    public var autocomplete: SkeletonAutocomplete?
    public var modifiers: SkeletonModifiers?

    public enum CodingKeys: CodingKey {
        case text
        case sourceKeypath
        case targetKeypath
        case placeholder
        case autocomplete
        case modifiers
    }
    enum ElementKey: CodingKey { case TextField }

    public init(
        text: String? = nil,
        sourceKeypath: String? = nil,
        targetKeypath: String? = nil,
        placeholder: String? = nil,
        autocomplete: SkeletonAutocomplete? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.text = text
        self.sourceKeypath = sourceKeypath
        self.targetKeypath = targetKeypath
        self.placeholder = placeholder
        self.autocomplete = autocomplete
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.sourceKeypath = try container.decodeIfPresent(String.self, forKey: .sourceKeypath)
        self.targetKeypath = try container.decodeIfPresent(String.self, forKey: .targetKeypath)
        self.placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        self.autocomplete = try container.decodeIfPresent(SkeletonAutocomplete.self, forKey: .autocomplete)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .TextField)
        try elementContainer.encodeIfPresent(self.text, forKey: .text)
        try elementContainer.encodeIfPresent(self.sourceKeypath, forKey: .sourceKeypath)
        try elementContainer.encodeIfPresent(self.targetKeypath, forKey: .targetKeypath)
        try elementContainer.encodeIfPresent(self.placeholder, forKey: .placeholder)
        try elementContainer.encodeIfPresent(self.autocomplete, forKey: .autocomplete)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
    
    public func asyncContent(userInfoValue: ValueType? = nil) async -> String {
        // Behavior mirrors SkeletonText.asyncContent: prefer provided userInfoValue/keypath, fallback to static text
        if let userInfoValue, let sourceKeypath {
            switch userInfoValue {
            case .string(let string):
                return string
            case .float(let float):
                return String(float)
            case .integer(let integer):
                return String(integer)
            case .number(let integer):
                return String(integer)
            case .object(let object):
                if let returnObjectValue = try? object.get(keypath: sourceKeypath),
                   let responseString = try? returnObjectValue.jsonString() {
                    return responseString
                } else {
                    return "get \(sourceKeypath) failed"
                }
            default:
                return "TextField asyncContent case not implemented. userInfoValue: \(String(describing: userInfoValue))"
            }
        } else if let text {
            return text
        }
        return ""
    }
}

public enum SkeletonTextAreaEditorMode: String, Codable {
    case plain
    case richMarkdown
}

public struct SkeletonTextArea: Codable, Identifiable {
    public var id = UUID()
    public var text: String?
    public var sourceKeypath: String?
    public var targetKeypath: String?
    public var placeholder: String?
    public var minLines: Int?
    public var maxLines: Int?
    public var submitOnEnter: Bool?
    public var editorMode: SkeletonTextAreaEditorMode?
    public var modifiers: SkeletonModifiers?

    public enum CodingKeys: CodingKey {
        case text
        case sourceKeypath
        case targetKeypath
        case placeholder
        case minLines
        case maxLines
        case submitOnEnter
        case editorMode
        case modifiers
    }
    enum ElementKey: CodingKey { case TextArea }

    public init(
        text: String? = nil,
        sourceKeypath: String? = nil,
        targetKeypath: String? = nil,
        placeholder: String? = nil,
        minLines: Int? = nil,
        maxLines: Int? = nil,
        submitOnEnter: Bool? = nil,
        editorMode: SkeletonTextAreaEditorMode? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.text = text
        self.sourceKeypath = sourceKeypath
        self.targetKeypath = targetKeypath
        self.placeholder = placeholder
        self.minLines = minLines
        self.maxLines = maxLines
        self.submitOnEnter = submitOnEnter
        self.editorMode = editorMode
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.sourceKeypath = try container.decodeIfPresent(String.self, forKey: .sourceKeypath)
        self.targetKeypath = try container.decodeIfPresent(String.self, forKey: .targetKeypath)
        self.placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        self.minLines = try container.decodeIfPresent(Int.self, forKey: .minLines)
        self.maxLines = try container.decodeIfPresent(Int.self, forKey: .maxLines)
        self.submitOnEnter = try container.decodeIfPresent(Bool.self, forKey: .submitOnEnter)
        self.editorMode = try container.decodeIfPresent(SkeletonTextAreaEditorMode.self, forKey: .editorMode)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .TextArea)
        try elementContainer.encodeIfPresent(self.text, forKey: .text)
        try elementContainer.encodeIfPresent(self.sourceKeypath, forKey: .sourceKeypath)
        try elementContainer.encodeIfPresent(self.targetKeypath, forKey: .targetKeypath)
        try elementContainer.encodeIfPresent(self.placeholder, forKey: .placeholder)
        try elementContainer.encodeIfPresent(self.minLines, forKey: .minLines)
        try elementContainer.encodeIfPresent(self.maxLines, forKey: .maxLines)
        try elementContainer.encodeIfPresent(self.submitOnEnter, forKey: .submitOnEnter)
        try elementContainer.encodeIfPresent(self.editorMode, forKey: .editorMode)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }

    public func asyncContent(userInfoValue: ValueType? = nil) async -> String {
        let proxy = SkeletonTextField(
            text: text,
            sourceKeypath: sourceKeypath,
            targetKeypath: targetKeypath,
            placeholder: placeholder,
            modifiers: modifiers
        )
        return await proxy.asyncContent(userInfoValue: userInfoValue)
    }
}

public struct SkeletonHStack: Codable, Identifiable {
    public var id = UUID()
    public var elements: SkeletonElementList
    public var spacing: Double?
    public var modifiers: SkeletonModifiers?
    
    enum ElementKey: CodingKey { case HStack }
    enum CodingKeys: CodingKey {
        case elements
        case spacing
        case modifiers
    }
    
    public init(elements: SkeletonElementList, spacing: Double? = nil, modifiers: SkeletonModifiers? = nil) {
        self.elements = elements
        self.spacing = spacing
        self.modifiers = modifiers
    }
    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.elements) || container.contains(.spacing) || container.contains(.modifiers) {
            self.elements = try container.decodeIfPresent(SkeletonElementList.self, forKey: .elements) ?? SkeletonElementList()
            self.spacing = try container.decodeIfPresent(Double.self, forKey: .spacing)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
            return
        }
        
         do {
             var unkeyedContainer = try decoder.unkeyedContainer()
             var elements = SkeletonElementList()
             while unkeyedContainer.isAtEnd != true {
                 do {
                     let decodedObject = try unkeyedContainer.decode(SkeletonElement.self)
                     elements.append(decodedObject)
                 } catch { CellBase.diagnosticLog("Decoding SkeletonHStack element failed with error: \(error)", domain: .skeleton) }
             }
             self.elements = elements
             self.spacing = nil
             self.modifiers = nil
             return
         } catch {
             CellBase.diagnosticLog("Decoding SkeletonHStack failed with error: \(error)", domain: .skeleton)
             elements = SkeletonElementList() // hmmmm
             self.spacing = nil
             self.modifiers = nil
         }
         
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        if spacing == nil && modifiers == nil {
            var elementContainer = container.nestedUnkeyedContainer(forKey: .HStack)
            for element in elements {
                try elementContainer.encode(element)
            }
            return
        }

        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .HStack)
        try elementContainer.encode(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.spacing, forKey: .spacing)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }

}

public struct SkeletonVStack: Codable, Identifiable {
    public var id = UUID()
    public var elements: SkeletonElementList
    public var spacing: Double?
    public var modifiers: SkeletonModifiers?
    
    enum ElementKey: CodingKey { case VStack }
    public enum CodingKeys: CodingKey {
        case id
        case elements
        case spacing
        case modifiers
    }
    
    public init(elements: SkeletonElementList, spacing: Double? = nil, modifiers: SkeletonModifiers? = nil) {
        self.elements = elements
        self.spacing = spacing
        self.modifiers = modifiers
    }
    
    public init(from decoder: any Decoder) throws {

        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.elements) || container.contains(.spacing) || container.contains(.modifiers) {
            self.elements = try container.decodeIfPresent(SkeletonElementList.self, forKey: .elements) ?? SkeletonElementList()
            self.spacing = try container.decodeIfPresent(Double.self, forKey: .spacing)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
            return
        }

        elements = SkeletonElementList()
         do {
             
             var unkeyedContainer = try decoder.unkeyedContainer()
             
             while unkeyedContainer.isAtEnd != true {
                 do {
                     let decodedObject = try unkeyedContainer.decode(SkeletonElement.self)
                     elements.append(decodedObject)
//                     print("decodedObject: \(decodedObject)")
                 } catch {
                     CellBase.diagnosticLog("Decoding SkeletonVStack element failed with error: \(error)", domain: .skeleton)
                 }
             }
             self.spacing = nil
             self.modifiers = nil
             return
         } catch {
             CellBase.diagnosticLog("Decoding SkeletonVStack failed with error: \(error)", domain: .skeleton)
             self.spacing = nil
             self.modifiers = nil
         }
         
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        if spacing == nil && modifiers == nil {
            var elementContainer = container.nestedUnkeyedContainer(forKey: .VStack)
            for element in elements {
                try elementContainer.encode(element)
            }
            return
        }

        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .VStack)
        try elementContainer.encode(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.spacing, forKey: .spacing)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public enum SkeletonListSelectionMode: String, Codable {
    case none
    case single
    case multiple
}

public enum SkeletonListSelectionPayloadMode: String, Codable {
    case item
    case itemID = "item_id"
    case selectedItems = "selected_items"
    case selectedIDs = "selected_ids"
}

public enum SkeletonListSelectionTrigger: String, Codable {
    case select
    case deselect
    case activate
}

public enum SkeletonListConfigurationError: Error {
    case missingSelectionValueKeypath(SkeletonListSelectionPayloadMode)
}

public enum SkeletonListSelectionPayloadError: Error {
    case invalidSelectionIndex(Int)
    case missingSelectionValue(String)
}

public struct SkeletonList: Codable, Identifiable {
    public var id = UUID()
    public var elements: ValueTypeList
    public var topic: String? // Which topic to update from
    public var keypath: String?
    public var filterTypes: [String]?
    public var selectionMode: SkeletonListSelectionMode?
    public var selectionValueKeypath: String?
    public var selectionStateKeypath: String?
    public var selectionActionKeypath: String?
    public var activationActionKeypath: String?
    public var selectionPayloadMode: SkeletonListSelectionPayloadMode?
    public var allowsEmptySelection: Bool?
    
    public var flowElementSkeleton: SkeletonVStack?
    public var modifiers: SkeletonModifiers?
    
    enum ElementKey: CodingKey { case List }
    
    enum CodingKeys: CodingKey {
        case topic
        case keypath
        case filterTypes
        case selectionMode
        case selectionValueKeypath
        case selectionStateKeypath
        case selectionActionKeypath
        case activationActionKeypath
        case selectionPayloadMode
        case allowsEmptySelection
        case flowElementSkeleton
        case elements
        case modifiers
    }
    
    public init(elements: ValueTypeList, topic: String? = nil, keypath: String? = nil, flowElementSkeleton: SkeletonVStack? = nil) {
        self.elements = elements
        self.topic = topic
        self.keypath = keypath
        self.flowElementSkeleton = flowElementSkeleton
    }
    
    public init(topic: String? = nil, keypath: String? = nil, flowElementSkeleton: SkeletonVStack? = nil) {
        self.elements = ValueTypeList()
        self.topic = topic
        self.keypath = keypath
        self.flowElementSkeleton = flowElementSkeleton
    }
    
    
    public init(from decoder: any Decoder) throws {
//        print("Decode SkeletonList")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        //        self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)

        self.flowElementSkeleton = nil

        let tempDecodedSkeletonVStackAsElement = try container.decodeIfPresent(SkeletonElement.self, forKey: .flowElementSkeleton)
        
        if case let .VStack(skeletonVStack) = tempDecodedSkeletonVStackAsElement {
            self.flowElementSkeleton = skeletonVStack
        }
        
        self.elements = ValueTypeList()
        if let valueList = try container.decodeIfPresent(ValueTypeList.self, forKey: .elements) {
            self.elements = valueList
        }
        self.topic = try container.decodeIfPresent(String.self, forKey: .topic)
        self.keypath = try container.decodeIfPresent(String.self, forKey: .keypath)
        self.filterTypes = try container.decodeIfPresent([String].self, forKey: .filterTypes)
        self.selectionMode = try container.decodeIfPresent(SkeletonListSelectionMode.self, forKey: .selectionMode)
        self.selectionValueKeypath = try container.decodeIfPresent(String.self, forKey: .selectionValueKeypath)
        self.selectionStateKeypath = try container.decodeIfPresent(String.self, forKey: .selectionStateKeypath)
        self.selectionActionKeypath = try container.decodeIfPresent(String.self, forKey: .selectionActionKeypath)
        self.activationActionKeypath = try container.decodeIfPresent(String.self, forKey: .activationActionKeypath)
        self.selectionPayloadMode = try container.decodeIfPresent(SkeletonListSelectionPayloadMode.self, forKey: .selectionPayloadMode)
        self.allowsEmptySelection = try container.decodeIfPresent(Bool.self, forKey: .allowsEmptySelection)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)

        try validateSelectionConfiguration()
    }
    
    
    // Is this the wrong place for this method?
    public func getElements() async throws -> ValueTypeList {
        if let resolver = CellBase.defaultCellResolver,
           let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: false),
           let keypath = self.keypath,
           let cellURL = try? urlFromKeypath(keypath: keypath)
        {
        
            let inititalElements = try await resolver.get(from: cellURL, requester: requester)
            guard case .list(let valueTypeList) = inititalElements else {
                print("Error. ValueType returned from get \(cellURL) not List")
                return ValueTypeList()
            }
            return valueTypeList
        }
        
        return ValueTypeList()
    }
    
    public func encode(to encoder: any Encoder) throws {
        try validateSelectionConfiguration()
        
        var elementsContainer = encoder.container(keyedBy: ElementKey.self)
        
        var container = elementsContainer.nestedContainer(keyedBy: CodingKeys.self, forKey: .List)
        
        try container.encodeIfPresent(self.topic, forKey: .topic)
        try container.encodeIfPresent(self.keypath, forKey: .keypath)
        try container.encodeIfPresent(self.filterTypes, forKey: .filterTypes)
        try container.encodeIfPresent(self.selectionMode, forKey: .selectionMode)
        try container.encodeIfPresent(self.selectionValueKeypath, forKey: .selectionValueKeypath)
        try container.encodeIfPresent(self.selectionStateKeypath, forKey: .selectionStateKeypath)
        try container.encodeIfPresent(self.selectionActionKeypath, forKey: .selectionActionKeypath)
        try container.encodeIfPresent(self.activationActionKeypath, forKey: .activationActionKeypath)
        try container.encodeIfPresent(self.selectionPayloadMode, forKey: .selectionPayloadMode)
        try container.encodeIfPresent(self.allowsEmptySelection, forKey: .allowsEmptySelection)
        if let rowSkeleton = self.flowElementSkeleton {
            try container.encode(SkeletonElement.VStack(rowSkeleton), forKey: .flowElementSkeleton)
        }
        try container.encodeIfPresent(self.elements, forKey: .elements)
        try container.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }

    private func validateSelectionConfiguration() throws {
        switch self.selectionPayloadMode {
        case .itemID?, .selectedIDs?:
            if self.selectionValueKeypath?.isEmpty != false {
                throw SkeletonListConfigurationError.missingSelectionValueKeypath(self.selectionPayloadMode!)
            }
        default:
            break
        }
    }

    public func selectionPayload(trigger: SkeletonListSelectionTrigger, rows: [ValueType], selectedIndices: [Int]) throws -> ValueType {
        try validateSelectionConfiguration()

        let normalizedIndices = Array(Set(selectedIndices)).sorted()
        for index in normalizedIndices where rows.indices.contains(index) == false {
            throw SkeletonListSelectionPayloadError.invalidSelectionIndex(index)
        }

        let effectiveSelectionMode: SkeletonListSelectionMode = {
            switch self.selectionMode {
            case .multiple?:
                return .multiple
            case .single?:
                return .single
            default:
                return normalizedIndices.count > 1 ? .multiple : .single
            }
        }()

        let effectivePayloadMode: SkeletonListSelectionPayloadMode = {
            if let selectionPayloadMode {
                return selectionPayloadMode
            }
            switch effectiveSelectionMode {
            case .multiple:
                return .selectedItems
            case .single, .none:
                return .item
            }
        }()

        var payload: Object = [
            "selectionMode": .string(effectiveSelectionMode.rawValue),
            "trigger": .string(trigger.rawValue)
        ]

        switch effectiveSelectionMode {
        case .multiple:
            let selectedRows = try normalizedIndices.map { index in
                try selectionPayloadValue(from: rows[index], payloadMode: effectivePayloadMode)
            }
            payload["selectedIndices"] = .list(normalizedIndices.map { .integer($0) })
            payload["selected"] = .list(selectedRows)
        case .single, .none:
            let selectedIndex = normalizedIndices.first
            payload["selectedIndex"] = selectedIndex.map { .integer($0) } ?? .null
            if let selectedIndex {
                payload["selected"] = try selectionPayloadValue(from: rows[selectedIndex], payloadMode: effectivePayloadMode)
            } else {
                payload["selected"] = .null
            }
        }

        return .object(payload)
    }

    private func selectionPayloadValue(from row: ValueType, payloadMode: SkeletonListSelectionPayloadMode) throws -> ValueType {
        switch payloadMode {
        case .item, .selectedItems:
            return row
        case .itemID, .selectedIDs:
            guard let selectionValueKeypath,
                  let selectedValue = row[selectionValueKeypath] else {
                throw SkeletonListSelectionPayloadError.missingSelectionValue(selectionValueKeypath ?? "")
            }
            return selectedValue
        }
    }
    
    func urlFromKeypath(keypath: String) throws -> URL {
        var url: URL?
        if keypath.hasPrefix("cell://") {
            url = URL(string: keypath)
        } else {
            url = URL(string: "cell:///Porthole/\(keypath)")
        }
        if let url = url {
            return url
        }
        throw URLKeypathError.badURL
    }
}

public enum URLKeypathError: Error {
    case badURL
}

public struct SkeletonObject: Codable, Identifiable {
    public var id = UUID()
    public var elements: SkeletonElementObject
    public var modifiers: SkeletonModifiers?
    
    public init(elements: SkeletonElementObject, modifiers: SkeletonModifiers? = nil) {
        self.elements = elements
        self.modifiers = modifiers  
    }

    public static func empty(modifiers: SkeletonModifiers? = nil) -> SkeletonObject {
        SkeletonObject(elements: [:], modifiers: modifiers)
    }
    
    enum ElementKey: CodingKey { case Object }
    enum CodingKeys: CodingKey {
        case elements
        case modifiers
    }

    public init(from decoder: any Decoder) throws {
        // Prefer direct decoding when elements are present (legacy unwrapped form)
        let directContainer = try decoder.container(keyedBy: CodingKeys.self)
        if directContainer.contains(.elements) {
            self.elements = try directContainer.decode(SkeletonElementObject.self, forKey: .elements)
            self.modifiers = try directContainer.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
            return
        }
        // Otherwise decode from the wrapped { "Object": { ... } } form
        let wrapper = try decoder.container(keyedBy: ElementKey.self)
        let container = try wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .Object)
        self.elements = try container.decode(SkeletonElementObject.self, forKey: .elements)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Object)
        try elementContainer.encode(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonCellReference: Codable, Identifiable {
    public var id = UUID()
    public var keypath: String
    public var topic: String
    public var filterTypes: [String]?
    public var flowElementSkeleton: SkeletonVStack?
    public var scaledToFit = false
    public var padding: Double?
    public var modifiers: SkeletonModifiers?
    
    public enum CodingKeys: CodingKey {
        case id
        case keypath
        case topic
        case filterTypes
        case flowElementSkeleton
        case scaledToFit
        case padding
        case modifiers
    }
    
    enum ElementKey: CodingKey { case Reference }
    
    public init(keypath: String, topic: String) {
        self.keypath = keypath
        self.topic = topic
        
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
//        self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)
//        print("Decode SkeletonCellReference")

        if let id =  try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = id
        }
        self.keypath = try container.decode(String.self, forKey: .keypath)
        self.topic = try container.decode(String.self, forKey: .topic)
        self.filterTypes = try container.decodeIfPresent([String].self, forKey: .filterTypes)
        let tempDecodedSkeletonVStackAsElement = try container.decodeIfPresent(SkeletonElement.self, forKey: .flowElementSkeleton)
        
        if case let .VStack(skeletonVStack) = tempDecodedSkeletonVStackAsElement {
            self.flowElementSkeleton = skeletonVStack
        }
//        self.flowElementSkeleton = try container.decodeIfPresent(SkeletonVStack.self, forKey: .flowElementSkeleton)
        if container.contains(.scaledToFit) {
            scaledToFit = try container.decode(Bool.self, forKey: .scaledToFit)
        }
        
        if container.contains(.padding) {
            self.padding = try container.decode(Double.self, forKey: .padding)
        }
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
  
    public func encode(to encoder: any Encoder) throws {
//        print("Encode SkeletonReference")
        var container = encoder.container(keyedBy: ElementKey.self)
        
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self,
                                                         forKey: .Reference)
        
        try elementContainer.encode(self.keypath, forKey: .keypath)
        try elementContainer.encode(self.topic, forKey: .topic)
        try elementContainer.encodeIfPresent(self.filterTypes, forKey: .filterTypes)
        try elementContainer.encode(self.flowElementSkeleton, forKey: .flowElementSkeleton)
        if self.scaledToFit {
            try elementContainer.encode(self.scaledToFit, forKey: .scaledToFit)
        }
        if self.padding != nil {
            try elementContainer.encode(self.padding, forKey: .padding)
        }
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonButton: Codable, Identifiable {
    public var id = UUID()
    public var keypath: String
    public var label: String
    public var url: String?
    public var payload: ValueType?
    public var modifiers: SkeletonModifiers?
    
    public init(keypath: String, label: String, url: String? = nil, payload: ValueType? = nil ) {
        self.keypath = keypath
        self.label = label
        self.url = url
        self.payload = payload
    }
    
    public enum CodingKeys: CodingKey {
        case id
        case keypath
        case label
        case url
        case payload
        case modifiers
    }
    
    enum ElementKey: CodingKey { case Button }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        //        self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)
//        print("Decode SkeletonButton")
        
        if let id =  try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = id
        }
        self.keypath = try container.decode(String.self, forKey: .keypath)
        self.label = try container.decode(String.self, forKey: .label)
        self.url = try container.decodeIfPresent(String.self, forKey: .url)
        self.payload = try container.decodeIfPresent(ValueType.self, forKey: .payload)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        
        
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self,
                                                         forKey: .Button)
        
        try elementContainer.encode(self.keypath, forKey: .keypath)
        try elementContainer.encode(self.label, forKey: .label)
        try elementContainer.encodeIfPresent(self.url, forKey: .url)
        try elementContainer.encodeIfPresent(self.payload, forKey: .payload)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
        
    
    public func execute(requester explicitRequester: Identity? = nil) async -> ValueType? {
        guard let resolver = CellBase.defaultCellResolver else {
            return nil
        }

        let requester: Identity?
        if let explicitRequester {
            requester = explicitRequester
        } else if let vault = CellBase.defaultIdentityVault {
            requester = await vault.identity(for: "private", makeNewIfNotFound: true)
        } else {
            requester = nil
        }

        guard let requester else {
            return nil
        }

        do {
            let targetCell = try await resolver.cellAtEndpoint(endpoint: url ?? "cell:///Porthole", requester: requester)
            if let meddleTarget = targetCell as? Meddle {
                if payload != nil {
                    return try await meddleTarget.set(keypath: keypath, value: payload!, requester: requester)
                } else {
                    return try await meddleTarget.get(keypath: keypath, requester: requester)
                }
            }
        } catch {
            print("Execute button failed with error: \(error)")
        }
        return nil
    }
}

public struct SkeletonDivider: Codable, Identifiable {
    public var id = UUID()
    public var modifiers: SkeletonModifiers?
    
    enum CodingKeys: CodingKey {
        case modifiers
    }
    enum ElementKey: CodingKey { case Divider }
    
    public init() {}
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Divider)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonScrollView: Codable, Identifiable {
    public var id = UUID()
    public var axis: String?
    public var elements: SkeletonElementList
    public var modifiers: SkeletonModifiers?
    
    enum ElementKey: CodingKey { case ScrollView }
    enum CodingKeys: CodingKey {
        case axis
        case elements
        case modifiers
    }
    
    public init(axis: String? = nil, elements: SkeletonElementList) {
        self.axis = axis
        self.elements = elements
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.axis = try container.decodeIfPresent(String.self, forKey: .axis)
        self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .ScrollView)
        try elementContainer.encodeIfPresent(self.axis, forKey: .axis)
        try elementContainer.encode(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonSection: Codable, Identifiable {
    public var id = UUID()
    public var header: SkeletonElement?
    public var footer: SkeletonElement?
    public var content: SkeletonElementList
    public var modifiers: SkeletonModifiers?
    
    enum ElementKey: CodingKey { case Section }
    enum CodingKeys: CodingKey {
        case header
        case footer
        case content
        case modifiers
    }
    
    public init(header: SkeletonElement? = nil, footer: SkeletonElement? = nil, content: SkeletonElementList) {
        self.header = header
        self.footer = footer
        self.content = content
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.header = try container.decodeIfPresent(SkeletonElement.self, forKey: .header)
        self.footer = try container.decodeIfPresent(SkeletonElement.self, forKey: .footer)
        self.content = try container.decode(SkeletonElementList.self, forKey: .content)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Section)
        try elementContainer.encodeIfPresent(self.header, forKey: .header)
        try elementContainer.encodeIfPresent(self.footer, forKey: .footer)
        try elementContainer.encode(self.content, forKey: .content)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonTabPanel: Codable, Identifiable {
    public var id: String
    public var content: SkeletonElementList
    public var modifiers: SkeletonModifiers?

    public enum CodingKeys: CodingKey {
        case id
        case content
        case modifiers
    }

    public init(id: String, content: SkeletonElementList, modifiers: SkeletonModifiers? = nil) {
        self.id = id
        self.content = content
        self.modifiers = modifiers
    }
}

public struct SkeletonTabs: Codable, Identifiable {
    public var id = UUID()
    public var tabsKeypath: String?
    public var activeTabStateKeypath: String
    public var selectionActionKeypath: String?
    public var idKeypath: String
    public var labelKeypath: String
    public var panels: [SkeletonTabPanel]
    public var modifiers: SkeletonModifiers?

    enum ElementKey: CodingKey { case Tabs }
    public enum CodingKeys: CodingKey {
        case id
        case tabsKeypath
        case activeTabStateKeypath
        case selectionActionKeypath
        case idKeypath
        case labelKeypath
        case panels
        case modifiers
    }

    public init(
        id: UUID = UUID(),
        tabsKeypath: String? = nil,
        activeTabStateKeypath: String,
        selectionActionKeypath: String? = nil,
        idKeypath: String = "id",
        labelKeypath: String = "title",
        panels: [SkeletonTabPanel],
        modifiers: SkeletonModifiers? = nil
    ) {
        self.id = id
        self.tabsKeypath = tabsKeypath
        self.activeTabStateKeypath = activeTabStateKeypath
        self.selectionActionKeypath = selectionActionKeypath
        self.idKeypath = idKeypath
        self.labelKeypath = labelKeypath
        self.panels = panels
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        if let last = decoder.codingPath.last, last.stringValue == "Tabs" {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedID { self.id = decodedID }
            self.tabsKeypath = try container.decodeIfPresent(String.self, forKey: .tabsKeypath)
            self.activeTabStateKeypath = try container.decode(String.self, forKey: .activeTabStateKeypath)
            self.selectionActionKeypath = try container.decodeIfPresent(String.self, forKey: .selectionActionKeypath)
            self.idKeypath = try container.decodeIfPresent(String.self, forKey: .idKeypath) ?? "id"
            self.labelKeypath = try container.decodeIfPresent(String.self, forKey: .labelKeypath) ?? "title"
            self.panels = try container.decode([SkeletonTabPanel].self, forKey: .panels)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        } else {
            let wrapper = try decoder.container(keyedBy: ElementKey.self)
            let container = try wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .Tabs)
            let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedID { self.id = decodedID }
            self.tabsKeypath = try container.decodeIfPresent(String.self, forKey: .tabsKeypath)
            self.activeTabStateKeypath = try container.decode(String.self, forKey: .activeTabStateKeypath)
            self.selectionActionKeypath = try container.decodeIfPresent(String.self, forKey: .selectionActionKeypath)
            self.idKeypath = try container.decodeIfPresent(String.self, forKey: .idKeypath) ?? "id"
            self.labelKeypath = try container.decodeIfPresent(String.self, forKey: .labelKeypath) ?? "title"
            self.panels = try container.decode([SkeletonTabPanel].self, forKey: .panels)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Tabs)
        try elementContainer.encode(self.id, forKey: .id)
        try elementContainer.encodeIfPresent(self.tabsKeypath, forKey: .tabsKeypath)
        try elementContainer.encode(self.activeTabStateKeypath, forKey: .activeTabStateKeypath)
        try elementContainer.encodeIfPresent(self.selectionActionKeypath, forKey: .selectionActionKeypath)
        try elementContainer.encode(self.idKeypath, forKey: .idKeypath)
        try elementContainer.encode(self.labelKeypath, forKey: .labelKeypath)
        try elementContainer.encode(self.panels, forKey: .panels)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

// New structs added as per instructions:

public enum SkeletonGridColumnType: String, Codable { case fixed, flexible, adaptive }
public struct SkeletonGridColumn: Codable {
    public var type: SkeletonGridColumnType
    public var value: Double? // for fixed
    public var min: Double?   // for flexible/adaptive
    public var max: Double?   // for flexible/adaptive

    public init(type: SkeletonGridColumnType, value: Double? = nil, min: Double? = nil, max: Double? = nil) {
        self.type = type
        self.value = value
        self.min = min
        self.max = max
    }

    public static func fixed(_ value: Double) -> SkeletonGridColumn {
        SkeletonGridColumn(type: .fixed, value: value)
    }

    public static func flexible(min: Double = 0, max: Double? = nil) -> SkeletonGridColumn {
        SkeletonGridColumn(type: .flexible, min: min, max: max)
    }

    public static func adaptive(min: Double, max: Double? = nil) -> SkeletonGridColumn {
        SkeletonGridColumn(type: .adaptive, min: min, max: max)
    }
}

public struct SkeletonZStack: Codable, Identifiable {
    public var id = UUID()
    public var elements: SkeletonElementList
    public var modifiers: SkeletonModifiers?

    enum ElementKey: CodingKey { case ZStack }
    enum CodingKeys: CodingKey {
        case id
        case elements
        case modifiers
    }

    public init(elements: SkeletonElementList, modifiers: SkeletonModifiers? = nil) {
        self.elements = elements
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        if let last = decoder.codingPath.last, last.stringValue == "ZStack" {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedId = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedId { self.id = decodedId }
            self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        } else {
            let wrapper = try decoder.container(keyedBy: ElementKey.self)
            let container = try wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .ZStack)
            let decodedId = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedId { self.id = decodedId }
            self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .ZStack)
        try elementContainer.encode(self.id, forKey: .id)
        try elementContainer.encode(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonGrid: Codable, Identifiable {
    public var id = UUID()
    public var columns: [SkeletonGridColumn]
    public var spacing: Double?
    public var keypath: String?
    public var itemSkeleton: SkeletonElement?
    public var elements: SkeletonElementList
    public var modifiers: SkeletonModifiers?

    enum ElementKey: CodingKey { case Grid }
    enum CodingKeys: CodingKey {
        case id
        case columns
        case spacing
        case keypath
        case itemSkeleton
        case elements
        case modifiers
    }

    public init(
        columns: [SkeletonGridColumn],
        spacing: Double? = nil,
        keypath: String? = nil,
        itemSkeleton: SkeletonElement? = nil,
        elements: SkeletonElementList = [],
        modifiers: SkeletonModifiers? = nil
    ) {
        self.columns = columns
        self.spacing = spacing
        self.keypath = keypath
        self.itemSkeleton = itemSkeleton
        self.elements = elements
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        // Try to decode either directly with CodingKeys, or via a nested container under ElementKey.Grid
        if let last = decoder.codingPath.last, last.stringValue == "Grid" {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedId = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedId { self.id = decodedId }
            self.columns = try container.decode([SkeletonGridColumn].self, forKey: .columns)
            self.spacing = try container.decodeIfPresent(Double.self, forKey: .spacing)
            self.keypath = try container.decodeIfPresent(String.self, forKey: .keypath)
            self.itemSkeleton = try container.decodeIfPresent(SkeletonElement.self, forKey: .itemSkeleton)
            self.elements = (try container.decodeIfPresent(SkeletonElementList.self, forKey: .elements)) ?? []
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        } else {
            let wrapper = try decoder.container(keyedBy: ElementKey.self)
            let container = try wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .Grid)
            let decodedId = try container.decodeIfPresent(UUID.self, forKey: .id)
            if let decodedId { self.id = decodedId }
            self.columns = try container.decode([SkeletonGridColumn].self, forKey: .columns)
            self.spacing = try container.decodeIfPresent(Double.self, forKey: .spacing)
            self.keypath = try container.decodeIfPresent(String.self, forKey: .keypath)
            self.itemSkeleton = try container.decodeIfPresent(SkeletonElement.self, forKey: .itemSkeleton)
            self.elements = (try container.decodeIfPresent(SkeletonElementList.self, forKey: .elements)) ?? []
            self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        }
    }

    public func getItems() async throws -> ValueTypeList {
        if let resolver = CellBase.defaultCellResolver,
           let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: false),
           let keypath = self.keypath,
           let cellURL = try? urlFromKeypath(keypath: keypath)
        {
            let initialItems = try await resolver.get(from: cellURL, requester: requester)
            guard case .list(let valueTypeList) = initialItems else {
                print("Error. ValueType returned from get \(cellURL) not List")
                return ValueTypeList()
            }
            return valueTypeList
        }

        return ValueTypeList()
    }

    private func urlFromKeypath(keypath: String) throws -> URL {
        var url: URL?
        if keypath.hasPrefix("cell://") {
            url = URL(string: keypath)
        } else {
            url = URL(string: "cell:///Porthole/\(keypath)")
        }
        if let url {
            return url
        }
        throw URLKeypathError.badURL
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Grid)
        try elementContainer.encode(self.columns, forKey: .columns)
        try elementContainer.encodeIfPresent(self.spacing, forKey: .spacing)
        try elementContainer.encodeIfPresent(self.keypath, forKey: .keypath)
        try elementContainer.encodeIfPresent(self.itemSkeleton, forKey: .itemSkeleton)
        try elementContainer.encodeIfPresent(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonToggle: Codable, Identifiable {
    public var id = UUID()
    public var label: String
    public var keypath: String // cell:/// or relative (resolved like other keypaths)
    public var modifiers: SkeletonModifiers?
    public var isOn: Bool = false
    
    public init(id: UUID = UUID(), label: String, keypath: String, modifiers: SkeletonModifiers? = nil, isOn: Bool = false) {
        self.id = id
        self.label = label
        self.keypath = keypath
        self.modifiers = modifiers
        self.isOn = isOn    
    }
    
    enum ElementKey: CodingKey { case Toggle }
    enum CodingKeys: CodingKey {
        case id
        case label
        case keypath
        case modifiers
        case isOn
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        //        self.elements = try container.decode(SkeletonElementList.self, forKey: .elements)
//        print("Decode SkeletonButton")
        
        if let id =  try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = id
        }
        self.keypath = try container.decode(String.self, forKey: .keypath)
        self.label = try container.decode(String.self, forKey: .label)
        self.isOn = try container.decode(Bool.self, forKey: .isOn)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
        
        
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self,
                                                         forKey: .Toggle)
        
        try elementContainer.encode(self.keypath, forKey: .keypath)
        try elementContainer.encode(self.label, forKey: .label)
        try elementContainer.encodeIfPresent(self.isOn, forKey: .isOn)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public struct SkeletonPicker: Codable, Identifiable {
    public var id = UUID()
    public var label: String?
    public var placeholder: String?
    public var elements: ValueTypeList
    public var keypath: String?
    public var optionLabelKeypath: String?
    public var selectionValueKeypath: String?
    public var selectionStateKeypath: String?
    public var selectionActionKeypath: String?
    public var selectionPayloadMode: SkeletonListSelectionPayloadMode?
    public var allowsEmptySelection: Bool?
    public var modifiers: SkeletonModifiers?

    enum ElementKey: CodingKey { case Picker }
    enum CodingKeys: CodingKey {
        case id
        case label
        case placeholder
        case elements
        case keypath
        case optionLabelKeypath
        case selectionValueKeypath
        case selectionStateKeypath
        case selectionActionKeypath
        case selectionPayloadMode
        case allowsEmptySelection
        case modifiers
    }

    public init(
        id: UUID = UUID(),
        label: String? = nil,
        placeholder: String? = nil,
        elements: ValueTypeList = ValueTypeList(),
        keypath: String? = nil,
        optionLabelKeypath: String? = nil,
        selectionValueKeypath: String? = nil,
        selectionStateKeypath: String? = nil,
        selectionActionKeypath: String? = nil,
        selectionPayloadMode: SkeletonListSelectionPayloadMode? = nil,
        allowsEmptySelection: Bool? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.id = id
        self.label = label
        self.placeholder = placeholder
        self.elements = elements
        self.keypath = keypath
        self.optionLabelKeypath = optionLabelKeypath
        self.selectionValueKeypath = selectionValueKeypath
        self.selectionStateKeypath = selectionStateKeypath
        self.selectionActionKeypath = selectionActionKeypath
        self.selectionPayloadMode = selectionPayloadMode
        self.allowsEmptySelection = allowsEmptySelection
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = decodedID
        }
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        self.elements = (try container.decodeIfPresent(ValueTypeList.self, forKey: .elements)) ?? ValueTypeList()
        self.keypath = try container.decodeIfPresent(String.self, forKey: .keypath)
        self.optionLabelKeypath = try container.decodeIfPresent(String.self, forKey: .optionLabelKeypath)
        self.selectionValueKeypath = try container.decodeIfPresent(String.self, forKey: .selectionValueKeypath)
        self.selectionStateKeypath = try container.decodeIfPresent(String.self, forKey: .selectionStateKeypath)
        self.selectionActionKeypath = try container.decodeIfPresent(String.self, forKey: .selectionActionKeypath)
        self.selectionPayloadMode = try container.decodeIfPresent(SkeletonListSelectionPayloadMode.self, forKey: .selectionPayloadMode)
        self.allowsEmptySelection = try container.decodeIfPresent(Bool.self, forKey: .allowsEmptySelection)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)

        try validateSelectionConfiguration()
    }

    public func getElements() async throws -> ValueTypeList {
        if let resolver = CellBase.defaultCellResolver,
           let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: false),
           let keypath = self.keypath,
           let cellURL = try? urlFromKeypath(keypath: keypath)
        {
            let initialElements = try await resolver.get(from: cellURL, requester: requester)
            guard case .list(let valueTypeList) = initialElements else {
                print("Error. ValueType returned from get \(cellURL) not List")
                return ValueTypeList()
            }
            return valueTypeList
        }

        return ValueTypeList()
    }

    private func urlFromKeypath(keypath: String) throws -> URL {
        var url: URL?
        if keypath.hasPrefix("cell://") {
            url = URL(string: keypath)
        } else {
            url = URL(string: "cell:///Porthole/\(keypath)")
        }
        if let url {
            return url
        }
        throw URLKeypathError.badURL
    }

    public func encode(to encoder: any Encoder) throws {
        try validateSelectionConfiguration()

        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Picker)
        try elementContainer.encode(self.id, forKey: .id)
        try elementContainer.encodeIfPresent(self.label, forKey: .label)
        try elementContainer.encodeIfPresent(self.placeholder, forKey: .placeholder)
        try elementContainer.encodeIfPresent(self.elements, forKey: .elements)
        try elementContainer.encodeIfPresent(self.keypath, forKey: .keypath)
        try elementContainer.encodeIfPresent(self.optionLabelKeypath, forKey: .optionLabelKeypath)
        try elementContainer.encodeIfPresent(self.selectionValueKeypath, forKey: .selectionValueKeypath)
        try elementContainer.encodeIfPresent(self.selectionStateKeypath, forKey: .selectionStateKeypath)
        try elementContainer.encodeIfPresent(self.selectionActionKeypath, forKey: .selectionActionKeypath)
        try elementContainer.encodeIfPresent(self.selectionPayloadMode, forKey: .selectionPayloadMode)
        try elementContainer.encodeIfPresent(self.allowsEmptySelection, forKey: .allowsEmptySelection)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }

    public func selectionPayload(trigger: SkeletonListSelectionTrigger, rows: [ValueType], selectedIndex: Int?) throws -> ValueType {
        var proxyList = SkeletonList(elements: ValueTypeList())
        proxyList.selectionMode = .single
        proxyList.selectionValueKeypath = selectionValueKeypath
        proxyList.selectionPayloadMode = selectionPayloadMode
        proxyList.allowsEmptySelection = allowsEmptySelection
        return try proxyList.selectionPayload(
            trigger: trigger,
            rows: rows,
            selectedIndices: selectedIndex.map { [$0] } ?? []
        )
    }

    private func validateSelectionConfiguration() throws {
        switch self.selectionPayloadMode {
        case .itemID?, .selectedIDs?:
            if self.selectionValueKeypath?.isEmpty != false {
                throw SkeletonListConfigurationError.missingSelectionValueKeypath(self.selectionPayloadMode!)
            }
        default:
            break
        }
    }
}

public struct SkeletonVisualization: Codable, Identifiable {
    public var id = UUID()
    public var kind: String
    public var keypath: String?
    public var stateKeypath: String?
    public var actionKeypath: String?
    public var spec: ValueType?
    public var modifiers: SkeletonModifiers?

    public init(
        id: UUID = UUID(),
        kind: String,
        keypath: String? = nil,
        stateKeypath: String? = nil,
        actionKeypath: String? = nil,
        spec: ValueType? = nil,
        modifiers: SkeletonModifiers? = nil
    ) {
        self.id = id
        self.kind = kind
        self.keypath = keypath
        self.stateKeypath = stateKeypath
        self.actionKeypath = actionKeypath
        self.spec = spec
        self.modifiers = modifiers
    }

    enum ElementKey: CodingKey { case Visualization }
    enum CodingKeys: CodingKey {
        case id
        case kind
        case keypath
        case stateKeypath
        case actionKeypath
        case spec
        case modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = decodedID
        }
        self.kind = try container.decode(String.self, forKey: .kind)
        self.keypath = try container.decodeIfPresent(String.self, forKey: .keypath)
        self.stateKeypath = try container.decodeIfPresent(String.self, forKey: .stateKeypath)
        self.actionKeypath = try container.decodeIfPresent(String.self, forKey: .actionKeypath)
        self.spec = try container.decodeIfPresent(ValueType.self, forKey: .spec)
        self.modifiers = try container.decodeIfPresent(SkeletonModifiers.self, forKey: .modifiers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ElementKey.self)
        var elementContainer = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .Visualization)
        try elementContainer.encode(self.id, forKey: .id)
        try elementContainer.encode(self.kind, forKey: .kind)
        try elementContainer.encodeIfPresent(self.keypath, forKey: .keypath)
        try elementContainer.encodeIfPresent(self.stateKeypath, forKey: .stateKeypath)
        try elementContainer.encodeIfPresent(self.actionKeypath, forKey: .actionKeypath)
        try elementContainer.encodeIfPresent(self.spec, forKey: .spec)
        try elementContainer.encodeIfPresent(self.modifiers, forKey: .modifiers)
    }
}

public indirect enum SkeletonElement : Codable, Identifiable {
    case List(SkeletonList)
    case Object(SkeletonObject)
    case Spacer(SkeletonSpacer)
    case Image(SkeletonImage)
    case Text(SkeletonText)
    case AttachmentField(SkeletonAttachmentField)
    case FileUpload(SkeletonFileUpload)
    case TextField(SkeletonTextField)
    case TextArea(SkeletonTextArea)
    case HStack(SkeletonHStack)
    case VStack(SkeletonVStack)
    case Reference(SkeletonCellReference)
    case Button(SkeletonButton)
    case Divider(SkeletonDivider)
    case ScrollView(SkeletonScrollView)
    case Section(SkeletonSection)
    case Tabs(SkeletonTabs)
    case ZStack(SkeletonZStack)
    case Grid(SkeletonGrid)
    case Toggle(SkeletonToggle)
    case Picker(SkeletonPicker)
    case Visualization(SkeletonVisualization)
    
    public var id: UUID {
        switch self {
        case .Text(let value):
            return value.id

        case .AttachmentField(let value):
            return value.id

        case .FileUpload(let value):
            return value.id
            
        case .TextField(let value):
            return value.id

        case .TextArea(let value):
            return value.id

        case .HStack(let value):
            return value.id
            
        case .VStack(let value):
            return value.id
            
        case .Image(let value):
            return value.id
            
        case .List(let value):
            return value.id
            
        case .Object(let value):
            return value.id
            
        case .Spacer(let value):
            return value.id
            
        case .Reference(let value):
            return value.id
            
        case .Button(let value):
            return value.id
            
        case .Divider(let value):
            return value.id
            
        case .ScrollView(let value):
            return value.id
            
        case .Section(let value):
            return value.id

        case .Tabs(let value):
            return value.id
            
        case .ZStack(let value):
            return value.id
            
        case .Grid(let value):
            return value.id
            
        case .Toggle(let value):
            return value.id

        case .Picker(let value):
            return value.id
        case .Visualization(let value):
            return value.id
        }
    
    }
        
    
    
    
    public init(from decoder: any Decoder) throws {
//        print("Decode SkeletonElement")
        func trace(_ message: String) {
            CellBase.diagnosticLog(message, domain: .skeleton)
        }

        if let key = decoder.codingPath.last?.stringValue {
            trace("Decoding key: \(key)")
            switch key {
            case "List":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let list = try singleValueContainer.decode(SkeletonList.self)
                    self = .List(list)
                    return
                } catch {
                    trace("Decoding List failed with error: \(error)")
                }
            case "Object":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonObject = try singleValueContainer.decode(SkeletonObject.self)
                    self = .Object(skeletonObject)
                    return
                } catch {
                    trace("Decoding skeletonObject failed with error: \(error)")
                }
                
            case "Spacer":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonSpacer = try singleValueContainer.decode(SkeletonSpacer.self)
                    self = .Spacer(skeletonSpacer)
                    return
                } catch {
                    trace("Decoding skeletonSpacer failed with error: \(error)")
                }
                
            case "Image":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonImage = try singleValueContainer.decode(SkeletonImage.self)
                    self = .Image(skeletonImage)
                    return
                } catch {
                    trace("Decoding skeletonImage failed with error: \(error)")
                }
                
            case "Text":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonText = try singleValueContainer.decode(SkeletonText.self)
                    self = .Text(skeletonText)
                    return
                } catch {
                    trace("Decoding skeletonText failed with error: \(error)")
                }

            case "AttachmentField":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let attachmentField = try singleValueContainer.decode(SkeletonAttachmentField.self)
                    self = .AttachmentField(attachmentField)
                    return
                } catch {
                    trace("Decoding attachmentField failed with error: \(error)")
                }

            case "FileUpload":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let fileUpload = try singleValueContainer.decode(SkeletonFileUpload.self)
                    self = .FileUpload(fileUpload)
                    return
                } catch {
                    trace("Decoding fileUpload failed with error: \(error)")
                }

            case "TextField":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonTextField = try singleValueContainer.decode(SkeletonTextField.self)
                    self = .TextField(skeletonTextField)
                    return
                } catch {
                    trace("Decoding skeletonTextField failed with error: \(error)")
                }
                
            case "TextArea":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonTextArea = try singleValueContainer.decode(SkeletonTextArea.self)
                    self = .TextArea(skeletonTextArea)
                    return
                } catch {
                    trace("Decoding skeletonTextArea failed with error: \(error)")
                }

            case "HStack":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonHStack = try singleValueContainer.decode(SkeletonHStack.self)
                    self = .HStack(skeletonHStack)
                    return
                } catch {
                    trace("Decoding skeletonHStack failed with error: \(error)")
                }
                
            case "VStack":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonVStack = try singleValueContainer.decode(SkeletonVStack.self)
                    self = .VStack(skeletonVStack)
                    return
                } catch {
                    trace("Decoding VStack failed with error: \(error)")
                }
                
            case "Reference":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonCellReference = try singleValueContainer.decode(SkeletonCellReference.self)
                    self = .Reference(skeletonCellReference)
                    return
                } catch {
                    trace("Decoding skeletonCellreference failed with error: \(error)")
                }
                
            case "Button":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonButton = try singleValueContainer.decode(SkeletonButton.self)
                    self = .Button(skeletonButton)
                    return
                } catch {
                    trace("Decoding skeletonButton failed with error: \(error)")
                }
                
            case "Divider":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonDivider = try singleValueContainer.decode(SkeletonDivider.self)
                    self = .Divider(skeletonDivider)
                    return
                } catch {
                    trace("Decoding skeletonDivider failed with error: \(error)")
                }
                
            case "ScrollView":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonScrollView = try singleValueContainer.decode(SkeletonScrollView.self)
                    self = .ScrollView(skeletonScrollView)
                    return
                } catch {
                    trace("Decoding skeletonScrollView failed with error: \(error)")
                }
                
            case "Section":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonSection = try singleValueContainer.decode(SkeletonSection.self)
                    self = .Section(skeletonSection)
                    return
                } catch {
                    trace("Decoding skeletonSection failed with error: \(error)")
                }

            case "Tabs":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonTabs = try singleValueContainer.decode(SkeletonTabs.self)
                    self = .Tabs(skeletonTabs)
                    return
                } catch {
                    trace("Decoding skeletonTabs failed with error: \(error)")
                }
                
            case "ZStack":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonZStack = try singleValueContainer.decode(SkeletonZStack.self)
                    self = .ZStack(skeletonZStack)
                    return
                } catch {
                    trace("Decoding skeletonZStack failed with error: \(error)")
                }
                
            case "Grid":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonGrid = try singleValueContainer.decode(SkeletonGrid.self)
                    self = .Grid(skeletonGrid)
                    return
                } catch {
                    trace("Decoding skeletonGrid failed with error: \(error)")
                }
                
            case "Toggle":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonToggle = try singleValueContainer.decode(SkeletonToggle.self)
                    self = .Toggle(skeletonToggle)
                    return
                } catch {
                    trace("Decoding skeletonToggle failed with error: \(error)")
                }

            case "Picker":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonPicker = try singleValueContainer.decode(SkeletonPicker.self)
                    self = .Picker(skeletonPicker)
                    return
                } catch {
                    trace("Decoding skeletonPicker failed with error: \(error)")
                }

            case "Visualization":
                do {
                    let singleValueContainer = try decoder.singleValueContainer()
                    let skeletonVisualization = try singleValueContainer.decode(SkeletonVisualization.self)
                    self = .Visualization(skeletonVisualization)
                    return
                } catch {
                    trace("Decoding skeletonVisualization failed with error: \(error)")
                }
                
            default:
                break
            }
            
            do {
                let container = try decoder.container(keyedBy: DynamicCodingKey.self)
//                print("container: \(container.allKeys)")
                
                for key in container.allKeys {
                    do {
//                        print("@@@@@@@ Decoding key: \(key)")
                        let decodedObject = try container.decode(SkeletonElement.self, forKey: key )
                        self = decodedObject
                        return
                    } catch { trace("Decoding SkeletonElement in object using key: \(key) failed with error: \(error)") }
                }
             
                
            } catch {
                trace("Single value decoder failed with error: \(error)")
                
            }
            trace("SkeletonElement decode exhausted keyed fallback")
            throw DecodingPDSError.corruptedData
        } else {
            do {
                let container = try decoder.container(keyedBy: DynamicCodingKey.self)
                for key in container.allKeys {
                    do {
                        let decodedObject = try container.decode(SkeletonElement.self, forKey: key)
                        self = decodedObject
                        return
                    } catch {
                        trace("Decoding SkeletonElement with no codingPath using key: \(key) failed with error: \(error)")
                    }
                }
            } catch {
                trace("No Key fallback failed with error: \(error)")
            }

            trace("SkeletonElement decode had no codingPath key")
        }
        trace("End of SkeletonElement decode")
        throw DecodingPDSError.corruptedData
    }
    
    public func encode(to encoder: Encoder) throws {
        
        var container = encoder.singleValueContainer()
        switch self {
        case let .List(value):
            try container.encode(value) //
        case let .Object(value):
            try container.encode(value)
        case let .Spacer(value):
            try container.encode(value)
        case let .Image(value):
            try container.encode(value)
        case let .Text(value):
            try container.encode(value)
        case let .AttachmentField(value):
            try container.encode(value)
        case let .FileUpload(value):
            try container.encode(value)
        case let .TextField(value):
            try container.encode(value)
        case let .TextArea(value):
            try container.encode(value)
        case let .HStack(value):
            try container.encode(value)
        case let .VStack(value):
            try container.encode(value)
        case let .Reference(value):
            try container.encode(value)
        case let .Button(value):
            try container.encode(value)
        case let .Divider(value):
            try container.encode(value)
        case let .ScrollView(value):
            try container.encode(value)
        case let .Section(value):
            try container.encode(value)
        case let .Tabs(value):
            try container.encode(value)
        case let .ZStack(value):
            try container.encode(value)
        case let .Grid(value):
            try container.encode(value)
        case let .Toggle(value):
            try container.encode(value)
        case let .Picker(value):
            try container.encode(value)
        case let .Visualization(value):
            try container.encode(value)
        }
    }
}
