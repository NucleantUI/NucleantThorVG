// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

/// Build against the sibling checkouts (`../NucleantVulkan`) or GitHub.
///
/// GitHub unless `NUCLEANT_LOCAL_DEV=1` is in the environment: the sibling
/// checkouts are used only when that turns them on, never just because they
/// are there. Every Nucleant package reads the same variable, so one setting
/// covers the whole chain.
let devMode: Bool = ["1", "true", "yes"].contains(
    (ProcessInfo.processInfo.environment["NUCLEANT_LOCAL_DEV"] ?? "").lowercased()
)

func getPlatformTarget() -> PackageDescription.Platform {
    // Package.swift is compiled by the *host* toolchain even when
    // cross-compiling, so `#if os(...)` only ever describes the host. Building
    // for Android from this Linux box would otherwise resolve to `.linux` and
    // link the Linux libthorvg. Android is always a cross-compile, so it is an
    // explicit env-var opt-in — SWIFT_ANDROID_HOME, matching NucleantVulkan,
    // CPython and PySwiftKit.
    let env = ProcessInfo.processInfo.environment
    if env["SWIFT_ANDROID_HOME"] != nil || env["ANDROID_BUILD"] != nil {
        return .android
    }
    // WebAssembly (`swift build --swift-sdk <version>_wasm`) is a
    // cross-compile too, opted into the same way as in NucleantVulkan.
    if env["WASM_BUILD"] == "1" {
        return .wasi
    }
#if os(Linux)
    return .linux
#elseif os(Windows)
    // Native, like Linux: the Windows toolchain builds for the machine it
    // runs on.
    return .windows
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

// Opt-in only, never the default — see the identical flag in NucleantVulkan's
// Package.swift for the full rationale. Must match between the two packages'
// builds, since this file's makeThorNode(importingHardwareBuffer:) calls
// straight into NucleantVulkan's WgpuContext.Target.nativeAndroidHardwareBuffer().
let ANDROID_USE_AHARDWAREBUFFER = ProcessInfo.processInfo.environment["NUCLEANT_ANDROID_USE_AHARDWAREBUFFER"] == "1"

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

/// Each prebuilt archive on the latest GitHub release, by file name: its URL
/// and checksum. Written here by .github/workflows/release.yml, which commits
/// it to master with the release — so master and the release's tag both
/// build from exactly the archives on that release. In this file, not one it
/// reads, because SwiftPM caches a manifest's evaluation by its text (and
/// environment), not by the files it looks at. Empty only before the first
/// release.
let releasedThorVG: [String: (url: String, checksum: String)] = [
    "ThorVG.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantThorVG/releases/download/0.1.0/ThorVG.xcframework.zip",
        checksum: "73acbea2ac363a9de3ab09e85e8b7eb5ebaa40cf639988af9d73b763a7e75b66"
    ),
    "ThorVG_lib.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantThorVG/releases/download/0.1.0/ThorVG_lib.xcframework.zip",
        checksum: "9a24d938ae6430fd60546d14ef44f3cc91973cd3666a94824f9f5f9f2b30e0ce"
    ),
    "libomp.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantThorVG/releases/download/0.1.0/libomp.xcframework.zip",
        checksum: "569194053e40d0e9d780b592cd2e76e16835b8ae4ec966cd2a347be56db80f20"
    ),
    "thorvg-android-arm64-v8a.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantThorVG/releases/download/0.1.0/thorvg-android-arm64-v8a.artifactbundle.zip",
        checksum: "f3904bf91cb2a2ddb75c26732258400b2961d3b849e629102e417265f425b7a5"
    ),
    "thorvg-android-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantThorVG/releases/download/0.1.0/thorvg-android-x86_64.artifactbundle.zip",
        checksum: "f2c26a6379b85a8907a63fa5cb01d8de6d637386d063951b52b374a1c718cf3d"
    ),
    "thorvg-linux-aarch64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantThorVG/releases/download/0.1.0/thorvg-linux-aarch64.artifactbundle.zip",
        checksum: "98620238d890020fc4ff76c8e78f3a83d2d7938c80865cb51ae5cc4ab884c02b"
    ),
    "thorvg-linux-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantThorVG/releases/download/0.1.0/thorvg-linux-x86_64.artifactbundle.zip",
        checksum: "caefe714d7824898fdc013c5edc747807ec0b395eee400027e7153515a036ed6"
    ),
    "thorvg-wasm32.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantThorVG/releases/download/0.1.0/thorvg-wasm32.artifactbundle.zip",
        checksum: "2bea14dff5f01db0ac4e14bb56e75c5bd0e5093fd858a34e2a0ebf4ecb1219f9"
    ),
    "thorvg-windows-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantThorVG/releases/download/0.1.0/thorvg-windows-x86_64.artifactbundle.zip",
        checksum: "0be8b8d83dd71b521ba6dc77d54a9259a0038e0da4d0c605942a0d4bdf01a260"
    ),
]

/// With NUCLEANT_THORVG_ARTIFACTS=1, the archives in Artifacts/ — the ones
/// .github/workflows/build-deps.yml has just built, put there to build and
/// test against. They come before the release's, which they are about to
/// replace.
let localArtifacts = ProcessInfo.processInfo.environment["NUCLEANT_THORVG_ARTIFACTS"] == "1"

/// ThorVG comes prebuilt: from Artifacts/ (above), or from the release.
/// Otherwise — before the first release — from the vendored Dependencies/.
let prebuiltThorVG = localArtifacts || !releasedThorVG.isEmpty

/// A prebuilt archive as a binary target: Artifacts/, else the release's URL.
func prebuiltBinary(_ name: String, _ archive: String) -> Target {
    if !localArtifacts, let release = releasedThorVG[archive] {
        return .binaryTarget(name: name, url: release.url, checksum: release.checksum)
    }
    return .binaryTarget(name: name, path: "Artifacts/\(archive)")
}

/// One of Dependencies/apple's xcframeworks, or its prebuilt zip.
func appleBinary(_ name: String, _ xcframework: String) -> Target {
    if prebuiltThorVG {
        return prebuiltBinary(name, "\(xcframework).zip")
    }
    return .binaryTarget(name: name, path: "Dependencies/apple/\(xcframework)")
}

/// ThorVG on Linux, Windows, Android and wasm, as one artifact bundle per
/// platform and architecture (scripts/make_artifactbundle.py). On Linux and
/// Android the bundle holds libthorvg-1.so itself — SwiftPM copies it next to
/// the product and links it, beside NucleantVulkan's libwgpu_native.so, which
/// it links. On Windows it holds thorvg-1.dll's import library, which the
/// product links, and the DLL, which SwiftPM copies next to it, beside
/// NucleantVulkan's wgpu_native.dll.
func prebuiltLibrariesArchive() -> String {
    switch platformTarget {
    case .wasi:
        return "thorvg-wasm32.artifactbundle.zip"
    case .android:
        return "thorvg-android-\(androidABI()).artifactbundle.zip"
    case .windows:
        // Native, as on Linux.
#if arch(arm64)
        return "thorvg-windows-arm64.artifactbundle.zip"
#else
        return "thorvg-windows-x86_64.artifactbundle.zip"
#endif
    default:
        // Linux builds are native, so the host's architecture is the target's.
#if arch(arm64)
        return "thorvg-linux-aarch64.artifactbundle.zip"
#else
        return "thorvg-linux-x86_64.artifactbundle.zip"
#endif
    }
}

/// CThorVG over the prebuilt bundle, off Apple's platforms. No unsafeFlags —
/// SwiftPM refuses them in a package depended on by version — so the binary
/// target gives the library and CThorVG keeps only its header.
func prebuiltThorTargets() -> [Target] {
    return [
        prebuiltBinary("thorvg", prebuiltLibrariesArchive()),
        .target(
            name: "CThorVG",
            dependencies: ["thorvg"],
            path: "Sources/CThorVG",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            // ThorVG is C++: on wasm, libc++/libc++abi from the SDK's sysroot.
            linkerSettings: platformTarget == .wasi ? [
                .linkedLibrary("c++"),
                .linkedLibrary("c++abi"),
            ] : []
        ),
    ]
}

func getDepedencies() -> [Package.Dependency] {
    var deps = [Package.Dependency]()
    if devMode {
        deps.append(.package(path: "../NucleantVulkan"))
    } else {
        // 0.1.0: the shared VulkanRenderDevice the nodes take.
        deps.append(.package(url: "https://github.com/NucleantUI/NucleantVulkan", .upToNextMajor(from: "0.1.0")))
    }
    //deps.append(.package(path: "../NucleantCore"))
    return deps
}

func thorTargets() -> [Target] {
    if prebuiltThorVG && [.wasi, .android, .linux, .windows].contains(platformTarget) {
        return prebuiltThorTargets()
    }
    if platformTarget == .wasi {
        // Vendored libthorvg.a for wasm32-wasip1 under Dependencies/wasm/lib,
        // built with the `wg` engine by scripts/build_thorvg_wasm.py — the
        // same role Dependencies/linux/lib plays above. Its webgpu.h calls
        // resolve against NucleantVulkan's CWgpu, which on wasm is webgpu.h
        // implemented on the browser's WebGPU — the device the Vulkan
        // implementation runs on, so ThorVG draws straight into textures the
        // engine samples. ThorVG is C++: libc++/libc++abi come from the wasm
        // SDK's sysroot.
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let wasmLibDir = packageRoot.appendingPathComponent("Dependencies/wasm/lib").path
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
                    .linkedLibrary("c++"),
                    .linkedLibrary("c++abi"),
                    .unsafeFlags(["-L\(wasmLibDir)"]),
                ]
            ),
        ]
    }
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
        appleBinary("ThorVG", "ThorVG.xcframework"),
        // libomp (dynamic OpenMP) — iOS only. The iOS ThorVG.framework links
        // @rpath/libomp.framework/libomp, so it must be embedded; SPM does that
        // when CThorVG depends on this binary target. macOS's ThorVG statically
        // links libomp, so this xcframework carries iOS slices only and is only
        // depended on for iOS.
        appleBinary("libomp", "libomp.xcframework"),
    ]
    // The same Mach-O as ThorVG.xcframework's macOS slice, minus the bundle:
    // @rpath/libthorvg-1.dylib instead of @rpath/ThorVG.framework/ThorVG. A
    // wheel vendors plain files into nucleant/.dylibs, so PIP_MODE links this
    // one on macOS; the Xcode/embed path keeps the framework, and iOS links a
    // framework either way. scripts/build_thorvg.py emits both from one build.
    if PIP_MODE {
        targets.append(appleBinary("ThorVGLib", "ThorVG_lib.xcframework"))
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
            ],
            swiftSettings: ANDROID_USE_AHARDWAREBUFFER ? [.define("NUCLEANT_ANDROID_USE_AHARDWAREBUFFER")] : []
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
