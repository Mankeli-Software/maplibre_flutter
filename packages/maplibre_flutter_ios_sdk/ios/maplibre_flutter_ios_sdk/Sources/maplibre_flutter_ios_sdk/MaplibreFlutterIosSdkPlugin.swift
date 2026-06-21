import Flutter
import UIKit

/// Native half of the opt-in MapLibre Apple SDK plugin.
///
/// Registers the `UiKitView` factory that renders with the MapLibre Apple SDK's
/// `MLNMapView`. Camera/style is driven from Dart over swiftgen (CLAUDE.md §3/§5b);
/// there is no data-path method channel.
public class MaplibreFlutterIosSdkPlugin: NSObject, FlutterPlugin {
  /// Platform-view type the SDK Dart controller reports.
  static let viewType = "maplibre_flutter/ios"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let factory = MapLibreViewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: viewType)
  }
}
