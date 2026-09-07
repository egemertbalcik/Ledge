// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ledge",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Ledge", targets: ["LedgeApp"]),
        .executable(name: "LedgePreview", targets: ["LedgePreview"]),
        // Loaded by /usr/bin/perl at runtime, never linked by anything here.
        // Perl is Apple-signed and entitled for MediaRemote, so code dlopened
        // into it inherits that entitlement — which is the only way to read
        // now-playing information since macOS 15.4 closed the gate.
        .library(name: "LedgeMediaAdapter", type: .dynamic, targets: ["LedgeMediaAdapter"]),
    ],
    dependencies: [
        // In-app updates for distribution outside the App Store. Confined to
        // the composition root: nothing below LedgeApp knows updates exist.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        // Pure domain. Foundation only — no AppKit, no SwiftUI, no IOKit.
        .target(name: "LedgeCore"),

        // Every private / permission-gated capability, behind protocols.
        .target(name: "LedgeSystem", dependencies: ["LedgeCore"]),

        // Turns system signals into activities. Testable against stubs.
        .target(name: "LedgeProviders", dependencies: ["LedgeCore", "LedgeSystem"]),

        // Views. Takes values, never providers.
        .target(name: "LedgeUI", dependencies: ["LedgeCore"]),

        // Window layer: panels, screen observation, hover tracking.
        .target(
            name: "LedgeShell",
            dependencies: ["LedgeCore", "LedgeUI", "LedgeSystem", "LedgeProviders"]
        ),

        // Composition root.
        .executableTarget(
            name: "LedgeApp",
            dependencies: [
                "LedgeCore", "LedgeSystem", "LedgeProviders", "LedgeUI", "LedgeShell",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // Sparkle.framework ships inside Contents/Frameworks; without
                // this rpath the bundled app dies at load with "Library not
                // loaded". Development runs resolve it from .build instead.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),

        // Stands in for Xcode previews, which are unavailable here: a plain
        // window rendering every card in every state.
        .executableTarget(name: "LedgePreview", dependencies: ["LedgeUI", "LedgeCore"]),

        // Plain ObjC, deliberately: it is injected into a process Apple ships,
        // so it must drag in nothing beyond what is already resident there. A
        // Swift dylib would additionally load the Swift runtime inside perl.
        .target(
            name: "LedgeMediaAdapter",
            cSettings: [.unsafeFlags(["-fvisibility=hidden"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),

        .testTarget(name: "LedgeCoreTests", dependencies: ["LedgeCore"]),
        .testTarget(
            name: "LedgeProvidersTests",
            dependencies: ["LedgeProviders", "LedgeCore", "LedgeSystem"]
        ),
        .testTarget(name: "LedgeSystemTests", dependencies: ["LedgeSystem", "LedgeCore"]),
        .testTarget(name: "LedgeUITests", dependencies: ["LedgeUI", "LedgeCore"]),
        .testTarget(name: "LedgeShellTests", dependencies: ["LedgeShell", "LedgeCore", "LedgeProviders", "LedgeUI"]),
    ],
    swiftLanguageModes: [.v6]
)
