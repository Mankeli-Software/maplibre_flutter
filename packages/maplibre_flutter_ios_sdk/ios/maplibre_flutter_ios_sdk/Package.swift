// swift-tools-version: 5.9
// The opt-in MapLibre Apple SDK implementation of maplibre_flutter (CLAUDE.md §9:
// SPM + CocoaPods both). The SPM target / pod name is the Swift module name, which
// MUST equal the package name so swiftgen's module-qualified @objc lookups resolve
// (CLAUDE.md §5b).
import PackageDescription

let package = Package(
    name: "maplibre_flutter_ios_sdk",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "maplibre-flutter-ios-sdk", targets: ["maplibre_flutter_ios_sdk"]),
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
            name: "maplibre_flutter_ios_sdk",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "MapLibre", package: "maplibre-gl-native-distribution"),
            ]
        ),
    ]
)
