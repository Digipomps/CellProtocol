import Foundation

struct RadarCluster: Identifiable {
    let id: String
    let x: Double
    let y: Double
    let members: [RadarBlip]
}

enum RadarClustering {
    /// Bucket in screen space. Stable ids and bounded work even when thousands overlap.
    static func groups(_ blips: [RadarBlip], radius: Double, cellSize: Double = 48) -> [RadarCluster] {
        guard radius.isFinite, radius > 0, cellSize.isFinite, cellSize >= 1 else { return [] }
        let valid = blips.filter { $0.hasDirection && $0.x.isFinite && $0.y.isFinite && hypot($0.x, $0.y) <= 1.01 }
        let groups = Dictionary(grouping: valid) { blip in
            "\(Int(floor(blip.x * radius / cellSize))):\(Int(floor(blip.y * radius / cellSize)))"
        }
        var clusters = groups.keys.sorted().map { id in
            let members = groups[id]!.sorted { $0.id < $1.id }
            return RadarCluster(id: id, x: members.reduce(0) { $0 + $1.x } / Double(members.count),
                                y: members.reduce(0) { $0 + $1.y } / Double(members.count), members: members)
        }
        // Merge adjacent buckets whose centroids would create overlapping hit targets.
        // This runs over the small set of screen buckets, never all pairs of peers.
        while clusters.count > 1 {
            var nearest: (Int, Int)?
            var minimum = cellSize / radius
            for a in clusters.indices {
                for b in clusters.indices where b > a {
                    let distance = hypot(clusters[a].x - clusters[b].x, clusters[a].y - clusters[b].y)
                    if distance < minimum { minimum = distance; nearest = (a, b) }
                }
            }
            guard let (a, b) = nearest else { break }
            let members = (clusters[a].members + clusters[b].members).sorted { $0.id < $1.id }
            clusters[a] = RadarCluster(id: clusters[a].id,
                x: members.reduce(0) { $0 + $1.x } / Double(members.count),
                y: members.reduce(0) { $0 + $1.y } / Double(members.count), members: members)
            clusters.remove(at: b)
        }
        return clusters
    }
}
