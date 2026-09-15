// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DuoIcon",
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
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
