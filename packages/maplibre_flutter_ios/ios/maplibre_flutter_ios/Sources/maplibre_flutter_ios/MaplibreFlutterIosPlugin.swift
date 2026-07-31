import Flutter
import UIKit

/// Native half of the hybrid iOS plugin (the default mbgl-core renderer).
///
/// Installs a bootstrap method channel (`maplibre_flutter/ios/registrar`) that
/// binds an engine `Texture` to an mbgl-core map — the macOS desktop tier ported
/// to iOS. Registration only (CLAUDE.md §10); the per-frame data path is FFI to
/// maplibre_flutter_core (the core's render thread → the texture's
/// `copyPixelBuffer`).
///
/// (The opt-in `maplibre_flutter_ios_sdk` package provides the alternative
/// `UiKitView` factory that renders with the MapLibre Apple SDK's `MLNMapView`.)
public class MaplibreFlutterIosPlugin: NSObject, FlutterPlugin {
  /// Bootstrap channel for the core texture registrar
  /// (mirrors macOS's `maplibre_flutter/macos/registrar`).
  static let registrarChannelName = "maplibre_flutter/ios/registrar"

  private let textures: FlutterTextureRegistry
  private var registered: [Int64: MapLibreCoreTexture] = [:]

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    // The texture-registrar bootstrap channel. NOTE: on iOS `messenger`/`textures`
    // are METHODS (they are properties on macOS).
    let channel = FlutterMethodChannel(
      name: registrarChannelName, binaryMessenger: registrar.messenger())
    let instance = MaplibreFlutterIosPlugin(textures: registrar.textures())
    registrar.addMethodCallDelegate(instance, channel: channel)
    // Required for detachFromEngine to be delivered at all: FlutterPlugin.h is
    // explicit that "you will only receive this method if you registered your
    // plugin instance with the FlutterEngine via -[FlutterPluginRegistry
    // publish:]". addMethodCallDelegate alone is not enough.
    registrar.publish(instance)
  }

  /// Releases any texture still registered when the engine goes away.
  ///
  /// Normally the Dart controller's `dispose()` sends `unregisterTexture` and
  /// this finds nothing to do. It matters when the engine is torn down without
  /// that happening — an add-to-app host dropping a FlutterEngine, say — where
  /// each surviving entry holds a live mbgl-core map AND its render thread.
  ///
  /// SCOPE, so this is not mistaken for more than it is: iOS is the only Apple
  /// tier where this hook exists at all. FlutterMacOS's plugin protocol has no
  /// detach callback (checked against the framework headers), so macOS has no
  /// equivalent and the Dart dispose path is its only teardown. Neither
  /// platform is notified of a hot restart, so neither this nor anything else
  /// at the plugin layer addresses that case.
  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    for texture in registered.values {
      // Clears the core's frame callback before dropping the registration, so
      // the render thread cannot call back into a texture that is going away.
      texture.unregister()
    }
    registered.removeAll()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "registerTexture":
      let args = call.arguments as? [String: Any]
      guard let handleValue = (args?["mapHandle"] as? NSNumber)?.int64Value,
        let mapHandle = UnsafeMutableRawPointer(bitPattern: Int(handleValue)),
        let copyFrameAddr = (args?["copyFrameFn"] as? NSNumber)?.int64Value,
        let setCallbackAddr = (args?["setFrameCallbackFn"] as? NSNumber)?
          .int64Value,
        copyFrameAddr != 0, setCallbackAddr != 0
      else {
        result(
          FlutterError(
            code: "bad_args",
            message: "registerTexture requires mapHandle + function addresses",
            details: nil))
        return
      }
      // Optional: the zero-copy IOSurface accessor. Absent/0 → CPU readback only.
      let iosurfaceAddr =
        (args?["currentIOSurfaceFn"] as? NSNumber)?.int64Value ?? 0
      let texture = MapLibreCoreTexture(
        mapHandle: mapHandle, copyFrameAddress: Int(copyFrameAddr),
        setFrameCallbackAddress: Int(setCallbackAddr),
        currentIOSurfaceAddress: Int(iosurfaceAddr), registry: textures)
      let textureId = texture.register()
      registered[textureId] = texture
      result(NSNumber(value: textureId))

    case "unregisterTexture":
      if let textureId = (call.arguments as? NSNumber)?.int64Value,
        let texture = registered.removeValue(forKey: textureId)
      {
        texture.unregister()
      }
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
