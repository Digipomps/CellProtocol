// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Fail-closed file I/O shared by the Apple and Vapor persisted-Cell stores.
///
/// The limit applies to the bytes on disk, including the encrypted envelope.
/// It leaves substantial headroom for ordinary JSON state while still
/// bounding allocation before decryption and JSON decoding. Deployments must
/// inventory existing file sizes before enabling a newly introduced cap.
@_spi(HAVENRuntime)
public enum PersistedCellFileIO {
    public static let maximumStoredCellBytes = 64 * 1_024 * 1_024

    public enum ReadError: Error, Equatable {
        case missing
        case invalidFile
        case storedCellTooLarge
        case readFailed
    }

    public static func readStoredCell(at url: URL) throws -> Data {
        try readRegularFile(at: url, maximumBytes: maximumStoredCellBytes)
    }

    static func readRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else {
            throw ReadError.invalidFile
        }

        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
#if canImport(Darwin)
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
#elseif canImport(Glibc)
            return Glibc.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
#else
            return -1
#endif
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw ReadError.missing
            }
            throw ReadError.invalidFile
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var info = stat()
#if canImport(Darwin)
        let status = Darwin.fstat(descriptor, &info)
#elseif canImport(Glibc)
        let status = Glibc.fstat(descriptor, &info)
#else
        let status = -1
#endif
        guard status == 0,
              info.st_size >= 0,
              info.st_nlink == 1,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ReadError.invalidFile
        }
        guard UInt64(info.st_size) <= UInt64(maximumBytes) else {
            throw ReadError.storedCellTooLarge
        }

        do {
            var stored = Data()
            stored.reserveCapacity(Int(info.st_size))

            while true {
                let remaining = maximumBytes - stored.count
                let requested = remaining == 0 ? 1 : min(64 * 1_024, remaining)
                let chunk = try handle.read(upToCount: requested) ?? Data()
                guard chunk.isEmpty == false else {
                    return stored
                }
                guard chunk.count <= remaining else {
                    throw ReadError.storedCellTooLarge
                }
                stored.append(chunk)
            }
        } catch let error as ReadError {
            throw error
        } catch {
            throw ReadError.readFailed
        }
    }
}
