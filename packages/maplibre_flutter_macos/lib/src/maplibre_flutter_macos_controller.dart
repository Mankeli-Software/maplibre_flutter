import 'dart:async';

import 'package:flutter/services.dart';
import 'package:maplibre_flutter_core/maplibre_flutter_core.dart' as core;
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// Bootstrap channel for the texture registrar.
///
/// The one sanctioned platform-channel use (CLAUDE.md §3/§10): the engine's
/// texture registrar is only reachable from the native plugin, so Dart hands it
/// the core map's native handle to bind a `Texture` to. Registration only — the
/// per-frame data path is native + FFI (the core's render thread → the texture's
/// `copyPixelBuffer`), never this channel.
const MethodChannel _registrar = MethodChannel(
  'maplibre_flutter/macos/registrar',
);

/// Controller for a map composited through a Flutter `Texture` (desktop tier).
///
/// macOS drives `mbgl-core` over FFI (via `maplibre_flutter_core`): the core
/// renders off-screen on its own thread into a BGRA buffer; the native plugin's
/// `MapLibreTexture` copies that into a `CVPixelBuffer` for the `Texture`. This
/// controller creates the core map, registers the texture, and forwards
/// camera/style. (CLAUDE.md §8 M2.)
class MapLibreFlutterMacosController implements MapLibreMapController {
  MapLibreFlutterMacosController._(this._coreMap, this._textureId);

  final core.MapLibreCoreMap _coreMap;
  final int _textureId;

  bool _disposed = false;
  final Completer<void> _ready = Completer<void>();

  // Off-screen render size in device pixels. Fixed for M2; M3/M4 resize it to
  // the widget's real size × devicePixelRatio.
  static const int _renderWidth = 1024;
  static const int _renderHeight = 1024;

  /// Creates the core map, registers an engine texture bound to it, and returns
  /// a controller whose [renderHandle] is ready to embed.
  static Future<MapLibreFlutterMacosController> create(
    MapOptions options,
  ) async {
    final camera = options.initialCamera;
    final coreMap = core.MapLibreCoreMap.create(
      width: _renderWidth,
      height: _renderHeight,
      pixelRatio: 1,
      styleUri: options.styleUri,
    );
    coreMap.setCamera(
      latitude: camera.center.latitude,
      longitude: camera.center.longitude,
      zoom: camera.zoom,
      bearing: camera.bearing,
      pitch: camera.pitch,
    );

    final textureId = await _registrar
        .invokeMethod<int>('registerTexture', <String, Object?>{
          'mapHandle': coreMap.nativeAddress,
          'copyFrameFn': core.MapLibreCoreMap.copyFrameFunctionAddress,
          'setFrameCallbackFn':
              core.MapLibreCoreMap.setFrameCallbackFunctionAddress,
          'width': _renderWidth,
          'height': _renderHeight,
        });

    final controller = MapLibreFlutterMacosController._(
      coreMap,
      textureId ?? -1,
    );
    // M3 will gate readiness on the first rendered frame; for M2 the map exists
    // and the texture is wired, so report ready immediately.
    controller._ready.complete();
    return controller;
  }

  @override
  MapLibreRenderHandle get renderHandle => TextureHandle(textureId: _textureId);

  @override
  Future<void> get onReady => _ready.future;

  @override
  Future<MapCamera> getCamera() async {
    final c = _coreMap.getCamera();
    return MapCamera(
      center: LatLng(c.latitude, c.longitude),
      zoom: c.zoom,
      bearing: c.bearing,
      pitch: c.pitch,
    );
  }

  @override
  Future<void> moveCamera(MapCamera camera, {Duration? duration}) async {
    _coreMap.setCamera(
      latitude: camera.center.latitude,
      longitude: camera.center.longitude,
      zoom: camera.zoom,
      bearing: camera.bearing,
      pitch: camera.pitch,
    );
  }

  @override
  Future<void> setStyle(String styleUri) async => _coreMap.setStyle(styleUri);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Unregister first (clears the native frame callback and stops the engine
    // pulling frames), then destroy the core map (joins its render thread).
    await _registrar.invokeMethod<void>('unregisterTexture', _textureId);
    _coreMap.dispose();
  }
}
