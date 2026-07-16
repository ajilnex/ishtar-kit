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
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        // sqlite-vec (MIT/Apache-2.0), amalgamation C : recherche vectorielle
        // dans SQLite. Conforme à la politique de licences (60-CAP §2).
        .target(
            name: "CSQLiteVec",
            cSettings: [.define("SQLITE_CORE")]
        ),
        .target(
            name: "IshtarCatalog",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "IshtarIngest",
            dependencies: [
                "IshtarCatalog",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(
            name: "IshtarSearch",
            dependencies: [
                "IshtarCatalog", "CSQLiteVec",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "IshtarDaemon",
            dependencies: [
                "IshtarCatalog", "IshtarSearch",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
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
            dependencies: ["IshtarCatalog", "IshtarIngest", "IshtarSearch", "IshtarDaemon"]
        ),
    ]
)
