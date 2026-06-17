import Flutter
import UIKit

/// Native half of the hybrid iOS plugin.
///
/// Registers the `UiKitView` factory with the platform-view registrar — not a
/// data-path method channel (CLAUDE.md §10). Camera/style control is driven from
/// Dart over swiftgen (milestone B), not through this class.
public class MaplibreFlutterIosPlugin: NSObject, FlutterPlugin {
  /// View type that the Dart controller reports.
  static let viewType = "maplibre_flutter/ios"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let factory = MapLibreViewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: viewType)
  }
}
