// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QingJian",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "QingJian", targets: ["QingJian"])
    ],
    targets: [
        .executableTarget(
            name: "QingJian",
            path: "Sources/QingJian",
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
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .testTarget(
            name: "QingJianTests",
            dependencies: ["QingJian"],
            path: "Tests/QingJianTests"
        )
    ]
)
