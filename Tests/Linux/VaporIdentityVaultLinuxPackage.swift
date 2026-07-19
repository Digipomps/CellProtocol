// swift-tools-version:5.8
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import PackageDescription

/// Dependency-minimal Linux gate for the production Vapor identity vault.
///
/// The workflow copies this manifest, the exact production Sources tree, and
/// VaporIdentityVaultStrictTests into a disposable package root. CellVapor is
/// deliberately limited to VaporIdentityVault.swift because that source has no
/// CFileUtils dependency. This lets Linux CI execute the actual vault storage
/// tests without granting this repository access to the private FileUtils-c
/// repository or replacing it with a behavioral stub.
let package = Package(
    name: "VaporIdentityVaultLinuxGate",
    platforms: [
        .macOS(.v13), .iOS(.v16), .tvOS(.v13),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", exact: "1.9.0"),
        .package(url: "https://github.com/OpenCombine/OpenCombine.git", exact: "0.14.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        .package(url: "https://github.com/GiacomoLeopizzi/random-swift", exact: "1.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.3.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "5.7.0"),
    ],
    targets: [
        .target(
            name: "CombineHelpers",
            dependencies: [
                "OpenCombine",
                .product(name: "OpenCombineFoundation", package: "OpenCombine"),
                .product(name: "OpenCombineDispatch", package: "OpenCombine"),
            ],
            path: "Sources/CombineHelpers"
        ),
        .target(name: "CodableHelpers", path: "Sources/CodableHelpers"),
        .target(
            name: "HavenCoreSchemas",
            path: "Sources/HavenCoreSchemas"
        ),
        .target(
            name: "TaxonomyResolver",
            dependencies: ["HavenCoreSchemas"],
            path: "Sources/TaxonomyResolver"
        ),
        .target(
            name: "KeyPathResolver",
            dependencies: ["HavenCoreSchemas", "TaxonomyResolver"],
            path: "Sources/KeyPathResolver"
        ),
        .target(
            name: "CellBase",
            dependencies: [
                "OpenCombine",
                .product(name: "OpenCombineFoundation", package: "OpenCombine"),
                .product(name: "OpenCombineDispatch", package: "OpenCombine"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Random", package: "random-swift"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "BigInt", package: "BigInt"),
                "HavenCoreSchemas",
                "CombineHelpers",
                "CodableHelpers",
                "KeyPathResolver",
            ],
            path: "Sources/CellBase"
        ),
        .target(
            name: "CellVapor",
            dependencies: [
                "CellBase",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/CellVapor",
            sources: [
                "VaporBridgeIdentitySnapshot.swift",
                "VaporIdentityVault.swift",
            ]
        ),
        .testTarget(
            name: "VaporIdentityVaultLinuxTests",
            dependencies: ["CellBase", "CellVapor"],
            path: "Tests/VaporIdentityVaultLinuxTests"
        ),
    ]
)
