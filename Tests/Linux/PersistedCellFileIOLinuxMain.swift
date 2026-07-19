// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Dependency-independent Linux execution gate for the exact descriptor
/// reader source. SwiftPM still requires private FileUtils-c credentials before
/// it can compile the complete CellVapor product in GitHub Actions.
@main
enum PersistedCellFileIOLinuxMain {
    static func main() throws {
        guard PersistedCellFileIO.maximumStoredCellBytes == 67_108_864 else {
            throw GateError.unexpectedProductionLimit
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("persisted-cell-linux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let limit = 4_096
        let exactURL = root.appendingPathComponent("exact")
        let exact = Data(repeating: 0xA5, count: limit)
        try exact.write(to: exactURL)
        guard try PersistedCellFileIO.readRegularFile(at: exactURL, maximumBytes: limit) == exact else {
            throw GateError.exactBoundaryMismatch
        }

        let overURL = root.appendingPathComponent("over")
        try Data(repeating: 0x5A, count: limit + 1).write(to: overURL)
        try require(.storedCellTooLarge) {
            try PersistedCellFileIO.readRegularFile(at: overURL, maximumBytes: limit)
        }

        let targetURL = root.appendingPathComponent("target")
        try Data("private-cell-content-marker".utf8).write(to: targetURL)
        let symlinkURL = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
        try require(.invalidFile) {
            try PersistedCellFileIO.readStoredCell(at: symlinkURL)
        }

        let hardLinkURL = root.appendingPathComponent("hard-link")
        try FileManager.default.linkItem(at: targetURL, to: hardLinkURL)
        try require(.invalidFile) {
            try PersistedCellFileIO.readStoredCell(at: hardLinkURL)
        }
        try require(.invalidFile) {
            try PersistedCellFileIO.readStoredCell(at: root)
        }
        try require(.missing) {
            try PersistedCellFileIO.readStoredCell(at: root.appendingPathComponent("missing"))
        }

        print("PersistedCellFileIO Linux gate passed")
    }

    private static func require(
        _ expected: PersistedCellFileIO.ReadError,
        operation: () throws -> Data
    ) throws {
        do {
            _ = try operation()
            throw GateError.expectedFailure(expected)
        } catch let error as PersistedCellFileIO.ReadError {
            guard error == expected else {
                throw GateError.unexpectedFailure(expected: expected, actual: error)
            }
        }
    }

    private enum GateError: Error {
        case unexpectedProductionLimit
        case exactBoundaryMismatch
        case expectedFailure(PersistedCellFileIO.ReadError)
        case unexpectedFailure(
            expected: PersistedCellFileIO.ReadError,
            actual: PersistedCellFileIO.ReadError
        )
    }
}
