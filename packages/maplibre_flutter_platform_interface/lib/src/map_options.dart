import 'package:flutter/foundation.dart';

import 'camera.dart';

/// Initial configuration handed to a platform when a map is created.
@immutable
class MapOptions {
  const MapOptions({required this.styleUri, required this.initialCamera});

  /// MapLibre style document: a URL, asset path, or inline JSON.
  final String styleUri;

  /// Camera the map starts at before any user interaction.
  final MapCamera initialCamera;

  @override
  bool operator ==(Object other) =>
      other is MapOptions &&
      other.styleUri == styleUri &&
      other.initialCamera == initialCamera;

  @override
  int get hashCode => Object.hash(styleUri, initialCamera);
}
