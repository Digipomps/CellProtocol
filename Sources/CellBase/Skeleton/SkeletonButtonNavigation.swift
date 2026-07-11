// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum SkeletonButtonNavigation {
    public static func isNavigationButton(_ button: SkeletonButton) -> Bool {
        button.keypath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && normalized(button.url) != nil
    }

    public static func resolveURL(
        for button: SkeletonButton,
        relativeTo baseURL: URL? = nil
    ) -> URL? {
        guard isNavigationButton(button), let rawURL = normalized(button.url) else {
            return nil
        }

        let parsed: URL?
        let requiresSameOrigin: Bool
        if let absolute = URL(string: rawURL), absolute.scheme != nil {
            parsed = absolute
            requiresSameOrigin = false
        } else if rawURL.hasPrefix("//") {
            return nil
        } else if let baseURL, isAllowedBaseURL(baseURL) {
            parsed = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL
            requiresSameOrigin = true
        } else {
            parsed = nil
            requiresSameOrigin = false
        }

        guard let parsed,
              parsed.user == nil,
              parsed.password == nil,
              let scheme = parsed.scheme?.lowercased(),
              let host = parsed.host,
              host.isEmpty == false
        else {
            return nil
        }

        if requiresSameOrigin, let baseURL, isSameOrigin(parsed, baseURL) == false {
            return nil
        }

        if scheme == "https" {
            return parsed
        }
        if scheme == "http", isLoopbackHost(host) {
            return parsed
        }
        return nil
    }

    public static func configuredBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        for key in ["CELL_SCAFFOLD_PUBLIC_BASE_URL", "PUBLIC_BASE_URL"] {
            guard let value = normalized(environment[key]), let url = URL(string: value) else {
                continue
            }
            if isAllowedBaseURL(url) {
                return url
            }
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isAllowedBaseURL(_ url: URL) -> Bool {
        guard url.user == nil,
              url.password == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              host.isEmpty == false
        else {
            return false
        }
        return scheme == "https" || (scheme == "http" && isLoopbackHost(host))
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return normalizedHost == "localhost"
            || normalizedHost.hasSuffix(".localhost")
            || normalizedHost == "127.0.0.1"
            || normalizedHost.hasPrefix("127.")
            || normalizedHost == "::1"
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(for: lhs) == effectivePort(for: rhs)
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
