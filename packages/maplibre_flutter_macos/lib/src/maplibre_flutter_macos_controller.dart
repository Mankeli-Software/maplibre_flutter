import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:maplibre_flutter_core/maplibre_flutter_core.dart' as core;
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// Bootstrap channel for the texture registrar.
///
/// The one sanctioned platform-channel use (CLAUDE.md §3/§10): the engine's
/// texture registrar is only reachable from the native plugin, so Dart hands it
/// the core map's native handle (and the core's resolved function addresses) to
/// bind a `Texture` to. Registration only — the per-frame data path is native +
/// FFI (the core's render thread → the texture's `copyPixelBuffer`).
const MethodChannel _registrar = MethodChannel(
  'maplibre_flutter/macos/registrar',
);

/// Controller for a map composited through a Flutter `Texture` (desktop tier).
///
/// macOS drives `mbgl-core` over FFI (via `maplibre_flutter_core`): the core
/// renders off-screen on its own thread into a BGRA buffer; the native plugin's
/// `MapLibreTexture` copies that into a `CVPixelBuffer` for the `Texture`. This
/// controller creates the core map, registers the texture, forwards
/// camera/style, and resizes the off-screen surface to the widget. (§8 M2–M3.)
class MapLibreFlutterMacosController
    implements MapLibreMapPlatformController, MapLibreGestureHandler {
  MapLibreFlutterMacosController._(this._coreMap, this._textureId) {
    _pollReady();
  }

  final core.MapLibreCoreMap _coreMap;
  final int _textureId;

  bool _disposed = false;
  // Bumped to supersede a running fly-to animation (a new move or a gesture).
  int _animToken = 0;
  final Completer<void> _ready = Completer<void>();

  // Initial off-screen size in LOGICAL points; replaced once the widget reports
  // its real size via [resize]. The texture self-sizes to whatever the core
  // renders, so this is only the size of the very first frame(s).
  static const int _initialWidth = 512;
  static const int _initialHeight = 512;
  int _renderWidth = _initialWidth;
  int _renderHeight = _initialHeight;

  /// Creates the core map, registers an engine texture bound to it, and returns
  /// a controller. [onReady] completes once the first frame has rendered.
  static Future<MapLibreFlutterMacosController> create(
    String style,
    MapOptions options,
  ) async {
    final camera = options.initialCamera;
    // Render at the display's real pixel ratio (like a native map view), NOT 1. The
    // core's framebuffer is mbgl `Size * pixelRatio`, so passing logical points as the
    // size + the real DPR makes mbgl lay out tiles/lines on the device pixel grid; the
    // device-pixel texture then composites 1:1 with no resampling (pr=1 rendered a 1x
    // map blown up — more area, tiny labels, tile edges on fractional device pixels).
    final dpr =
        ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1.0;
    final coreMap = core.MapLibreCoreMap.create(
      width: _initialWidth,
      height: _initialHeight,
      pixelRatio: dpr,
      styleUri: style,
      // Continuous render (partial frames that refine as tiles load) is on by
      // default; --dart-define=MAPLIBRE_CONTINUOUS=false uses the blocking
      // Static path for an A/B.
      continuous: const bool.fromEnvironment(
        'MAPLIBRE_CONTINUOUS',
        defaultValue: true,
      ),
    );
    // Zero-copy present (GPU blit into an IOSurface) is on by default; flip it
    // off for an A/B against the CPU-readback path with
    // `--dart-define=MAPLIBRE_ZEROCOPY=false`.
    coreMap.setZeroCopy(
      const bool.fromEnvironment('MAPLIBRE_ZEROCOPY', defaultValue: true),
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
          'currentIOSurfaceFn':
              core.MapLibreCoreMap.currentIOSurfaceFunctionAddress,
        });

    return MapLibreFlutterMacosController._(coreMap, textureId ?? -1);
  }

  /// Polls until the first frame has rendered, then completes [onReady] (mirrors
  /// the mobile controllers' readiness handshake). Stops on dispose.
  void _pollReady() {
    if (_disposed || _ready.isCompleted) return;
    if (_coreMap.awaitFrame(Duration.zero)) {
      _ready.complete();
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 50), _pollReady);
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
    final token = ++_animToken; // supersede any running animation
    final ms = duration?.inMilliseconds ?? 0;
    if (_disposed || ms <= 0) {
      _applyCamera(camera);
      return;
    }
    // Desktop has no usable native flyTo, so step an eased arc and render each
    // frame on the working (complete-frame) Static path. ~30fps; the core's
    // render thread paces the actual frames.
    final start = await getCamera();
    if (_disposed || token != _animToken) return;
    const frameMs = 33;
    final steps = math.max(1, (ms / frameMs).round());
    for (var i = 1; i <= steps; i++) {
      if (_disposed || token != _animToken) return;
      _applyCamera(flyCameraAt(start, camera, i / steps));
      await Future<void>.delayed(const Duration(milliseconds: frameMs));
    }
    if (!_disposed && token == _animToken) _applyCamera(camera);
  }

  void _applyCamera(MapCamera camera) {
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
  Future<void> resize(Size size, double devicePixelRatio) async {
    if (_disposed) return;
    // Pass LOGICAL points as mbgl's size; the core multiplies by the pixelRatio set
    // at create to produce the device-pixel texture. (devicePixelRatio is unused
    // here — the core already knows the density.)
    final w = size.width.round();
    final h = size.height.round();
    if (w <= 0 || h <= 0 || (w == _renderWidth && h == _renderHeight)) return;
    _renderWidth = w;
    _renderHeight = h;
    _coreMap.resize(w, h);
  }

  @override
  void moveBy(double dx, double dy) {
    if (_disposed) return;
    _animToken++; // a gesture supersedes any running fly-to
    // mbgl's screen coordinates are logical points (Size = logical points),
    // matching the widget's gesture deltas — no DPR scaling.
    _coreMap.moveBy(dx, dy);
  }

  @override
  void scaleBy(double scale, double anchorX, double anchorY) {
    if (_disposed) return;
    _animToken++; // a gesture supersedes any running fly-to
    _coreMap.scaleBy(scale, anchorX, anchorY);
  }

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
