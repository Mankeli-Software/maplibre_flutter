// swift-tools-version: 5.9
// The iOS implementation of maplibre_flutter (CLAUDE.md §9: SPM + CocoaPods both).
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
        // MapLibre Apple SDK (MLNMapView). Same distribution CocoaPods uses.
        .package(
            url: "https://github.com/maplibre/maplibre-gl-native-distribution",
            from: "6.27.0"
        ),
    ],
    targets: [
        .target(
            name: "maplibre_flutter_ios",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "MapLibre", package: "maplibre-gl-native-distribution"),
            ]
        ),
    ]
)
