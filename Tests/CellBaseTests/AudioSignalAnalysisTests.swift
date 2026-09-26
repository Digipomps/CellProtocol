// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

final class AudioSignalAnalysisTests: XCTestCase {
    func testReferenceFileMatchesChapter34AndIsDeterministic() throws {
        let referenceFile = try referenceFileURL()
        let analyzer = AudioSignalAnalyzer()

        let first = try analyzer.analyze(fileURL: referenceFile)
        let second = try analyzer.analyze(fileURL: referenceFile)

        XCTAssertEqual(first, second, "Two L1 runs over identical bytes must have identical output")
        XCTAssertEqual(first.durationSeconds, 172.6, accuracy: 0.1)
        XCTAssertEqual(first.codec, "mp3")
        XCTAssertEqual(first.sampleRate, 44_100)
        XCTAssertEqual(first.channels, 2)
        XCTAssertEqual(first.bitRate, 192_000)
        XCTAssertEqual(first.tempoBPM, 117.5, accuracy: 0.1)
        XCTAssertTrue(first.tempoOctaveAmbiguous)
        XCTAssertEqual(first.keyEstimate, "B-flat major")
        XCTAssertEqual(first.keyCorrelation, 0.767, accuracy: 0.02)
        XCTAssertFalse(first.keySettled, "A key correlation below 0.8 must remain unsettled")
        XCTAssertEqual(first.peakDBFS, 0.0, accuracy: 0.01)
        XCTAssertTrue(first.limitedAtCeiling, "A peak at or above -0.1 dBFS must be ceiling-limited")
        XCTAssertEqual(first.dynamicsStdDB, 13.0, accuracy: 0.2)
        XCTAssertEqual(first.segmentBoundariesSeconds.count, 6)

        XCTAssertTrue(first.metadataProducer.version.contains("ffprobe version"))
        XCTAssertTrue(first.signalProducer.version.contains("ffmpeg version"))
        XCTAssertTrue(first.signalProducer.version.contains("Python"))
        XCTAssertTrue(first.signalProducer.version.contains("NumPy"))

        let record = try first.makeRecord(
            contentHash: String(repeating: "b", count: 64),
            computedAt: "2026-09-03T08:00:00Z"
        )
        XCTAssertEqual(record.fields.count, 17)
        for (name, field) in record.fields {
            XCTAssertEqual(field.tier, .computed, "Unexpected tier for \(name)")
            XCTAssertNil(field.confidence, "Computed field \(name) must not carry confidence")
            XCTAssertFalse(field.producer.version.isEmpty, "Missing tool version for \(name)")
        }
        XCTAssertEqual(record.fields["tempoOctaveAmbiguous"]?.value, .boolean(true))
        XCTAssertEqual(record.fields["keySettled"]?.value, .boolean(false))
        XCTAssertEqual(record.fields["limitedAtCeiling"]?.value, .boolean(true))
    }

    private func referenceFileURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["AUDIO_ANALYSIS_REFERENCE_FILE"] {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("AUDIO_ANALYSIS_REFERENCE_FILE does not exist: \(url.path)")
            }
            return url
        }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .deletingLastPathComponent()
            .appendingPathComponent("Losen/e-post/vedlegg/OPP_OG_STA_morgenmarsj.mp3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Reference audio is not present at \(url.path)")
        }
        return url
    }
}
