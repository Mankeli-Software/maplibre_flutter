/// Native MapLibre vector maps for Flutter on every platform.
///
/// App code depends only on this package. It re-exports the render-agnostic
/// types from the platform interface and provides the [MapLibreMap] widget.
library;

export 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart'
    show LatLng, MapCamera, MapOptions;

export 'src/maplibre_map.dart';
export 'src/maplibre_map_controller.dart';
