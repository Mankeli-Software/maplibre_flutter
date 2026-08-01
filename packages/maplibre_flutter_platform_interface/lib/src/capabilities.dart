import 'package:flutter/foundation.dart';

import 'gesture_handler.dart';
import 'maplibre_map_controller.dart';
import 'model_host.dart';
import 'projector.dart';
import 'rotate_handler.dart';
import 'style_layers.dart';

/// What the bound renderer can actually do.
///
/// No upstream has an analogue, and could not: gl-js and each native SDK ship
/// exactly one renderer, whereas this plugin is federated across eight tiers
/// with genuinely different ceilings — the web-WASM tier has no projector, no
/// style layers and no models today, while the five `mbgl-core` tiers have all
/// three. So this is a federated-plugin primitive, named for what it is.
///
/// Read it from `controller.capabilities`. It is derived in one place from the
/// same `is` checks the controller itself uses, which is the point: an app that
/// wants to hide a "tilt" button on a tier that cannot tilt should not have to
/// know that the check is `is MapLibreRotateHandler`.
///
/// The capability interfaces are exported too, so `if (controller is
/// MapLibreModelHost)` is available for the cases this object does not cover.
/// They exist to be **implemented by platform packages**, not by apps: they are
/// `abstract interface class`es, so adding a member is a deliberate,
/// all-tiers-at-once change (CLAUDE.md §3), and an app implementing one would
/// be broken by it.
@immutable
class MapLibreCapabilities {
  const MapLibreCapabilities({
    required this.projection,
    required this.styleLayers,
    required this.models,
    required this.rotateAndTilt,
    required this.gestures,
  });

  /// Everything off, for when no map is bound yet.
  const MapLibreCapabilities.none()
    : projection = false,
      styleLayers = false,
      models = false,
      rotateAndTilt = false,
      gestures = false;

  /// Derives the capabilities of [platform], which may be null before attach.
  factory MapLibreCapabilities.of(Object? platform) {
    if (platform is! MapLibreMapPlatformController) {
      return const MapLibreCapabilities.none();
    }
    return MapLibreCapabilities(
      projection: platform is MapLibreMapProjector,
      styleLayers: platform is MapLibreStyleLayers,
      models: platform is MapLibreModelHost,
      rotateAndTilt: platform is MapLibreRotateHandler,
      gestures: platform is MapLibreGestureHandler,
    );
  }

  /// Whether the tier can turn coordinates into screen points and back
  /// ([MapLibreMapProjector]). Widget markers need this — without it there is
  /// no marker overlay at all.
  final bool projection;

  /// Whether the tier can add engine sources, layers and images
  /// ([MapLibreStyleLayers]).
  final bool styleLayers;

  /// Whether the tier can draw 3D models ([MapLibreModelHost]).
  final bool models;

  /// Whether the tier can rotate and tilt the camera ([MapLibreRotateHandler]).
  final bool rotateAndTilt;

  /// Whether the tier takes gesture deltas from the Dart gesture layer
  /// ([MapLibreGestureHandler]). False on the platform-view tiers, which
  /// recognise their own gestures natively.
  final bool gestures;

  @override
  bool operator ==(Object other) =>
      other is MapLibreCapabilities &&
      other.projection == projection &&
      other.styleLayers == styleLayers &&
      other.models == models &&
      other.rotateAndTilt == rotateAndTilt &&
      other.gestures == gestures;

  @override
  int get hashCode =>
      Object.hash(projection, styleLayers, models, rotateAndTilt, gestures);

  @override
  String toString() =>
      'MapLibreCapabilities(projection: $projection, styleLayers: '
      '$styleLayers, models: $models, rotateAndTilt: $rotateAndTilt, '
      'gestures: $gestures)';
}
