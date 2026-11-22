// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  SkeletonConfigurationCheck.swift
//  CellBase
//
//  One answer for an author holding a CellConfiguration file: will this
//  surface work, and if not, why — before anyone uploads it.
//
//  Decoding alone says yes too often. The Swift decoder turns an unknown or
//  malformed element into `Unsupported` and drops a List row template that is
//  not a VStack, while the web renderer refuses the same file outright. So the
//  check reads the raw JSON for what decoding hides (row templates, and the
//  names of elements the format does not have, which the decoder can lose when
//  it retries the inner object), decodes with the production decoder, and then
//  asks `SkeletonReachabilityAudit` what the person can actually see and do.
//
//  Used by the `skeleton-check` executable and by hosts that accept drafts
//  (Cell Configuration Studio), so both report the same findings.
//

import Foundation

public struct SkeletonConfigurationCheckFinding: Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// The file is not JSON, or not a CellConfiguration.
        case undecodable
        /// The configuration has no skeleton, so there is nothing to render.
        case missingSkeleton
        /// An element type the format does not have, or a known element whose
        /// fields could not be decoded. Swift renders nothing in its place.
        case unsupportedElement
        /// `List`/`Grid` row template that is not a `VStack`. The web renderer
        /// rejects the whole surface; CellApple silently drops the template.
        case flowElementNotVStack
        /// A structural reachability finding (hidden for good, dead condition,
        /// nested link, required action missing).
        case unreachable
    }

    public var kind: Kind
    /// Where in the file, in author terms.
    public var path: String
    public var message: String
    /// The actions the person loses with this finding.
    public var lostActionKeypaths: [String]

    public init(kind: Kind, path: String, message: String, lostActionKeypaths: [String] = []) {
        self.kind = kind
        self.path = path
        self.message = message
        self.lostActionKeypaths = lostActionKeypaths
    }
}

public struct SkeletonConfigurationCheckReport: Equatable, Sendable, Codable {
    public var configurationName: String?
    public var findings: [SkeletonConfigurationCheckFinding]
    /// Every action a person can reach on the surface, sorted.
    public var reachableActionKeypaths: [String]

    public var passed: Bool { findings.isEmpty }

    public init(configurationName: String?, findings: [SkeletonConfigurationCheckFinding], reachableActionKeypaths: [String]) {
        self.configurationName = configurationName
        self.findings = findings
        self.reachableActionKeypaths = reachableActionKeypaths
    }
}

public enum SkeletonConfigurationCheck {
    /// Checks one CellConfiguration JSON document.
    /// - Parameter requiredActionKeypaths: actions the surface exists for; each
    ///   one that cannot be reached becomes a finding.
    public static func check(json data: Data, requiredActionKeypaths: Set<String> = []) -> SkeletonConfigurationCheckReport {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return failed("Filen er ikke gyldig JSON: \(error.localizedDescription)")
        }
        guard let object = raw as? [String: Any] else {
            return failed("Filen må være ett JSON-objekt med name, cellReferences og skeleton.")
        }

        var findings: [SkeletonConfigurationCheckFinding] = []
        if let skeleton = object["skeleton"] {
            findRowTemplates(skeleton, path: "skeleton", findings: &findings)
            findUnknownElements(skeleton, path: "skeleton", findings: &findings)
        }

        let configuration: CellConfiguration
        do {
            configuration = try JSONDecoder().decode(CellConfiguration.self, from: data)
        } catch {
            return failed("Filen er ikke en CellConfiguration: \(describe(error))", name: object["name"] as? String)
        }
        guard let skeleton = configuration.skeleton else {
            findings.append(.init(kind: .missingSkeleton, path: "skeleton", message: "Konfigurasjonen har ikke noe skeleton å vise."))
            return SkeletonConfigurationCheckReport(configurationName: configuration.name, findings: findings, reachableActionKeypaths: [])
        }
        return check(skeleton: skeleton, configurationName: configuration.name,
                     requiredActionKeypaths: requiredActionKeypaths, rawFindings: findings, rawScanned: true)
    }

    /// Checks an already decoded configuration. Row templates that were not a
    /// VStack are gone after decoding, so prefer `check(json:)` when the file
    /// is available.
    public static func check(configuration: CellConfiguration, requiredActionKeypaths: Set<String> = []) -> SkeletonConfigurationCheckReport {
        guard let skeleton = configuration.skeleton else {
            return SkeletonConfigurationCheckReport(configurationName: configuration.name, findings: [
                .init(kind: .missingSkeleton, path: "skeleton", message: "Konfigurasjonen har ikke noe skeleton å vise.")
            ], reachableActionKeypaths: [])
        }
        return check(skeleton: skeleton, configurationName: configuration.name,
                     requiredActionKeypaths: requiredActionKeypaths, rawFindings: [], rawScanned: false)
    }

    private static func check(skeleton: SkeletonElement, configurationName: String?,
                              requiredActionKeypaths: Set<String>,
                              rawFindings: [SkeletonConfigurationCheckFinding],
                              rawScanned: Bool) -> SkeletonConfigurationCheckReport {
        var findings = rawFindings
        for finding in SkeletonReachabilityAudit.audit(skeleton, requiredActionKeypaths: requiredActionKeypaths) {
            let path = "skeleton" + (finding.path.isEmpty ? "" : ".\(finding.path)")
            if finding.kind == .unsupportedElement {
                // With the raw file, unknown names are reported from it, where the
                // name is the author's own. Without it, the decoded tree is all
                // there is. Decode failures of known elements always stay.
                let unknown = finding.detail == unknownElementReason
                if unknown && rawScanned { continue }
                findings.append(.init(kind: .unsupportedElement, path: path,
                                      message: unknown
                                        ? "Et element formatet ikke har, kan ikke vises."
                                        : "Elementet kan ikke vises: \(finding.detail)",
                                      lostActionKeypaths: finding.lostActionKeypaths))
                continue
            }
            findings.append(.init(kind: .unreachable, path: path,
                                  message: "\(finding.elementKind): \(finding.detail)",
                                  lostActionKeypaths: finding.lostActionKeypaths))
        }
        let reachable = SkeletonReachabilityAudit.reachableActionKeypaths(skeleton).sorted()
        return SkeletonConfigurationCheckReport(configurationName: configurationName, findings: findings, reachableActionKeypaths: reachable)
    }

    private static func failed(_ message: String, name: String? = nil) -> SkeletonConfigurationCheckReport {
        SkeletonConfigurationCheckReport(configurationName: name,
                                         findings: [.init(kind: .undecodable, path: "", message: message)],
                                         reachableActionKeypaths: [])
    }

    private static func findRowTemplates(_ node: Any, path: String, findings: inout [SkeletonConfigurationCheckFinding]) {
        if let object = node as? [String: Any] {
            for key in object.keys.sorted() {
                let value = object[key]!
                let childPath = "\(path).\(key)"
                if key == "flowElementSkeleton", let template = value as? [String: Any], template["VStack"] == nil {
                    let found = template.keys.sorted().first ?? "tomt objekt"
                    findings.append(.init(kind: .flowElementNotVStack, path: childPath,
                        message: "Radmalen er \(found), men må være en VStack. Nettleseren avviser hele flaten, og appen viser ingen rader."))
                }
                findRowTemplates(value, path: childPath, findings: &findings)
            }
        } else if let list = node as? [Any] {
            for (index, value) in list.enumerated() {
                findRowTemplates(value, path: "\(path)[\(index)]", findings: &findings)
            }
        }
    }

    /// The reason the production decoder gives an element type it does not know.
    private static let unknownElementReason = "Unknown skeleton element type"

    /// Element names `SkeletonElement` decodes, from `decodeKnownElement`.
    static let knownElementNames: Set<String> = [
        "Tree", "ComponentSurface", "List", "Object", "Spacer", "Image", "Text",
        "AttachmentField", "FileUpload", "TextField", "TextArea", "HStack", "VStack",
        "Reference", "Button", "Divider", "ScrollView", "Section", "Tabs",
        "NavigationBar", "ZStack", "Grid", "Toggle", "Picker", "Visualization",
        "Audio", "AudioQueue", "Unsupported",
    ]

    /// Fields whose values are data, not skeleton, so their keys are not
    /// element names.
    private static let dataFields: Set<String> = ["payload", "rawPayload", "mounts", "initialRoot"]

    /// Element names are UpperCamelCase and fields lowerCamelCase, so an
    /// UpperCamelCase key the format does not know is an element it does not have.
    private static func findUnknownElements(_ node: Any, path: String, findings: inout [SkeletonConfigurationCheckFinding]) {
        if let object = node as? [String: Any] {
            for key in object.keys.sorted() {
                let childPath = "\(path).\(key)"
                if dataFields.contains(key) { continue }
                if let first = key.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first),
                   !knownElementNames.contains(key) {
                    findings.append(.init(kind: .unsupportedElement, path: childPath,
                        message: "\(key) finnes ikke i skeleton-formatet. Appen viser ingenting der, og nettleseren kan avvise flaten."))
                    continue
                }
                findUnknownElements(object[key]!, path: childPath, findings: &findings)
            }
        } else if let list = node as? [Any] {
            for (index, value) in list.enumerated() {
                findUnknownElements(value, path: "\(path)[\(index)]", findings: &findings)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? Swift.DecodingError {
        case .keyNotFound(let key, let context)?:
            return "mangler \(key.stringValue) ved \(codingPath(context.codingPath))"
        case .typeMismatch(_, let context)?, .valueNotFound(_, let context)?, .dataCorrupted(let context)?:
            return "\(context.debugDescription) ved \(codingPath(context.codingPath))"
        default:
            return error.localizedDescription
        }
    }

    private static func codingPath(_ path: [CodingKey]) -> String {
        path.isEmpty ? "roten" : path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}
