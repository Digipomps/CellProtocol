// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CellSecurityEndpointPolicyError: Error, Equatable, Sendable {
    case emptyEndpoint
    case endpointTooLong
    case malformedEndpoint
    case unsupportedScheme(String)
    case remoteEndpointNotAllowed(String)
    case hostNotAllowed(String)
}

public struct CellSecurityEndpointValidation: Equatable, Sendable {
    public var canonicalEndpoint: String
    public var scheme: String
    public var host: String?
    public var isRemote: Bool

    public init(
        canonicalEndpoint: String,
        scheme: String,
        host: String?,
        isRemote: Bool
    ) {
        self.canonicalEndpoint = canonicalEndpoint
        self.scheme = scheme
        self.host = host
        self.isRemote = isRemote
    }
}

public struct CellSecurityEndpointPolicy: Equatable, Sendable {
    public var allowedSchemes: Set<String>
    public var allowLocalEndpoints: Bool
    public var allowRemoteEndpoints: Bool
    public var allowedRemoteHosts: Set<String>
    public var maxEndpointLength: Int

    public init(
        allowedSchemes: Set<String> = ["cell"],
        allowLocalEndpoints: Bool = true,
        allowRemoteEndpoints: Bool = false,
        allowedRemoteHosts: Set<String> = [],
        maxEndpointLength: Int = 2048
    ) {
        self.allowedSchemes = Set(allowedSchemes.map { $0.lowercased() })
        self.allowLocalEndpoints = allowLocalEndpoints
        self.allowRemoteEndpoints = allowRemoteEndpoints
        self.allowedRemoteHosts = Set(allowedRemoteHosts.map { $0.lowercased() })
        self.maxEndpointLength = maxEndpointLength
    }

    public func validate(_ endpoint: String) throws -> CellSecurityEndpointValidation {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CellSecurityEndpointPolicyError.emptyEndpoint
        }
        guard trimmed.count <= maxEndpointLength else {
            throw CellSecurityEndpointPolicyError.endpointTooLong
        }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            throw CellSecurityEndpointPolicyError.malformedEndpoint
        }
        guard allowedSchemes.contains(scheme) else {
            throw CellSecurityEndpointPolicyError.unsupportedScheme(scheme)
        }

        components.scheme = scheme
        let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = host.flatMap { value in
            value.isEmpty ? nil : value.lowercased()
        }
        if let normalizedHost {
            components.host = normalizedHost
        }

        let isLocal = normalizedHost == nil
            || normalizedHost?.isEmpty == true
            || normalizedHost == "localhost"
            || normalizedHost == "127.0.0.1"
            || normalizedHost == "::1"
        let isRemote = !isLocal

        if isRemote {
            guard allowRemoteEndpoints else {
                throw CellSecurityEndpointPolicyError.remoteEndpointNotAllowed(normalizedHost ?? "")
            }
            guard let normalizedHost,
                  allowedRemoteHosts.contains(normalizedHost) else {
                throw CellSecurityEndpointPolicyError.hostNotAllowed(normalizedHost ?? "")
            }
        } else if !allowLocalEndpoints {
            throw CellSecurityEndpointPolicyError.hostNotAllowed(normalizedHost ?? "")
        }

        guard let canonicalEndpoint = components.string else {
            throw CellSecurityEndpointPolicyError.malformedEndpoint
        }

        return CellSecurityEndpointValidation(
            canonicalEndpoint: canonicalEndpoint,
            scheme: scheme,
            host: normalizedHost,
            isRemote: isRemote
        )
    }
}
