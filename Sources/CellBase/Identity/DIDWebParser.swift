// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum DIDWebError: Error {
    case invalidURL
    case invalidDID
}

public struct DIDWebParser {
    public static func did(from url: URL) throws -> String {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw DIDWebError.invalidURL
        }
        guard var host = url.host?.lowercased(), !host.isEmpty else {
            throw DIDWebError.invalidURL
        }

        if let port = url.port {
            host += "%3A\(port)"
        }

        var pathComponents = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if pathComponents.count >= 2,
           pathComponents[0] == ".well-known",
           pathComponents[1] == "did.json" {
            pathComponents = []
        } else {
            if pathComponents.last == "did.json" {
                pathComponents.removeLast()
            }
            if pathComponents.first == ".well-known" {
                pathComponents.removeFirst()
            }
        }

        let encodedComponents = pathComponents.map { component in
            component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
        }

        if encodedComponents.isEmpty {
            return "did:web:\(host)"
        }

        return "did:web:\(host):\(encodedComponents.joined(separator: ":"))"
    }

    public static func did(from urlString: String) throws -> String {
        guard let url = URL(string: urlString) else {
            throw DIDWebError.invalidURL
        }
        return try did(from: url)
    }

    public static func url(from did: String) throws -> URL {
        guard did.hasPrefix("did:web:") else {
            throw DIDWebError.invalidDID
        }

        let methodSpecific = String(did.dropFirst("did:web:".count))
        let parts = methodSpecific.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, !first.isEmpty else {
            throw DIDWebError.invalidDID
        }

        let hostPort = first.replacingOccurrences(of: "%3A", with: ":")
        let pathComponents = parts.dropFirst().map { component in
            component.removingPercentEncoding ?? component
        }

        var components = URLComponents()
        components.scheme = "https"

        if let portSeparator = hostPort.lastIndex(of: ":"),
           hostPort[hostPort.index(after: portSeparator)...].allSatisfy({ $0.isNumber }) {
            components.host = String(hostPort[..<portSeparator])
            components.port = Int(hostPort[hostPort.index(after: portSeparator)...])
        } else {
            components.host = hostPort
        }

        if pathComponents.isEmpty {
            components.path = "/.well-known/did.json"
        } else {
            components.path = "/" + pathComponents.joined(separator: "/") + "/did.json"
        }

        guard let url = components.url else {
            throw DIDWebError.invalidDID
        }
        return url
    }
}
