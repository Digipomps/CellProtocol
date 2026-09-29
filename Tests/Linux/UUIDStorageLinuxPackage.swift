// swift-tools-version:5.8
import PackageDescription

// The gate copies the exact production implementation, tests, and shared fixtures.
let package = Package(
    name: "UUIDStorageLinuxGate",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CellIdentifierSupport"),
        .testTarget(name: "CellIdentifierStorageTests", dependencies: ["CellIdentifierSupport"], exclude: ["Fixtures"]),
    ]
)
