// swift-tools-version:5.8
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CellProtocol",
    platforms: [
        .macOS(.v13), .iOS(.v16), .tvOS(.v13)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(name: "CellBase", targets: ["CellBase"]),
        .library(name: "CombineHelpers", targets: ["CombineHelpers"]),
        .library(name: "CodableHelpers", targets: ["CodableHelpers"]),
        .library(name: "CellApple", targets: ["CellApple"]),
        .library(name: "CellVapor", targets: ["CellVapor"]),
        .library(name: "HavenCoreSchemas", targets: ["HavenCoreSchemas"]),
        .library(name: "HavenPerspectiveSchemas", targets: ["HavenPerspectiveSchemas"]),
        .library(name: "TaxonomyResolver", targets: ["TaxonomyResolver"]),
        .library(name: "KeyPathResolver", targets: ["KeyPathResolver"]),
        .executable(name: "haven-commons", targets: ["HavenCommonsCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.4.1"),
        .package(url: "https://github.com/OpenCombine/OpenCombine.git", from: "0.13.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "4.0.0"),
        .package(url: "https://github.com/GiacomoLeopizzi/random-swift", from: "1.0.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.1"),
        .package(url: "https://github.com/Digipomps/FileUtils-c.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-collections.git", "1.1.0" ..< "2.0.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.4.0"),
    ],
    targets: [
        .target(name: "CombineHelpers",
                dependencies: [
                    "OpenCombine",
                    .product(name: "OpenCombineFoundation", package: "OpenCombine"),
                    .product(name: "OpenCombineDispatch", package: "OpenCombine"),
                ]),
        .target(name: "CodableHelpers"),
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
                .product(name: "BigInt", package: "bigint"),
                .target(name: "HavenCoreSchemas"),
                .target(name: "CombineHelpers"),
                .target(name: "CodableHelpers"),
                .target(name: "KeyPathResolver"),
            ]),
        .target(name: "CellApple",
                dependencies: [
                    .target(name: "CellBase"),
                    .target(name: "CombineHelpers"),
                    .target(name: "CodableHelpers"),
                    .product(name: "CFileUtils", package: "fileutils-c"),
                ]),
        .target(name: "CellVapor",
                dependencies: [
                    .target(name: "CellBase"),
                    .product(name: "Crypto", package: "swift-crypto"),
                    .product(name: "Vapor", package: "vapor"),
                    .product(name: "CFileUtils", package: "fileutils-c"),
                ]),
        .target(
            name: "HavenCoreSchemas",
            path: "commons/schemas/haven.core/Sources/HavenCoreSchemas"
        ),
        .target(
            name: "HavenPerspectiveSchemas",
            dependencies: [
                .target(name: "HavenCoreSchemas"),
            ],
            path: "commons/schemas/haven.perspective/Sources/HavenPerspectiveSchemas"
        ),
        .target(
            name: "TaxonomyResolver",
            dependencies: [
                .target(name: "HavenCoreSchemas"),
            ],
            path: "commons/resolver/taxonomy-resolver/Sources/TaxonomyResolver"
        ),
        .target(
            name: "KeyPathResolver",
            dependencies: [
                .target(name: "HavenCoreSchemas"),
                .target(name: "TaxonomyResolver"),
            ],
            path: "commons/resolver/keypath-resolver/Sources/KeyPathResolver"
        ),
        .target(
            name: "PurposeInterestBenchmarkSupport",
            dependencies: [
                .target(name: "CellBase"),
                .target(name: "HavenPerspectiveSchemas"),
            ],
            path: "commons/benchmarks/purpose-interest/Sources/PurposeInterestBenchmarkSupport"
        ),
        .executableTarget(
            name: "HavenCommonsCLI",
            dependencies: [
                .target(name: "KeyPathResolver"),
                .target(name: "PurposeInterestBenchmarkSupport"),
            ],
            path: "commons/cli/haven-commons/Sources/haven-commons"
        ),
//        .target(name: "CellVaporV2",
//                dependencies: [
//                    .product(name: "Vapor", package: "vapor"),
//                ]),
        .testTarget(
            name: "CellBaseTests",
            dependencies: [
                "CellBase",
                .target(name: "CodableHelpers"),
                .target(name: "HavenPerspectiveSchemas"),
                .target(name: "PurposeInterestBenchmarkSupport"),
                "CellApple",
                .target(name: "CellVapor", condition: .when(platforms: [.macOS])),
            ]),
        .testTarget(
            name: "HavenCommonsTests",
            dependencies: [
                .target(name: "TaxonomyResolver"),
                .target(name: "KeyPathResolver"),
                .target(name: "HavenPerspectiveSchemas"),
            ],
            path: "Tests/HavenCommonsTests"
        ),
    ]
)
