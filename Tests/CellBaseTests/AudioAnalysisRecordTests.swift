// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class AudioAnalysisRecordTests: XCTestCase {
    private let computedAt = "2026-09-03T08:00:00Z"

    func testRejectsFieldMissingTierOrProducer() {
        XCTAssertThrowsError(
            try makeRecord(field: AudioAnalysisFieldInput(
                value: .double(172.6),
                tier: nil,
                producer: producer(name: "ffprobe"),
                computedAt: computedAt
            ))
        ) { error in
            XCTAssertEqual(error as? AudioAnalysisRecordError, .missingTier(field: "durationSeconds"))
        }

        XCTAssertThrowsError(
            try makeRecord(field: AudioAnalysisFieldInput(
                value: .double(172.6),
                tier: .computed,
                producer: nil,
                computedAt: computedAt
            ))
        ) { error in
            XCTAssertEqual(error as? AudioAnalysisRecordError, .missingProducer(field: "durationSeconds"))
        }
    }

    func testRejectsComputedOrModelOpinionFieldCarryingConfidence() {
        for tier in [AudioAnalysisTier.computed, .modelOpinion] {
            XCTAssertThrowsError(
                try makeRecord(field: AudioAnalysisFieldInput(
                    value: .string("claim"),
                    tier: tier,
                    producer: producer(name: "producer"),
                    confidence: 0.9,
                    computedAt: computedAt
                ))
            ) { error in
                XCTAssertEqual(
                    error as? AudioAnalysisRecordError,
                    .confidenceForbidden(field: "durationSeconds", tier: tier)
                )
            }
        }
    }

    func testRejectsInferredFieldWithoutConfidence() {
        XCTAssertThrowsError(
            try makeRecord(field: AudioAnalysisFieldInput(
                value: .string("uplifting"),
                tier: .inferred,
                producer: producer(name: "CLAP"),
                labelVocabulary: ["uplifting", "somber"],
                computedAt: computedAt
            ))
        ) { error in
            XCTAssertEqual(error as? AudioAnalysisRecordError, .confidenceRequired(field: "durationSeconds"))
        }
    }

    func testRejectsInferredFieldWithoutLabelVocabulary() {
        XCTAssertThrowsError(
            try makeRecord(field: AudioAnalysisFieldInput(
                value: .string("uplifting"),
                tier: .inferred,
                producer: producer(name: "CLAP"),
                confidence: 0.72,
                computedAt: computedAt
            ))
        ) { error in
            XCTAssertEqual(
                error as? AudioAnalysisRecordError,
                .labelVocabularyRequired(field: "durationSeconds")
            )
        }
    }

    func testEncodeDecodeRoundTripPreservesAllFourTiers() throws {
        let record = try AudioAnalysisRecord(
            contentHash: String(repeating: "a", count: 64),
            fields: [
                "tempoBPM": AudioAnalysisFieldInput(
                    value: .double(117.5),
                    tier: .computed,
                    producer: producer(name: "audio-signal-v0"),
                    computedAt: computedAt
                ),
                "mood": AudioAnalysisFieldInput(
                    value: .string("uplifting"),
                    tier: .inferred,
                    producer: producer(name: "CLAP"),
                    confidence: 0.72,
                    labelVocabulary: ["uplifting", "somber"],
                    computedAt: computedAt
                ),
                "description": AudioAnalysisFieldInput(
                    value: .string("A bright brass-band march."),
                    tier: .modelOpinion,
                    producer: AudioAnalysisProducer(
                        toolOrModel: "language-model",
                        version: "model-v1",
                        paramsOrPrompt: .string("Describe the arrangement")
                    ),
                    computedAt: computedAt
                ),
                "title": AudioAnalysisFieldInput(
                    value: .string("OPP OG STÅ"),
                    tier: .declared,
                    producer: AudioAnalysisProducer(
                        toolOrModel: "ID3",
                        version: "2.4",
                        paramsOrPrompt: .object(["source": .string("file metadata")])
                    ),
                    computedAt: computedAt
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(record)
        let decoded = try JSONDecoder().decode(AudioAnalysisRecord.self, from: encoded)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(Set(decoded.fields.values.map(\.tier)), Set(AudioAnalysisTier.allCases))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("model_opinion"))
    }

    private func makeRecord(field: AudioAnalysisFieldInput) throws -> AudioAnalysisRecord {
        try AudioAnalysisRecord(
            contentHash: String(repeating: "a", count: 64),
            fields: ["durationSeconds": field]
        )
    }

    private func producer(name: String) -> AudioAnalysisProducer {
        AudioAnalysisProducer(
            toolOrModel: name,
            version: "1.0",
            paramsOrPrompt: .object(["fixture": .boolean(true)])
        )
    }
}
