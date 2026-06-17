import Foundation

/// Backend the controller forwards camera/style commands to.
///
/// Internal + **no MapLibre import** on purpose: swiftgen *compiles* its input
/// files, so anything it binds must build against the bare SDK. The concrete
/// implementation that actually touches `MLNMapView` lives in
/// `MapLibreMapBackend.swift` (not a swiftgen input) and is wired in at runtime.
protocol MapLibreMapOps: AnyObject {
  func moveCamera(
    lat: Double, lng: Double, zoom: Double, bearing: Double, pitch: Double, durationMs: Int)
  func setStyle(_ uri: String)
}

/// Thin, swiftgen-bound controller for one live map (CLAUDE.md §5b/§5d).
///
/// Dart calls the `@objc public` primitive surface over the Objective-C runtime;
/// commands forward to the MapLibre-backed [ops]. The camera is cached (written
/// by the backend from the map's delegate) so the getters are a plain read. The
/// surface is primitives + `String` only, so swiftgen never sees an `MLN*` type.
// Plain @objc (no explicit name): the default ObjC runtime name is
// module-qualified `maplibre_flutter_ios.MapLibreController`, which is exactly
// what the generated bindings look up via objc.getClass. An explicit
// @objc(MapLibreController) would unqualify it and break the lookup.
@objc public class MapLibreController: NSObject {
  /// Set by the backend; weak so the view owns the retain cycle, not us.
  weak var ops: MapLibreMapOps?

  // Cached camera, written by the backend on the main thread, read from Dart.
  @objc public var lat: Double = 0
  @objc public var lng: Double = 0
  @objc public var zoom: Double = 0
  @objc public var bearing: Double = 0
  @objc public var pitch: Double = 0
  @objc public var isReady: Bool = false

  @objc public func moveCamera(
    lat: Double, lng: Double, zoom: Double, bearing: Double, pitch: Double, durationMs: Int
  ) {
    ops?.moveCamera(
      lat: lat, lng: lng, zoom: zoom, bearing: bearing, pitch: pitch, durationMs: durationMs)
  }

  @objc public func setStyle(_ uri: String) {
    ops?.setStyle(uri)
  }
}
