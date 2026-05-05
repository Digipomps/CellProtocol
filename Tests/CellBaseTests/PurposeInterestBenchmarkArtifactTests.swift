// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import PurposeInterestBenchmarkSupport

final class PurposeInterestBenchmarkArtifactTests: XCTestCase {
    func testBenchmarkArtifactMatchesCheckedInBaseline() async throws {
        let artifact = try await PerspectiveMatchingScenarioSupport.buildBenchmarkArtifact()
        let currentJSON = try canonicalJSON(artifact)
        let baselineData = try Data(contentsOf: PerspectiveMatchingScenarioSupport.baselineURL())
        let baselineArtifact = try JSONDecoder().decode(ScenarioBenchmarkArtifact.self, from: baselineData)
        let baselineJSON = try canonicalJSON(PerspectiveMatchingScenarioSupport.normalizedArtifact(baselineArtifact))

        XCTAssertEqual(artifact.schemaVersion, "1.0")
        XCTAssertFalse(artifact.curated.isEmpty)
        XCTAssertFalse(artifact.challenge.methods.isEmpty)
        XCTAssertEqual(currentJSON, baselineJSON)
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            XCTFail("Unable to encode canonical json")
            return ""
        }
        return string
    }
}
