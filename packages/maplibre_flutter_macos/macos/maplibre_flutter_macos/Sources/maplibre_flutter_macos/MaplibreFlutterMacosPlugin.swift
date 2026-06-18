import FlutterMacOS
import Foundation

/// Native half of the hybrid macOS plugin.
///
/// Owns the Flutter texture registrar and exposes a bootstrap method channel to
/// register/unregister the engine texture a map renders into. This is the only
/// sanctioned platform-channel use (CLAUDE.md §3/§10) — registration, never the
/// per-frame data path (which is FFI to maplibre_flutter_core).
///
/// Registers a `MapLibreTexture` that bridges a core `MblMap*`'s frames into a
/// Flutter `Texture` (CLAUDE.md §8 M2). Dart creates the map over FFI and hands
/// its native handle here; the per-frame data path stays in native + FFI.
public class MaplibreFlutterMacosPlugin: NSObject, FlutterPlugin {
  static let channelName = "maplibre_flutter/macos/registrar"

  private let textures: FlutterTextureRegistry
  private var registered: [Int64: MapLibreTexture] = [:]

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    // NOTE: on macOS `messenger`/`textures` are properties (iOS uses methods).
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger)
    let instance = MaplibreFlutterMacosPlugin(textures: registrar.textures)
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
      let texture = MapLibreTexture(
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
