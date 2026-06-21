import CoreLocation
import Flutter
import MapLibre
import UIKit

/// A single embedded MapLibre map (milestone A: render; milestone B wires the
/// controller below).
///
/// `MLNMapView` renders and handles gestures itself, so milestone A just builds
/// it, points it at the style, and sets the initial camera from `creationParams`.
class MapLibrePlatformView: NSObject, FlutterPlatformView {
  private let mapView: MLNMapView
  private let mapId: Int
  // Strong ref: the controller holds the backend weakly (CLAUDE.md §5d analogue).
  private var backend: MapLibreMapBackend?

  init(frame: CGRect, args: Any?) {
    let params = args as? [String: Any] ?? [:]
    // NSNumber-bridged reads so an int-valued field (e.g. zoom: 0) still decodes
    // — parity with Android's `as? Number` robustness.
    mapId = (params["mapId"] as? NSNumber)?.intValue ?? -1

    let styleUri =
      (params["styleUri"] as? String) ?? "https://demotiles.maplibre.org/style.json"
    let lat = (params["lat"] as? NSNumber)?.doubleValue ?? 0
    let lng = (params["lng"] as? NSNumber)?.doubleValue ?? 0
    let zoom = (params["zoom"] as? NSNumber)?.doubleValue ?? 0
    let bearing = (params["bearing"] as? NSNumber)?.doubleValue ?? 0
    let pitch = (params["pitch"] as? NSNumber)?.doubleValue ?? 0

    mapView = MLNMapView(frame: frame, styleURL: URL(string: styleUri))
    mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    super.init()

    mapView.setCenter(
      CLLocationCoordinate2D(latitude: lat, longitude: lng),
      zoomLevel: zoom,
      direction: bearing,
      animated: false
    )
    // setCenter has no pitch parameter, so apply it via the camera (parity with
    // Android's initial `.tilt(pitch)`).
    if pitch > 0 {
      let cam = mapView.camera
      cam.pitch = CGFloat(pitch)
      mapView.setCamera(cam, animated: false)
    }

    // Milestone B: register a controller for this map so Dart can drive it.
    if mapId >= 0 {
      let controller = MapRegistry.register(mapId)
      backend = MapLibreMapBackend(mapView: mapView, controller: controller)
    }
  }

  func view() -> UIView {
    mapView
  }

  deinit {
    if mapId >= 0 {
      MapRegistry.unregister(mapId)
    }
  }
}
