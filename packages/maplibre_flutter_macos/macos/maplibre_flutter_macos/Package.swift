// swift-tools-version: 5.9
// The macOS implementation of maplibre_flutter (CLAUDE.md §9: SPM + CocoaPods both).
//
// macOS renders mbgl-core (via maplibre_flutter_core) off-screen into a Metal
// texture, so — unlike iOS — there is NO MapLibre Apple SDK dependency here, and
// sharedDarwinSource is deliberately not used (CLAUDE.md §3).
import PackageDescription

let package = Package(
    name: "maplibre_flutter_macos",
    platforms: [
        .macOS("10.15"),
    ],
    products: [
        .library(name: "maplibre-flutter-macos", targets: ["maplibre_flutter_macos"]),
    ],
    dependencies: [
        // Flutter SDK package, injected by the tool (new in Flutter 3.41).
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "maplibre_flutter_macos",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ]
        ),
    ]
)
