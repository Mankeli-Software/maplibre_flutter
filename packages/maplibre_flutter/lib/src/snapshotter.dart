import 'dart:async';
import 'dart:ui' as ui;

import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// Renders a map to an image WITHOUT one on screen — Apple `MLNMapSnapshotter`.
///
/// For thumbnails, share cards, printed output, an offline preview — anywhere
/// you want a picture of a place rather than an interactive map.
///
/// ```dart
/// final image = await MapLibreSnapshotter.takeImage(
///   const MapSnapshotOptions(
///     style: 'https://demotiles.maplibre.org/style.json',
///     camera: MapCamera(center: LatLng(60.45, 22.27), zoom: 11),
///     size: Size(600, 400),
///   ),
/// );
/// ```
///
/// It renders in **Static** mode, which blocks until every tile for the frame
/// has loaded — so it is slower than a frame of the live map, on purpose. A
/// Continuous render would return whatever had arrived, and a snapshot missing
/// its tiles is worse than none.
abstract final class MapLibreSnapshotter {
  /// Renders and returns the raw pixels, or null if the renderer cannot do it
  /// or the tiles did not arrive inside `options.timeout`.
  ///
  /// Deliberately not an exception: a snapshot is best-effort, and a caller
  /// that wanted a picture is better served by "no picture" than by an error
  /// thrown out of a background render.
  static Future<MapSnapshot?> take(MapSnapshotOptions options) =>
      MapLibreFlutterPlatform.instance.takeSnapshot(options);

  /// The same, decoded into a [ui.Image] ready to draw or encode.
  static Future<ui.Image?> takeImage(MapSnapshotOptions options) async {
    final snapshot = await take(options);
    if (snapshot == null) return null;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      snapshot.pixels,
      snapshot.width,
      snapshot.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}
