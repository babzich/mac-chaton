import ProjectDescription

let sharedSettings: Settings = .settings(
    base: [
        "ARCHS": "arm64",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path @executable_path/Frameworks",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "SWIFT_VERSION": "6.0",
    ]
)

let appTargetSettings: Settings = .settings(
    base: [
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    ]
)

let project = Project(
    name: "LeChaton",
    organizationName: "vincentbach",
    options: .options(
        automaticSchemesOptions: .disabled,
        developmentRegion: "en"
    ),
    settings: sharedSettings,
    targets: [
        .target(
            name: "LeChatonCore",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.vincentbach.LeChatonCore",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            sources: ["Sources/LeChatonCore/**"],
            dependencies: [
                .external(name: "GRDB"),
                .external(name: "TOMLKit"),
            ]
        ),
        .target(
            name: "LeChaton",
            destinations: .macOS,
            product: .app,
            bundleId: "com.vincentbach.LeChaton",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "LeChaton",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "LSMinimumSystemVersion": "26.0",
                "NSHighResolutionCapable": true,
                "NSPrincipalClass": "NSApplication",
            ]),
            sources: ["Sources/LeChaton/**"],
            resources: ["Sources/LeChaton/Resources/**"],
            dependencies: [
                .target(name: "LeChatonCore"),
            ],
            settings: appTargetSettings
        ),
        .target(
            name: "ACPProbe",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "com.vincentbach.ACPProbe",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            sources: [
                "Sources/ACPProbe/**",
                "Sources/ACPProbeSupport/**",
            ],
            dependencies: [
                .target(name: "LeChatonCore"),
            ]
        ),
        .target(
            name: "FakeACPAgent",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "com.vincentbach.FakeACPAgent",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            sources: ["Sources/FakeACPAgent/**"],
            dependencies: [
                .target(name: "LeChatonCore"),
            ]
        ),
        .target(
            name: "LeChatonTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.vincentbach.LeChatonTests",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            sources: [
                "Tests/LeChatonTests/**",
                "Sources/ACPProbeSupport/**",
            ],
            dependencies: [
                .target(name: "LeChatonCore"),
                .target(name: "FakeACPAgent"),
            ]
        ),
    ],
    schemes: [
        .scheme(
            name: "LeChaton",
            shared: true,
            buildAction: .buildAction(targets: ["LeChaton"]),
            testAction: .targets(["LeChatonTests"]),
            runAction: .runAction(executable: "LeChaton")
        ),
        .scheme(
            name: "ACPProbe",
            shared: true,
            buildAction: .buildAction(targets: ["ACPProbe"]),
            runAction: .runAction(executable: "ACPProbe")
        ),
        .scheme(
            name: "FakeACPAgent",
            shared: true,
            buildAction: .buildAction(targets: ["FakeACPAgent"]),
            runAction: .runAction(executable: "FakeACPAgent")
        ),
    ]
)
