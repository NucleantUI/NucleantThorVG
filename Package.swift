// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let devMode = false
let branch = "master"

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
    return [
        .binaryTarget(
            name: "ThorVG",
            path: "output/ThorVG.xcframework"
        ),
        // libomp (dynamic OpenMP) — iOS only. The iOS ThorVG.framework links
        // @rpath/libomp.framework/libomp, so it must be embedded; SPM does that
        // when CThorVG depends on this binary target. macOS's ThorVG statically
        // links libomp, so this xcframework carries iOS slices only and is only
        // depended on for iOS.
        .binaryTarget(
            name: "libomp",
            path: "output/libomp.xcframework"
        ),
        .target(
            name: "CThorVG",
            dependencies: [
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
        ),
    ]
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
