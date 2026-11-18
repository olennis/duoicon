// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DuoIcon",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "DuoIcon",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Combine"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("IOKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
