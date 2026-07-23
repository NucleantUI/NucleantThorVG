// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let devMode = false
let branch = "refactor"

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
        .target(
            name: "CThorVG",
            dependencies: ["ThorVG"],
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
        .iOS(.v15),
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
