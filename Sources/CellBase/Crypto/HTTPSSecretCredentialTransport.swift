// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SecretCredentialResponse: Codable, Sendable {
    public let record: SealedDatabaseSecret?
    public init(record: SealedDatabaseSecret?) { self.record = record }
}

/// Dedicated non-cacheable data plane. TLS validation uses the platform trust store; redirects are refused.
/// Do not wrap this in request/response body recording, Flow, LLM tools or analytics.
public final class HTTPSSecretCredentialTransport: SecretCredentialTransport, @unchecked Sendable {
    private let endpoint: URL
    private let session: URLSession
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let trustAnchors: [Data]
        init(trustAnchors: [Data]) { self.trustAnchors = trustAnchors }
#if canImport(Security)
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard !trustAnchors.isEmpty else { completionHandler(.performDefaultHandling, nil); return }
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else { completionHandler(.cancelAuthenticationChallenge, nil); return }
            let certificates = trustAnchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            guard certificates.count == trustAnchors.count,
                  SecTrustSetAnchorCertificates(trust, certificates as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
#endif
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    /// Explicit private PKI anchors may be supplied by trusted owner configuration, never by a remote response.
    /// Hostname, validity and chain verification remain mandatory. Empty means the platform trust store.
    public init(endpoint: URL, trustAnchors: [Data] = []) throws {
#if !canImport(Security)
        guard trustAnchors.isEmpty else { throw SecretCredentialError.unavailable }
#endif
        guard endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { throw SecretCredentialError.invalidContract }
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config, delegate: NoRedirects(trustAnchors: trustAnchors), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func exchange(_ request: SecretCredentialRequest) async throws -> SealedDatabaseSecret? {
        var http = URLRequest(url: endpoint)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        http.httpBody = try JSONEncoder().encode(request)
        guard (http.httpBody?.count ?? 0) <= 65_536 else { throw SecretCredentialError.invalidContract }
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: http) }
        catch { throw SecretCredentialError.unavailable }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 65_536 else {
            throw SecretCredentialError.unavailable
        }
        do { return try JSONDecoder().decode(SecretCredentialResponse.self, from: data).record }
        catch { throw SecretCredentialError.integrity }
    }
}
