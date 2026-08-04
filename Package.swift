// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let devMode = true
let branch = "master"

func getPlatformTarget() -> PackageDescription.Platform {
    // Package.swift is compiled by the *host* toolchain even when
    // cross-compiling, so `#if os(...)` only ever describes the host. Building
    // for Android from this Linux box would otherwise resolve to `.linux` and
    // link the Linux libthorvg. Android is always a cross-compile, so it is an
    // explicit env-var opt-in — SWIFT_ANDROID_HOME, matching NucleantVulkan,
    // CPython, PySwiftKit and PyNucleantUI.
    let env = ProcessInfo.processInfo.environment
    if env["SWIFT_ANDROID_HOME"] != nil || env["ANDROID_BUILD"] != nil {
        return .android
    }
#if os(Linux)
    return .linux
#else
    return .macOS
#endif
}

let platformTarget = getPlatformTarget()

// Set by pyswiftkit-builder for a wheel build — the signal that separates the
// two macOS modes (`uv run` against a wheel vs. the Xcode app embedding this
// package), which want the ThorVG binary in different shapes. Same use as in
// NucleantVulkan's Package.swift; see the binary targets below.
let PIP_MODE = ProcessInfo.processInfo.environment["PIP_MODE"] == "1"

/// Vendored Android artifacts for the ABI currently being built. Android
/// builds one architecture per `swift build`, so unlike Linux there is no
/// single lib directory. Mirrors NucleantVulkan's helper of the same name.
func androidABI() -> String {
    let env = ProcessInfo.processInfo.environment
    if let abi = env["SWIFT_ANDROID_ABI"], !abi.isEmpty {
        return abi
    }
    switch (env["SWIFT_TRIPLE"] ?? "").split(separator: "-").first.map(String.init) ?? "" {
    case "aarch64": return "arm64-v8a"
    case "x86_64":  return "x86_64"
    case "armv7":   return "armeabi-v7a"
    default:        return "arm64-v8a"
    }
}

func getDepedencies() -> [Package.Dependency] {
    var deps = [Package.Dependency]()
    if devMode {
        deps.append(.package(path: "../NucleantVulkan"))
    } else {
        deps.append(.package(url: "https://github.com/NucleantUI/NucleantVulkan", branch: branch))
    }
    //deps.append(.package(path: "../NucleantCore"))
    return deps
}

func thorTargets() -> [Target] {
    if platformTarget == .android {
        // Vendored libthorvg-1.so per ABI under Dependencies/android/<abi>/lib
        // — the same role Dependencies/linux/lib plays below. No -rpath: on
        // Android the loader resolves DT_NEEDED out of the app's native
        // library directory, where Gradle stages this .so, and a host path
        // baked in at build time would not exist on device.
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let androidLibDir = packageRoot
            .appendingPathComponent("Dependencies/android/\(androidABI())/lib").path
        return [
            .target(
                name: "CThorVG",
                path: "Sources/CThorVG",
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("include"),
                ],
                linkerSettings: [
                    .linkedLibrary("thorvg-1"),
                    .unsafeFlags(["-L\(androidLibDir)"]),
                ]
            ),
        ]
    }
    if platformTarget == .linux {
        // Vendored libthorvg-1.so (built with the `wg`/WebGPU engine) in
        // Dependencies/linux/lib, linked directly — same role
        // Dependencies/apple/ThorVG.xcframework plays below, just without
        // SPM binaryTarget/XCFramework support on Linux. Run
        // scripts/build_thorvg.py linux first (wraps thorvg-cython) to
        // (re)produce it. See Dependencies/linux/README.md.
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let linuxLibDir = packageRoot.appendingPathComponent("Dependencies/linux/lib").path
        return [
            .target(
                name: "CThorVG",
                path: "Sources/CThorVG",
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("include"),
                ],
                linkerSettings: [
                    .linkedLibrary("thorvg-1"),
                    .unsafeFlags([
                        "-L\(linuxLibDir)",
                        "-Xlinker", "-rpath", "-Xlinker", linuxLibDir,
                    ]),
                ]
            ),
        ]
    }
    var targets: [Target] = [
        .binaryTarget(
            name: "ThorVG",
            path: "Dependencies/apple/ThorVG.xcframework"
        ),
        // libomp (dynamic OpenMP) — iOS only. The iOS ThorVG.framework links
        // @rpath/libomp.framework/libomp, so it must be embedded; SPM does that
        // when CThorVG depends on this binary target. macOS's ThorVG statically
        // links libomp, so this xcframework carries iOS slices only and is only
        // depended on for iOS.
        .binaryTarget(
            name: "libomp",
            path: "Dependencies/apple/libomp.xcframework"
        ),
    ]
    // The same Mach-O as ThorVG.xcframework's macOS slice, minus the bundle:
    // @rpath/libthorvg-1.dylib instead of @rpath/ThorVG.framework/ThorVG. A
    // wheel vendors plain files into nucleant/.dylibs, so PIP_MODE links this
    // one on macOS; the Xcode/embed path keeps the framework, and iOS links a
    // framework either way. scripts/build_thorvg.py emits both from one build.
    if PIP_MODE {
        targets.append(
            .binaryTarget(
                name: "ThorVGLib",
                path: "Dependencies/apple/ThorVG_lib.xcframework"
            )
        )
    }
    targets.append(
        .target(
            name: "CThorVG",
            dependencies: PIP_MODE ? [
                .byName(name: "ThorVGLib", condition: .when(platforms: [.macOS])),
                .byName(name: "ThorVG", condition: .when(platforms: [.iOS, .tvOS, .macCatalyst])),
                .byName(name: "libomp", condition: .when(platforms: [.iOS])),
            ] : [
                "ThorVG",
                .byName(name: "libomp", condition: .when(platforms: [.iOS])),
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedFramework("QuartzCore", .when(platforms: [.iOS, .macOS, .tvOS])),
            ]
        )
    )
    return targets
}

func mainTargets() -> [Target] {
    return [
        .target(
            name: "NucleantThorVG",
            dependencies: [
                "CThorVG",
                .product(name: "NucleantVulkan", package: "NucleantVulkan")
            ]
        ),
        .testTarget(
            name: "NucleantThorVGTests",
            dependencies: ["NucleantThorVG"]
        ),
    ]
}

func getTargets() -> [Target] {
    var targets = [Target]()
    targets.append(contentsOf: mainTargets())
    targets.append(contentsOf: thorTargets())
    return targets
}

let package = Package(
    name: "NucleantThorVG",
    platforms: [
        // iOS 17 to match the graph's Observation-framework floor (macOS 14).
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "NucleantThorVG",
            targets: ["NucleantThorVG"]
        )
    ],
    dependencies: getDepedencies(),
    targets: getTargets()
)
