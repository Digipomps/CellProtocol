// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A class that provides landmark data for the app.
*/

import Foundation
import CellBase
@preconcurrency import MapKit
import CoreLocation
import Synchronization

@available(macOS 26.0, iOS 26.0, *)
@Observable
class ModelData {
    @MainActor
    static let shared = ModelData()
    nonisolated static let landmarkLoadResult = Result {
        try parseLandmarks(fileName: "landmarkData.json")
    }
    
    var landmarksByContinent: [String: [Landmark]] = [:]
    var featuredLandmark: Landmark?
    var landmarksByID: [Int: Landmark] = [:]
    private(set) var loadError: Error?
        
    private init() {
        loadLandmarks()
    }
    
    func loadLandmarks() {
        let landmarks: [Landmark]
        switch ModelData.landmarkLoadResult {
        case .success(let loadedLandmarks):
            landmarks = loadedLandmarks
            loadError = nil
        case .failure(let error):
            landmarks = []
            loadError = error
            CellBase.diagnosticLog("Landmark fixture unavailable: \(error)", domain: .lifecycle)
        }

        landmarksByContinent = landmarksByContinent(from: landmarks)
        
        for landmark in landmarks {
            landmarksByID[landmark.id] = landmark
        }

        if let primaryLandmark = landmarksByID[1016] {
            featuredLandmark = primaryLandmark
        }
    }
    
    private func landmarksByContinent(from landmarks: [Landmark]) -> [String: [Landmark]] {
        var landmarksByContinent: [String: [Landmark]] = [:]
        for landmark in landmarks {
            landmarksByContinent[landmark.continent, default: []].append(landmark)
        }
        return landmarksByContinent
    }
    
    static func parseLandmarks(fileName: String) throws -> [Landmark] {
        guard let file = Bundle.main.url(forResource: fileName, withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: fileName])
        }

        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode([Landmark].self, from: data)
    }
}
