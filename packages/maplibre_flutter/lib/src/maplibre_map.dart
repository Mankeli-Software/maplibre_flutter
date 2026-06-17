import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// Signature for [MapLibreMap.onMapCreated].
typedef MapCreatedCallback = void Function(MapLibreMapController controller);

/// The public map widget.
///
/// Renders a MapLibre map natively on every platform. Internally it asks the
/// registered [MapLibreFlutterPlatform] to create a map, then embeds the result
/// based on its [MapLibreRenderHandle]: a platform view on mobile/web or a
/// [Texture] on desktop. The branch is an implementation detail — callers see
/// one widget and one [MapLibreMapController].
class MapLibreMap extends StatefulWidget {
  const MapLibreMap({super.key, required this.options, this.onMapCreated});

  /// Initial style and camera.
  final MapOptions options;

  /// Called as soon as the [MapLibreMapController] exists — which is *before*
  /// the native map has finished initialising. Await
  /// [MapLibreMapController.onReady] before driving the camera or style.
  final MapCreatedCallback? onMapCreated;

  @override
  State<MapLibreMap> createState() => _MapLibreMapState();
}

class _MapLibreMapState extends State<MapLibreMap> {
  Future<MapLibreMapController>? _creation;

  @override
  void initState() {
    super.initState();
    _creation = _create();
  }

  Future<MapLibreMapController> _create() async {
    final controller = await MapLibreFlutterPlatform.instance.createMap(
      widget.options,
    );
    widget.onMapCreated?.call(controller);
    return controller;
  }

  @override
  void dispose() {
    _creation?.then((c) => c.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<MapLibreMapController>(
      future: _creation,
      builder: (context, snapshot) {
        final controller = snapshot.data;
        if (controller == null) {
          return const SizedBox.shrink();
        }
        return _embed(context, controller);
      },
    );
  }

  /// The render split (CLAUDE.md §3) is resolved here and nowhere else.
  Widget _embed(BuildContext context, MapLibreMapController controller) {
    final handle = controller.renderHandle;
    switch (handle) {
      case TextureHandle(:final textureId):
        // Desktop tier: report the view's size + DPR so the core renders at the
        // right resolution and aspect ratio (and follows window resizes).
        // `resize` is idempotent, so reporting on every layout is cheap.
        return LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final dpr = MediaQuery.devicePixelRatioOf(context);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (size.isFinite && !size.isEmpty) {
                controller.resize(size, dpr);
              }
            });
            return Texture(textureId: textureId);
          },
        );
      case PlatformViewHandle():
        return _platformView(handle);
      case ElementViewHandle(:final viewType):
        return _UnimplementedEmbed(label: 'element view "$viewType"');
    }
  }

  /// Embed a native view. The mobile tier reaches here: Android composites the
  /// map's `SurfaceView` via Hybrid Composition, iOS embeds `MLNMapView` via
  /// `UiKitView`. The concrete view factory is registered by each platform
  /// package.
  Widget _platformView(PlatformViewHandle handle) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return _androidView(handle);
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: handle.viewType,
          creationParams: handle.creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        );
      default:
        return _UnimplementedEmbed(
          label: 'platform view "${handle.viewType}" on $defaultTargetPlatform',
        );
    }
  }

  /// Android embed via **Hybrid Composition** (`PlatformViewLink` +
  /// `PlatformViewsService.initSurfaceAndroidView`), so the map's `SurfaceView`
  /// composites directly in the view hierarchy with correct gestures and
  /// accessibility — unlike the plain `AndroidView` (texture-layer) path, which
  /// shunts SurfaceViews into a virtual display. On capable devices (Flutter
  /// 3.44+, Android API 34+, Vulkan) this is transparently upgraded to Hybrid
  /// Composition Plus (HCPP) when the app manifest sets
  /// `io.flutter.embedding.android.EnableHcpp`; otherwise it falls back to
  /// classic Hybrid Composition.
  Widget _androidView(PlatformViewHandle handle) {
    return PlatformViewLink(
      viewType: handle.viewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        );
      },
      onCreatePlatformView: (params) {
        return PlatformViewsService.initSurfaceAndroidView(
            id: params.id,
            viewType: handle.viewType,
            layoutDirection: TextDirection.ltr,
            creationParams: handle.creationParams,
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
      },
    );
  }
}

class _UnimplementedEmbed extends StatelessWidget {
  const _UnimplementedEmbed({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    assert(() {
      debugPrint('MapLibreMap: embedding for $label not wired yet.');
      return true;
    }());
    return const SizedBox.shrink();
  }
}
