import 'dart:math' as math;

import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// The camera along an eased fly-to arc at progress [t] in `[0, 1]`.
///
/// The desktop tier renders complete frames on demand (the headless core has no
/// usable Continuous/native flyTo), so the desktop controller animates
/// `moveCamera(duration:)` by stepping this curve and rendering each step. The
/// zoom dips toward a "fit" level mid-flight — a simplified van-Wijk arc — so a
/// long flight passes through cheap low-zoom tiles (a world/continental view)
/// instead of fetching high-zoom tiles across the whole path.
MapCamera flyCameraAt(MapCamera start, MapCamera target, double t) {
  final clamped = t.clamp(0.0, 1.0);
  final e = clamped * clamped * (3 - 2 * clamped); // smoothstep ease

  final lat = _lerp(start.center.latitude, target.center.latitude, e);
  final lng =
      start.center.longitude +
      _shortestDelta(start.center.longitude, target.center.longitude) * e;

  // Dip the zoom toward a level that fits both endpoints, so the mid-flight view
  // is zoomed out (cheap, mostly-cached tiles). `peak` is the lowest zoom on the
  // arc; `dip` is how far below the straight zoom interpolation we pull at t=0.5.
  final fit = _fitZoom(start.center, target.center);
  final peak = math.min(math.min(start.zoom, target.zoom), fit);
  final dip = math.max(0.0, (start.zoom + target.zoom) / 2 - peak);
  final zoom =
      _lerp(start.zoom, target.zoom, e) - dip * math.sin(math.pi * clamped);

  return MapCamera(
    center: LatLng(lat, lng),
    zoom: zoom,
    bearing: start.bearing + _shortestDelta(start.bearing, target.bearing) * e,
    pitch: _lerp(start.pitch, target.pitch, e),
  );
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// Shortest signed delta from [from] to [to] on a 360° circle (handles the
/// antimeridian / bearing wrap), in `(-180, 180]`.
double _shortestDelta(double from, double to) {
  var d = (to - from) % 360.0;
  if (d > 180) d -= 360;
  if (d < -180) d += 360;
  return d;
}

/// A zoom level at which the span between [a] and [b] roughly fits the viewport
/// (≈ world at zoom 0; each halving of the span adds ~one zoom level).
double _fitZoom(LatLng a, LatLng b) {
  final dLng = _shortestDelta(a.longitude, b.longitude).abs();
  final dLat = (a.latitude - b.latitude).abs();
  final span = math.max(dLng, dLat * 2).clamp(1e-6, 360.0);
  return (math.log(360 / span) / math.ln2).clamp(0.0, 22.0);
}
