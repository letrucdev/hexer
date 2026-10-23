// swift-tools-version: 6.2
import Foundation
import PackageDescription

// With only the Command Line Tools installed, SwiftPM sometimes compiles test targets without
// loading swift-testing's macro plugin; point the compiler at it explicitly. Not when an Xcode is
// selected through DEVELOPER_DIR (as in CI): its toolchain brings its own plugin.
let testingPluginDir = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let usesXcode = Context.environment["DEVELOPER_DIR"]?.contains(".app/") ?? false
let testSettings: [SwiftSetting] = !usesXcode && FileManager.default.fileExists(atPath: testingPluginDir)
    ? [.unsafeFlags(["-plugin-path", testingPluginDir])]
    : []

let package = Package(
    name: "Hexer",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Hexer", targets: ["Hexer"]),
        .executable(name: "hexer-cli", targets: ["HexerCLI"]),
    ],
    targets: [
        .target(name: "HexerCore"),
        // Capstone 5.0.9, vendored by Scripts/fetch_capstone.sh with only the X86 and AArch64 back ends.
        .target(
            name: "CCapstone",
            cSettings: [
                .define("CAPSTONE_HAS_X86"),
                .define("CAPSTONE_HAS_ARM64"),
                .define("CAPSTONE_USE_SYS_DYN_MEM"),
                .define("NDEBUG", .when(configuration: .release)),
                .unsafeFlags(["-w"]),  // third-party code: ~36 -Wshorten-64-to-32 warnings otherwise
            ]
        ),
        .target(name: "HexerDisasm", dependencies: ["CCapstone"]),
        // Descriptor passing (SCM_RIGHTS) and disk ioctls that Swift cannot call directly.
        .target(name: "CHexerSys"),
        // Raw disks: enumeration (IOKit + DiskArbitration), authopen, sector I/O, cloning.
        .target(
            name: "HexerPlatform",
            dependencies: ["HexerCore", "CHexerSys"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "Hexer",
            dependencies: ["HexerCore", "HexerDisasm", "HexerPlatform"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(name: "HexerCLI", dependencies: ["HexerCore", "HexerDisasm", "HexerPlatform"]),
        .testTarget(name: "HexerCoreTests", dependencies: ["HexerCore"], swiftSettings: testSettings),
        .testTarget(name: "HexerDisasmTests", dependencies: ["HexerDisasm"], swiftSettings: testSettings),
        .testTarget(
            name: "HexerPlatformTests",
            dependencies: ["HexerPlatform", "HexerCore", "CHexerSys"],
            swiftSettings: testSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
