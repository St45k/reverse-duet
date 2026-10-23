// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ReverseDuet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ReverseDuet", targets: ["ReverseDuet"]),
    ],
    targets: [
        // Thin Objective-C wrapper around the private CGVirtualDisplay API
        // (used for "Extend" mode, i.e. a real second screen).
        .target(
            name: "CGVirtualDisplayBridge",
            path: "Sources/CGVirtualDisplayBridge",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "ReverseDuet",
            dependencies: ["CGVirtualDisplayBridge"],
            path: "Sources/ReverseDuet",
            resources: [.copy("Web")],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreImage"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
