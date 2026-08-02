/// Native MapLibre vector maps for Flutter on every platform.
///
/// App code depends only on this package. It re-exports the render-agnostic
/// types from the platform interface and provides the [MapLibreMap] widget.
library;

export 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart'
    show
        CameraAnimation,
        CameraOptions,
        CameraTransition,
        MapCameraConstraints,
        LatLng,
        LatLngBounds,
        MapAttribution,
        MapSnapshot,
        MapSnapshotOptions,
        MapUserLocation,
        MapUserTrackingMode,
        AttributionLink,
        MapCamera,
        MapCameraChangeReason,
        MapCameraChangeReasons,
        MapLibreCapabilities,
        MapLibreModel,
        MapOptions,
        // The capability interfaces, so an app can feature-detect with `is`.
        // They are implemented by platform packages, never by apps — see
        // MapLibreCapabilities.
        MapLibreCameraCommands,
        MapLibreGestureHandler,
        MapLibreMapProjector,
        MapLibreModelHost,
        MapLibreRotateHandler,
        MapLibreStyleLayers;

export 'geojson.dart';
export 'src/a11y/formatters.dart';
export 'src/a11y/locale.dart';
export 'src/attribution_bar.dart';
export 'src/map_style_controller.dart';
export 'src/maplibre_map.dart';
export 'src/settings.dart';
export 'src/snapshotter.dart';
export 'src/user_location_puck.dart';
export 'src/maplibre_map_controller.dart';
export 'src/marker.dart';
export 'src/style/style.dart';
