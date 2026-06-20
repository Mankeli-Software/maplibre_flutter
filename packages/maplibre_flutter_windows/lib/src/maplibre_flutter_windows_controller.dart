import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_flutter_core/maplibre_flutter_core.dart' as core;
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// Bootstrap channel for the texture registrar (the one sanctioned platform-
/// channel use, CLAUDE.md §3/§10): Dart hands the native Windows plugin the core
/// map's handle + the core's resolved function addresses to bind a
/// `flutter::PixelBufferTexture` to. Registration only — the per-frame data path
/// is native + FFI (the core's render thread → the texture's copy callback).
const MethodChannel _registrar = MethodChannel(
  'maplibre_flutter/windows/registrar',
);

/// Controller for a map composited through a Flutter `Texture` on Windows.
///
/// Windows is part of the desktop tier (CLAUDE.md §3): it drives `mbgl-core` over
/// FFI (via `maplibre_flutter_core`, the **ANGLE / OpenGL ES + EGL** arm), which
/// renders off-screen on its own thread; the native Windows plugin's
/// `flutter::PixelBufferTexture` reads each RGBA frame (`mbl_map_copy_frame`) into
/// a Flutter `Texture`. Mirrors the Linux controller (same CPU pixel-buffer
/// present); zero-copy on Windows would use a D3D shared texture and is a later
/// step, so this v1 has only the CPU path.
///
/// NOTE: not yet run on real Windows hardware — see CLAUDE.md §8.
class MapLibreFlutterWindowsController
    implements
        MapLibreMapPlatformController,
        MapLibreGestureHandler,
        MapLibreTextureSizeProvider {
  MapLibreFlutterWindowsController._(this._coreMap, this._textureId) {
    _pollReady();
  }

  final core.MapLibreCoreMap _coreMap;
  final int _textureId;

  bool _disposed = false;
  // Bumped to supersede a running fly-to animation (a new move or a gesture).
  int _animToken = 0;
  final Completer<void> _ready = Completer<void>();

  static const int _initialWidth = 512;
  static const int _initialHeight = 512;
  int _renderWidth = _initialWidth;
  int _renderHeight = _initialHeight;

  // The texture's currently-produced frame size (device px; only the aspect is
  // used). It lags [resize] on the CPU-readback present, so the widget cover-fits
  // a stale frame to the new window box instead of stretching it. Polled after
  // each resize until the produced size catches up (or a short safety cap).
  final ValueNotifier<Size> _textureSize = ValueNotifier<Size>(
    Size(_initialWidth.toDouble(), _initialHeight.toDouble()),
  );
  Timer? _sizePoll;
  // Drag-resize debounce: while the window is actively being dragged we hold the
  // core at its current size (so the produced frame stays frozen and the widget
  // can cover-fit it without stretching), and apply the real resize only once the
  // drag settles. _firstResizeApplied makes the initial sizing immediate.
  Timer? _resizeDebounce;
  bool _firstResizeApplied = false;

  /// Creates the core map, registers an engine texture bound to it, and returns
  /// a controller. [onReady] completes once the first frame has rendered.
  static Future<MapLibreFlutterWindowsController> create(
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
      // default; --dart-define=MAPLIBRE_CONTINUOUS=false uses the Static path.
      continuous: const bool.fromEnvironment(
        'MAPLIBRE_CONTINUOUS',
        defaultValue: true,
      ),
    );
    coreMap.setCamera(
      latitude: camera.center.latitude,
      longitude: camera.center.longitude,
      zoom: camera.zoom,
      bearing: camera.bearing,
      pitch: camera.pitch,
    );

    // Zero-copy D3D11 present (the core blits into a shared D3D11 texture ring;
    // the plugin presents it as a Flutter GpuSurfaceTexture via a DXGI shared
    // handle — no CPU readback) is opt-in: --dart-define=MAPLIBRE_ZEROCOPY=true.
    // We commit to the GPU texture only once the native presenter confirms it
    // initialised ([isZeroCopyActive]); otherwise (or if registration fails) we
    // fall back to the CPU PixelBufferTexture path.
    const wantZeroCopy = bool.fromEnvironment(
      'MAPLIBRE_ZEROCOPY',
      defaultValue: false,
    );
    int? textureId;
    if (wantZeroCopy) {
      coreMap.setZeroCopy(true);
      if (await _confirmZeroCopyActive(coreMap)) {
        try {
          textureId = await _registrar
              .invokeMethod<int>('registerTextureGpu', <String, Object?>{
                'mapHandle': coreMap.nativeAddress,
                'currentD3dHandleFn':
                    core.MapLibreCoreMap.currentD3dHandleFunctionAddress,
                'setFrameCallbackFn':
                    core.MapLibreCoreMap.setFrameCallbackFunctionAddress,
              });
        } catch (_) {
          textureId = null;
        }
      }
      if (textureId == null || textureId < 0) {
        coreMap.setZeroCopy(false); // unavailable / failed → CPU fallback
      }
    }

    if (textureId == null || textureId < 0) {
      // CPU pixel-buffer present (default + zero-copy fallback): the core emits
      // RGBA (the plugin's FlutterDesktopPixelBuffer is RGBA), and the native
      // plugin reads each frame over FFI via `mbl_map_copy_frame`.
      coreMap.setPixelFormatBgra(false);
      textureId = await _registrar
          .invokeMethod<int>('registerTexture', <String, Object?>{
            'mapHandle': coreMap.nativeAddress,
            'copyFrameFn': core.MapLibreCoreMap.copyFrameFunctionAddress,
            'setFrameCallbackFn':
                core.MapLibreCoreMap.setFrameCallbackFunctionAddress,
          });
    }

    return MapLibreFlutterWindowsController._(coreMap, textureId ?? -1);
  }

  /// Polls (up to ~1s) for the native D3D presenter to come up after
  /// [setZeroCopy](true) is processed on the render thread.
  static Future<bool> _confirmZeroCopyActive(
    core.MapLibreCoreMap coreMap,
  ) async {
    for (var i = 0; i < 20; i++) {
      if (coreMap.isZeroCopyActive()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  /// Polls until the first frame has rendered, then completes [onReady].
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
  ValueListenable<Size> get textureSize => _textureSize;

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
    // Step an eased arc and render each frame; the core's render thread paces
    // the actual frames (shared desktop behaviour).
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
    if (!_firstResizeApplied) {
      // Apply the initial size immediately so the map fills the window on load,
      // not the 512² placeholder cover-fit for a debounce interval.
      _firstResizeApplied = true;
      _applyResize();
      return;
    }
    // Debounce live drag-resizes. Resizing the core on every layout made its
    // *produced* frame chase the window, so by the time a frame was displayed the
    // widget box had moved on and Flutter stretched it — and the cover-fit had a
    // size that raced ahead of the actually-displayed frame, so it masked nothing.
    // Holding the core (and thus the produced + displayed frame) at one size while
    // the window is actively dragged lets the widget cover-fit that stable frame
    // to the moving box *uniformly* (a small crop, no stretch). The real resize
    // fires once the drag settles and the texture catches up to the final size.
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 100), _applyResize);
  }

  /// Pushes the latest requested size to the core and converges [textureSize] to
  /// it. Called immediately for the first sizing and on each drag settle.
  void _applyResize() {
    if (_disposed) return;
    _coreMap.resize(_renderWidth, _renderHeight);
    _pollTextureSize(_renderWidth / _renderHeight);
  }

  /// After a resize, polls the core's *produced* frame size and publishes it to
  /// [textureSize], stopping once the produced aspect matches [targetAspect]
  /// (the render thread has caught up) or after a short safety cap. The widget's
  /// cover-fit needs the aspect, not the exact size — and aspect is DPR-invariant,
  /// so the produced device-pixel frame compares cleanly to the requested logical
  /// aspect. This is what turns the resize *stretch* into a brief uniform crop:
  /// the published size trails the window, so the texture is cover-fit (not
  /// stretched) until a same-size frame arrives.
  void _pollTextureSize(double targetAspect) {
    _sizePoll?.cancel();
    var ticks = 0;
    _sizePoll = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (_disposed) {
        timer.cancel();
        return;
      }
      final fs = _coreMap.frameSize();
      if (fs != null && fs.height > 0) {
        _textureSize.value = Size(fs.width.toDouble(), fs.height.toDouble());
        if ((fs.width / fs.height - targetAspect).abs() < 0.001) {
          timer.cancel();
          _sizePoll = null;
          return;
        }
      }
      if (++ticks > 90) {
        // ~1.5s cap so a map that idles mid-resize doesn't spin the poll forever.
        timer.cancel();
        _sizePoll = null;
      }
    });
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
    _resizeDebounce?.cancel();
    _resizeDebounce = null;
    _sizePoll?.cancel();
    _sizePoll = null;
    _textureSize.dispose();
    await _registrar.invokeMethod<void>('unregisterTexture', _textureId);
    _coreMap.dispose();
  }
}
