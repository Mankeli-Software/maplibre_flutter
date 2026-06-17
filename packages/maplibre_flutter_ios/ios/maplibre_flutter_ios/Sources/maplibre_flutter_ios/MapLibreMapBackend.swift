import CoreLocation
import MapLibre
import UIKit

/// MapLibre-backed implementation of `MapLibreController`'s commands.
///
/// **Not** a swiftgen input (it imports MapLibre): swiftgen compiles its inputs
/// against the bare SDK, so all `MLN*` usage is quarantined here. UIKit is
/// main-thread only, so commands hop onto the main queue; the camera is cached
/// back into the controller from the map delegate for cheap getter reads.
final class MapLibreMapBackend: NSObject, MapLibreMapOps, MLNMapViewDelegate {
  private weak var mapView: MLNMapView?
  private let controller: MapLibreController

  init(mapView: MLNMapView, controller: MapLibreController) {
    self.mapView = mapView
    self.controller = controller
    super.init()
    mapView.delegate = self
    controller.ops = self
    cacheCamera(mapView)
  }

  // MARK: MapLibreMapOps

  func moveCamera(
    lat: Double, lng: Double, zoom: Double, bearing: Double, pitch: Double, durationMs: Int
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let mapView = self?.mapView else { return }
      let center = CLLocationCoordinate2D(latitude: lat, longitude: lng)
      let altitude = MLNAltitudeForZoomLevel(zoom, pitch, lat, mapView.frame.size)
      let camera = MLNMapCamera(
        lookingAtCenter: center, altitude: altitude, pitch: pitch, heading: bearing)
      if durationMs > 0 {
        // fly() does the parabolic zoom-out-then-in arc (matches Android's
        // animateCamera); setCamera(withDuration:) would move linearly instead.
        mapView.fly(
          to: camera,
          withDuration: Double(durationMs) / 1000.0,
          completionHandler: nil)
      } else {
        mapView.setCamera(camera, animated: false)
      }
    }
  }

  func setStyle(_ uri: String) {
    DispatchQueue.main.async { [weak self] in
      self?.mapView?.styleURL = URL(string: uri)
    }
  }

  // MARK: MLNMapViewDelegate

  func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
    controller.isReady = true
    cacheCamera(mapView)
  }

  func mapViewRegionIsChanging(_ mapView: MLNMapView) {
    cacheCamera(mapView)
  }

  func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
    cacheCamera(mapView)
  }

  private func cacheCamera(_ mapView: MLNMapView) {
    controller.lat = mapView.centerCoordinate.latitude
    controller.lng = mapView.centerCoordinate.longitude
    controller.zoom = mapView.zoomLevel
    controller.bearing = mapView.direction
    controller.pitch = mapView.camera.pitch
  }
}
