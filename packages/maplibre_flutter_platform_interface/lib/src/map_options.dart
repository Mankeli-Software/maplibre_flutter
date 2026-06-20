import 'package:flutter/foundation.dart';

import 'camera.dart';
import 'lat_lng.dart';

/// Init-only configuration handed to a platform when a map is created.
///
/// Holds only one-time creation state. The map's *style* is **not** here — it is
/// a declarative property of the `MapLibreMap` widget (change it to switch styles
/// at runtime). Runtime camera moves go through the controller, not this. (See
/// the three-bucket API split in CLAUDE.md §3.)
@immutable
class MapOptions {
  const MapOptions({
    this.initialCamera = const MapCamera(center: LatLng(0, 0)),
  });

  /// Camera the map starts at before any user interaction. Init-only; use the
  /// controller's camera methods to move afterwards.
  final MapCamera initialCamera;

  @override
  bool operator ==(Object other) =>
      other is MapOptions && other.initialCamera == initialCamera;

  @override
  int get hashCode => initialCamera.hashCode;
}
