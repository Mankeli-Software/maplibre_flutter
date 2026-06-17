import Flutter
import UIKit

/// Builds a `MapLibrePlatformView` per `UiKitView`. The creation args are the
/// `creationParams` map the Dart controller serialises from `MapOptions`
/// (`mapId`, `styleUri`, camera), decoded via `FlutterStandardMessageCodec`.
class MapLibreViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    MapLibrePlatformView(frame: frame, args: args)
  }
}
