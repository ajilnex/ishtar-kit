// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ishtar-kit",
    defaultLocalization: "fr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IshtarCatalog", targets: ["IshtarCatalog"]),
        .library(name: "IshtarIngest", targets: ["IshtarIngest"]),
        .library(name: "IshtarSearch", targets: ["IshtarSearch"]),
        .library(name: "IshtarDaemon", targets: ["IshtarDaemon"]),
        .executable(name: "ishtar", targets: ["ishtar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "IshtarCatalog",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "IshtarIngest",
            dependencies: ["IshtarCatalog"]
        ),
        .target(
            name: "IshtarSearch",
            dependencies: ["IshtarCatalog", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "IshtarDaemon",
            dependencies: ["IshtarCatalog", "IshtarSearch"]
        ),
        .executableTarget(
            name: "ishtar",
            dependencies: [
                "IshtarCatalog", "IshtarIngest", "IshtarSearch",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "IshtarKitTests",
            dependencies: ["IshtarCatalog", "IshtarIngest", "IshtarSearch"]
        ),
    ]
)
