// swift-tools-version: 5.9
// The default iOS implementation of maplibre_flutter (CLAUDE.md §9: SPM + CocoaPods
// both). Renders the shared mbgl-core engine via Metal into a Flutter Texture; it
// does NOT link the MapLibre Apple SDK (so there is no mbgl symbol duplication —
// the native engine ships via maplibre_flutter_core's build hook).
import PackageDescription

let package = Package(
    name: "maplibre_flutter_ios",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "maplibre-flutter-ios", targets: ["maplibre_flutter_ios"]),
    ],
    dependencies: [
        // Flutter SDK package, injected by the tool (new in Flutter 3.41).
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "maplibre_flutter_ios",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ]
        ),
    ]
)
