// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CellNearby",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16)],
    products: [.library(name: "CellNearby", targets: ["CellNearby"]),
               .executable(name: "haven-nearby", targets: ["HavenNearbyCLI"])],
    targets: [.target(name: "CellNearby"),
              .executableTarget(name: "HavenNearbyCLI", dependencies: ["CellNearby"]),
              .testTarget(name: "CellNearbyTests", dependencies: ["CellNearby"])]
)
