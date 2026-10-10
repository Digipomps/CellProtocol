// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Private receipt/policy storage. Key material is supplied by the host vault;
/// no plaintext fallback, no key generation when opening an existing store.
public actor OwnerAttachEncryptedStore: OwnerAttachExtensionStore {
    private let directory: URL
    private let key: SymmetricKey

    public init(directory: URL, key: Data) throws {
        guard key.count == 32 else { throw OwnerAttachExtensionError.persistenceFailed }
        self.directory = directory; self.key = SymmetricKey(data: key)
    }

    private func file(_ id: String) throws -> URL {
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw OwnerAttachExtensionError.wrongContext
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else {
                throw OwnerAttachExtensionError.persistenceFailed
            }
        }
        return directory.appendingPathComponent(id + ".sealed")
    }

    public func read(id: String) throws -> Data? {
        let url = try file(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, size > 0, size <= 256 * 1024 else {
            throw OwnerAttachExtensionError.persistenceFailed
        }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        return try AES.GCM.open(box, using: key, authenticating: Data(("owner-attach.v1:" + id).utf8))
    }

    public func identifiers() throws -> [String] {
        _ = try file(String(repeating: "0", count: 64))
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sealed" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
            .sorted()
    }

    public func write(_ data: Data, id: String) throws {
        let url = try file(id)
        // Authentication failure must never turn an existing entry into a new one.
        _ = try read(id: id)
        guard data.count <= 240 * 1024,
              let sealed = try AES.GCM.seal(data, using: key,
                authenticating: Data(("owner-attach.v1:" + id).utf8)).combined else {
            throw OwnerAttachExtensionError.persistenceFailed
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var protected = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        #if os(iOS)
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try sealed.write(to: url, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard try read(id: id) == data else { throw OwnerAttachExtensionError.persistenceFailed }
    }
}

public extension OwnerAttachExtensionRuntime {
    /// Explicit host opt-in after a durable vault and private storage root are
    /// ready. The dedicated receipt signer is never a human enrollment issuer.
    func configure(vault: any IdentityVaultProtocol, directory: URL, label: String) async throws {
        let token = beginConfiguration()
        guard let secrets = vault as? any ScopedSecretProviderProtocol,
              let receiver = await vault.identity(for: "runtime.owner-attach-receipts.v1", makeNewIfNotFound: true) else {
            throw OwnerAttachExtensionError.unavailable
        }
        let secret = try await secrets.scopedSecretData(tag: "runtime.owner-attach-receipts.v1", minimumLength: 32)
        let store = try OwnerAttachEncryptedStore(directory: directory, key: secret)
        try finishConfiguration(OwnerAttachEntityExtensionHost(receiver: receiver, label: label, store: store), token: token)
    }
}
