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

        // Owns CoreAudio / CoreMediaIO listener registrations in C, because
        // Swift cannot hand those APIs the same block pointer twice and they
        // match on pointer identity to unregister. See the header.
        .target(
            name: "LedgeAudioListen",
            // Manual reference counting, deliberately. The whole point of this
            // target is to own a block copy and hand out the identical pointer
            // twice; ARC would manage those lifetimes invisibly and the thing
            // being guaranteed would stop being visible in the source.
            cSettings: [.unsafeFlags(["-fno-objc-arc"])],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMediaIO"),
            ]
        ),

        // Every private / permission-gated capability, behind protocols.
        // LedgeHelperKit comes in for the XPC contract alone: the app side
        // needs the protocol and the result codes to talk to the daemon, and
        // nothing above this line knows there is a daemon at all.
        .target(name: "LedgeSystem", dependencies: ["LedgeCore", "LedgeAudioListen", "LedgeHelperKit"]),

        // What the root daemon knows: the XPC contract and the state machine
        // behind it, with nothing privileged in it and nothing of Ledge's own.
        // Foundation only, so the code that ends up running as root stays
        // small enough to read in one sitting, and so every interleaving the
        // lease depends on can be exercised with injected clocks rather than
        // with a Mac that has to be put to sleep to test it.
        .target(name: "LedgeHelperKit"),

        .executableTarget(name: "LedgeKeepAwakeHelper", dependencies: ["LedgeHelperKit"]),

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
        .testTarget(name: "LedgeHelperKitTests", dependencies: ["LedgeHelperKit"]),
        .testTarget(name: "LedgeKeepAwakeHelperTests", dependencies: ["LedgeKeepAwakeHelper"]),
        .testTarget(name: "LedgeUITests", dependencies: ["LedgeUI", "LedgeCore"]),
        .testTarget(name: "LedgeShellTests", dependencies: ["LedgeShell", "LedgeCore", "LedgeProviders", "LedgeUI"]),
    ],
    swiftLanguageModes: [.v6]
)
