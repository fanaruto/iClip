// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iClip",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "iClip", targets: ["iClip"])
    ],
    targets: [
        .executableTarget(
            name: "iClip",
            path: "Sources/iClip",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Vision"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .testTarget(
            name: "iClipTests",
            dependencies: ["iClip"],
            path: "Tests/iClipTests"
        )
    ]
)
