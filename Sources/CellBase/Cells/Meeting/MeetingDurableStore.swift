import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Synchronous durable boundary: callers must not issue a receipt until commit
/// returns. Implementations must reject conflicting immutable keys and read back.
/// Sensitive payloads must already be encrypted before entering this store.
public protocol MeetingDurableStore: Sendable {
    func read(_ key: String) throws -> Data?
    func commit(_ bytes: Data, key: String) throws
    func commitReceipt(_ bytes: Data, key: String, requiring package: Data, packageKey: String) throws
    func remove(_ key: String) throws
    func keys() throws -> [String]
}

/// Private directory, exclusive file lock, immutable atomic commits, fsync of
/// file and directory, exact readback. No plaintext transcript or vault key here.
/// The lock also serializes independently restored inbox/outbox instances.
public final class MeetingFileStore: MeetingDurableStore, @unchecked Sendable {
    private let root: URL
    private let mutex = NSLock()
    public static let maximumBytes = 32 * 1024 * 1024
    public init(directory: URL) throws {
        root = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw MeetingSessionError.unavailable }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    private func path(_ key: String) throws -> URL {
        guard !key.isEmpty, key.count <= 180, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw MeetingSessionError.invalidPlan
        }
        return root.appendingPathComponent(key + ".meeting")
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MeetingSessionError.unavailable }; defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw MeetingSessionError.unavailable }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func readFile(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw MeetingSessionError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let value = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard value.count <= Self.maximumBytes else { throw MeetingSessionError.wrongPackage }
        return value
    }
    public func read(_ key: String) throws -> Data? { try locked { try readFile(path(key)) } }
    public func commit(_ bytes: Data, key: String) throws {
        try locked { try commitLocked(bytes, key: key) }
    }
    public func commitReceipt(_ bytes: Data, key: String, requiring package: Data, packageKey: String) throws {
        try locked {
            guard try readFile(path(packageKey)) == package else { throw MeetingSessionError.unavailable }
            try commitLocked(bytes, key: key)
        }
    }
    private func commitLocked(_ bytes: Data, key: String) throws {
            guard bytes.count <= Self.maximumBytes else { throw MeetingSessionError.wrongPackage }
            let target = try path(key)
            if let existing = try readFile(target) {
                guard existing == bytes else { throw MeetingSessionError.operationConflict }
                let fd = open(target.path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw MeetingSessionError.unavailable }
                defer { close(fd) }
                guard fsync(fd) == 0 else { throw MeetingSessionError.unavailable }
                try syncDirectory()
                guard try readFile(target) == bytes else { throw MeetingSessionError.unavailable }
                return
            }
            let temp = root.appendingPathComponent(".pending-" + UUID().uuidString)
            let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw MeetingSessionError.unavailable }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close()
            guard rename(temp.path, target.path) == 0 else { throw MeetingSessionError.unavailable }
            try syncDirectory()
            guard try readFile(target) == bytes else { throw MeetingSessionError.unavailable }
    }
    public func remove(_ key: String) throws {
        try locked {
            let target = try path(key)
            if unlink(target.path) != 0 && errno != ENOENT { throw MeetingSessionError.unavailable }
            try syncDirectory()
        }
    }
    public func keys() throws -> [String] {
        try locked { try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".meeting") }.map { String($0.dropLast(8)) }.sorted() }
    }
    private func syncDirectory() throws {
        let fd = open(root.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw MeetingSessionError.unavailable }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw MeetingSessionError.unavailable }
    }
}
