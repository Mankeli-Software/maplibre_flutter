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

  /// Called once the native map exists and its controller is ready.
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
        return _embed(controller.renderHandle);
      },
    );
  }

  /// The render split (CLAUDE.md §3) is resolved here and nowhere else.
  Widget _embed(MapLibreRenderHandle handle) {
    switch (handle) {
      case TextureHandle(:final textureId):
        return Texture(textureId: textureId);
      case PlatformViewHandle(:final viewType):
        // Each platform package registers the concrete view factory; the
        // mobile impls swap this for AndroidView / UiKitView once wired.
        return _UnimplementedEmbed(label: 'platform view "$viewType"');
      case ElementViewHandle(:final viewType):
        return _UnimplementedEmbed(label: 'element view "$viewType"');
    }
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
