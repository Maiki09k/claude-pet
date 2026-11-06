// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClaudePet",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "ClaudePet",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(name: "ClaudePetTests", dependencies: ["ClaudePet"])
    ],
    // Swift 5 mode keeps Process and pipe handling simple; all UI state lives on the main actor anyway.
    swiftLanguageModes: [.v5]
)
