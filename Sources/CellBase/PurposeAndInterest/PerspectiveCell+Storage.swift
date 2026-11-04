// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The legacy native layout remains byte-for-byte compatible. Hosts normally
/// configure CellBase.documentRootPath before resolver registration. The Apple
/// fallback intentionally matches CellApple's historical documents/test roots;
/// a headless host without an explicit root fails instead of choosing a new home.
struct PerspectiveCellStorage {
    enum Failure: Error { case missingRoot, emptyWrite, readbackMismatch }
    let documentsRoot: URL
    let cellName: String

    static func documentsRoot() throws -> URL {
        if let path = CellBase.documentRootPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
#if canImport(Darwin)
        let process = ProcessInfo.processInfo
        if process.environment["XCTestConfigurationFilePath"] != nil
            || Bundle.main.bundlePath.contains(".xctest")
            || process.arguments.contains(where: { $0.contains(".xctest") }) {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("CellProtocolTests", isDirectory: true)
                .appendingPathComponent("CellApple-\(process.processIdentifier)", isDirectory: true)
        }
        if let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first { return root }
#endif
        throw Failure.missingRoot
    }

    func url(filename: String) throws -> URL {
        let cells = try CellStoragePathPolicy.component("CellsContainer", under: documentsRoot)
        let directory = try CellStoragePathPolicy.component(cellName, under: cells)
        return try CellStoragePathPolicy.filename(filename, under: directory)
    }

    func read(filename: String) throws -> Data { try Data(contentsOf: url(filename: filename)) }

    func write(_ data: Data, filename: String) throws {
        guard !data.isEmpty else { throw Failure.emptyWrite }
        let target = try url(filename: filename)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: target, options: .atomic) }
        catch {
            // A reported write failure can still have committed. Read the same
            // path before deciding; never retry under another name or identity.
            guard (try? Data(contentsOf: target)) == data else { throw error }
        }
        guard try Data(contentsOf: target) == data else { throw Failure.readbackMismatch }
    }
}

extension PerspectiveCell {
    func readPerspectiveFile(filename: String) async throws -> Data {
        try PerspectiveCellStorage(documentsRoot: PerspectiveCellStorage.documentsRoot(), cellName: name).read(filename: filename)
    }
    func writePerspectiveFile(fileData: Data, filename: String) async throws {
        try PerspectiveCellStorage(documentsRoot: PerspectiveCellStorage.documentsRoot(), cellName: name).write(fileData, filename: filename)
    }
}
