import Flutter
import UIKit

/// Native half of the hybrid iOS plugin.
///
/// Registers BOTH map paths so the Dart `MAPLIBRE_EXPERIMENTAL_CORE` flag can pick
/// either at runtime (CLAUDE.md §3):
///   - DEFAULT (SDK): the `UiKitView` factory that renders with the MapLibre Apple
///     SDK's `MLNMapView`. Camera/style is driven from Dart over swiftgen.
///   - EXPERIMENTAL (core): a bootstrap method channel (`maplibre_flutter/ios/registrar`)
///     that binds an engine `Texture` to an mbgl-core map — the macOS desktop tier
///     ported to iOS. Registration only (CLAUDE.md §10); the per-frame data path is FFI
///     to maplibre_flutter_core. The channel is inert unless the Dart core controller
///     calls it, so the default SDK build pays nothing for it.
public class MaplibreFlutterIosPlugin: NSObject, FlutterPlugin {
  /// Platform-view type the SDK Dart controller reports.
  static let viewType = "maplibre_flutter/ios"
  /// Bootstrap channel for the experimental core path's texture registrar
  /// (mirrors macOS's `maplibre_flutter/macos/registrar`).
  static let registrarChannelName = "maplibre_flutter/ios/registrar"

  private let textures: FlutterTextureRegistry
  private var registered: [Int64: MapLibreCoreTexture] = [:]

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    // Default SDK path: the UiKitView factory (MLNMapView).
    let factory = MapLibreViewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: viewType)

    // Experimental core path: the texture-registrar bootstrap channel. NOTE: on iOS
    // `messenger`/`textures` are METHODS (they are properties on macOS).
    let channel = FlutterMethodChannel(
      name: registrarChannelName, binaryMessenger: registrar.messenger())
    let instance = MaplibreFlutterIosPlugin(textures: registrar.textures())
    registrar.addMethodCallDelegate(instance, channel: channel)
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
