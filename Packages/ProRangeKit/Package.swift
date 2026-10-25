// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProRangeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PRCore", targets: ["PRCore"]),
        .library(name: "PRImaging", targets: ["PRImaging"]),
        .library(name: "PRStorage", targets: ["PRStorage"]),
        .library(name: "PREngine", targets: ["PREngine"]),
        .library(name: "PRUI", targets: ["PRUI"]),
    ],
    targets: [
        // Maths, projections, couleur, rasteriseur de référence CPU. Aucune dépendance.
        .target(name: "PRCore"),
        // Codecs, import/export (phase 7).
        .target(name: "PRImaging", dependencies: ["PRCore"]),
        // Tuiles éparses, format de projet, journal d'opérations (phase 1).
        .target(name: "PRStorage", dependencies: ["PRCore"]),
        // Metal : pinceau, composition, filtres.
        .target(name: "PREngine", dependencies: ["PRCore", "PRStorage"]),
        // Composants SwiftUI partagés.
        .target(name: "PRUI", dependencies: ["PRCore", "PREngine"]),

        .testTarget(name: "PRCoreTests", dependencies: ["PRCore"]),
        .testTarget(name: "PRStorageTests", dependencies: ["PRCore", "PRStorage"]),
    ]
)
