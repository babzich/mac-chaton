// swift-tools-version: 6.1
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    productTypes: [
        "GRDB": .framework,
    ]
)
#endif

let package = Package(
    name: "LeChatonDependencies",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        ),
    ]
)
