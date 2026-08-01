import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
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
/// FFI (via `maplibre_flutter_core`, the **Vulkan** arm), which renders off-screen
/// on its own thread. Presenting has two paths: a zero-copy D3D11 shared texture
/// when the driver can import it, and a CPU `flutter::PixelBufferTexture`
/// readback (`mbl_map_copy_frame`) otherwise — the Intel driver this was brought
/// up on takes the CPU path, which is why both exist.
///
/// The ANGLE / OpenGL-ES arm this used to describe is gone: mbgl's GL drawables
/// hit a resource-lifetime problem under ANGLE's strict D3D11 validation. See the
/// package README.
///
/// NOTE: not yet run on real Windows hardware — see CLAUDE.md §8.
class MapLibreFlutterWindowsController
    with MapLibreCameraTickNotifier
    implements
        MapLibreMapPlatformController,
        MapLibreGestureHandler,
        MapLibreRotateHandler,
        MapLibreResizeMaskHint,
        MapLibreMapProjector,
        MapLibreStyleLayers,
        MapLibreModelHost,
        MapLibreMapEvents {
  MapLibreFlutterWindowsController._(this._coreMap, this._textureId) {
    _startUp();
  }

  /// Builds a controller around an already-created core map, bypassing
  /// [create]'s native texture registration.
  ///
  /// Exists so the controller body can be tested on the VM against
  /// `RecordingCoreMap` (`package:maplibre_flutter_core/testing.dart`) with no
  /// dylib, GPU or device. [create] is unusable for that: it calls
  /// `MapLibreCoreMap.create` and a `registerTexture` method channel. The
  /// ~400 lines below — camera conversion, fly-to stepping, projector batching,
  /// style pass-through, dispose ordering — are otherwise executed by no test on
  /// any platform (CLAUDE.md §7 layer 2).
  @visibleForTesting
  MapLibreFlutterWindowsController.forTesting(
    core.MapLibreCoreMap coreMap, {
    int textureId = 0,
  }) : _coreMap = coreMap,
       // ignore: prefer_initializing_formals
       _textureId = textureId {
    _startUp();
  }

  final core.MapLibreCoreMap _coreMap;
  final int _textureId;

  bool _disposed = false;
  // Bumped to supersede a running fly-to animation (a new move or a gesture).
  int _animToken = 0;
  final Completer<void> _ready = Completer<void>();

  // --- Diagnostics (MapLibreMapEvents) ---------------------------------------
  //
  // The engine reports asynchronously, so almost every failure arrives here and
  // not as a thrown exception. Broadcast controllers: several widgets may watch
  // one map, and none of them should be required to.
  final StreamController<MapLibreError> _errors =
      StreamController<MapLibreError>.broadcast();
  final StreamController<void> _styleLoads = StreamController<void>.broadcast();
  final StreamController<String> _missingImages =
      StreamController<String>.broadcast();

  bool _diagnosticsInstalled = false;
  bool _styleLoaded = false;
  bool _firstFrame = false;

  @override
  Stream<MapLibreError> get onError => _errors.stream;

  @override
  Stream<void> get onStyleLoaded => _styleLoads.stream;

  @override
  Stream<String> get onStyleImageMissing => _missingImages.stream;

  /// Subscribes to the core's diagnostic channel and fans it out.
  void _installDiagnostics() {
    if (_diagnosticsInstalled || _disposed) return;
    _diagnosticsInstalled = true;
    _coreMap.setDiagnosticCallback((diagnostic) {
      if (_disposed) return;
      switch (diagnostic.kind) {
        case core.CoreDiagnosticKind.styleLoaded:
          _styleLoaded = true;
          if (!_styleLoads.isClosed) _styleLoads.add(null);
          _completeReadyIfLoaded();
        case core.CoreDiagnosticKind.styleImageMissing:
          if (!_missingImages.isClosed) _missingImages.add(diagnostic.message);
        case core.CoreDiagnosticKind.mapLoadFailed:
          _emitError(MapStyleError(diagnostic.message));
        case core.CoreDiagnosticKind.glyphsError:
          _emitError(MapGlyphsError(diagnostic.message));
        case core.CoreDiagnosticKind.spriteError:
          _emitError(MapSpriteError(diagnostic.message));
        case core.CoreDiagnosticKind.renderError:
          _emitError(MapRenderError(diagnostic.message));
        case core.CoreDiagnosticKind.commandFailed:
          _emitError(MapCommandError(diagnostic.message));
        case core.CoreDiagnosticKind.log:
          // The engine logs a great deal at info/debug; only what an app could
          // act on is worth a stream event. This is also the ONLY route a glyph
          // 404 takes — mbgl logs it and never calls onGlyphsError.
          if (diagnostic.severity == core.CoreDiagnosticSeverity.warning ||
              diagnostic.severity == core.CoreDiagnosticSeverity.error) {
            _emitError(MapEngineError(diagnostic.message));
          }
        case core.CoreDiagnosticKind.mapLoaded:
        case core.CoreDiagnosticKind.idle:
          // Neither fires in this configuration (see the stage-2 run log in
          // docs/api-parity-progress.md); listed so the switch stays total.
          break;
      }
    });
  }

  void _emitError(MapLibreError error) {
    if (!_errors.isClosed) _errors.add(error);
  }

  static const int _initialWidth = 512;
  static const int _initialHeight = 512;
  int _renderWidth = _initialWidth;
  int _renderHeight = _initialHeight;

  // Models currently on the map, and the repaint pump that animates them.
  //
  // Continuous mode is UPDATE-driven, not vsync-driven: with nothing
  // invalidating the map, a spinning model renders exactly once and stops. So
  // while any model has a non-zero spin we tick triggerRepaint from a Ticker.
  // Static models need no pump, which keeps the common case free of a permanent
  // render loop.
  final Map<String, MapLibreModel> _models = <String, MapLibreModel>{};
  Ticker? _modelTicker;

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
    // handle — no CPU readback) is the default — set
    // --dart-define=MAPLIBRE_ZEROCOPY=false to force the CPU path. We commit to the
    // GPU texture only once the native presenter confirms it initialised
    // ([isZeroCopyActive]); otherwise (or if registration fails, e.g. a driver that
    // can't import the legacy D3D11 shared handle) we fall back to the CPU
    // PixelBufferTexture path, so the map still renders.
    const wantZeroCopy = bool.fromEnvironment(
      'MAPLIBRE_ZEROCOPY',
      defaultValue: true,
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

  /// Starts the readiness handshake: subscribe to the engine's events, then
  /// wait for the first frame.
  void _startUp() {
    _installDiagnostics();
    _pollFirstFrame();
  }

  /// Polls until the first frame exists. Readiness needs the STYLE as well —
  /// see [_completeReadyIfLoaded]. Stops on dispose.
  void _pollFirstFrame() {
    if (_disposed || _ready.isCompleted) return;
    if (_coreMap.awaitFrame(Duration.zero)) {
      _firstFrame = true;
      _completeReadyIfLoaded();
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 50), _pollFirstFrame);
  }

  /// Completes [onReady] once the initial style has loaded AND a frame exists.
  ///
  /// The style half is the contract: `onReady` means gl-js `load`, and this tier
  /// used to complete it on the first FRAME alone — which can precede the style
  /// finishing, so an app that added a layer right after awaiting it lost the
  /// layer to the style load that came next. The frame half is kept because
  /// callers rely on a transform existing (projection returns null without one).
  ///
  /// A style that never loads therefore never completes this, exactly as gl-js
  /// never fires `load`. Listen to [onError] to hear why.
  void _completeReadyIfLoaded() {
    if (_disposed || _ready.isCompleted) return;
    if (!_styleLoaded || !_firstFrame) return;
    _ready.complete();
    // The first frame implies the transform snapshot exists; tick so any glued
    // overlay reprojects from off-screen to its real position.
    // Without this MapLibreMap(markers:) draws NOTHING until the first pan:
    // MarkerOverlay only starts repainting on a projector notification, and
    // its delegate skips every child while the projection generation is 0.
    notifyCameraChanged();
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
    notifyCameraChanged(); // reproject glued widget overlays
  }

  @override
  Future<void> setStyle(String styleUri) async {
    // Guarded like every other forward: the core throws StateError once
    // disposed, and the widget pushes its declarative `style` prop from
    // didUpdateWidget, which can land during teardown.
    if (_disposed) return;
    _coreMap.setStyle(styleUri);
  }

  @override
  Future<void> resize(Size size, double devicePixelRatio) async {
    if (_disposed) return;
    // Pass LOGICAL points as mbgl's size; the core multiplies by the pixelRatio set
    // at create to produce the device-pixel texture. (devicePixelRatio is unused
    // here — the core already knows the density.) The MapLibreMap widget debounces
    // these calls during an active drag (see MapLibreResizeMaskHint) so the core is
    // only resized once the window settles — it cover-fits the frozen frame in the
    // meantime, so the map never stretches on the slow CPU-readback present.
    final w = size.width.round();
    final h = size.height.round();
    if (w <= 0 || h <= 0 || (w == _renderWidth && h == _renderHeight)) return;
    _renderWidth = w;
    _renderHeight = h;
    _coreMap.resize(w, h);
    notifyCameraChanged(); // viewport size feeds the projection
  }

  @override
  void moveBy(double dx, double dy) {
    if (_disposed) return;
    _animToken++; // a gesture supersedes any running fly-to
    // mbgl's screen coordinates are logical points (Size = logical points),
    // matching the widget's gesture deltas — no DPR scaling.
    _coreMap.moveBy(dx, dy);
    notifyCameraChanged(); // reproject glued widget overlays
  }

  @override
  void scaleBy(double scale, double anchorX, double anchorY) {
    if (_disposed) return;
    _animToken++; // a gesture supersedes any running fly-to
    // Pass the anchor straight through (top-left, logical points — same space as
    // moveBy's deltas), matching the hardware-verified Linux controller. The present
    // path's blit (Vulkan blitImage / GL glBlitFramebuffer with inverted dst Y) flips
    // only the PIXEL BUFFER from mbgl's bottom-up framebuffer to the top-down texture
    // convention — it does NOT change mbgl's top-left ScreenCoordinate anchor space,
    // which already matches Flutter's top-left gesture coordinates. mbgl's easeTo
    // handles Y internally; no pre-flip is needed. A `_renderHeight - anchorY` flip
    // (briefly shipped) mirrored the anchor vertically — a top-of-widget pinch zoomed
    // about the bottom. Verified on Windows hardware: raw anchor zooms on the cursor.
    _coreMap.scaleBy(scale, anchorX, anchorY);
    notifyCameraChanged(); // reproject glued widget overlays
  }

  @override
  void rotateBy(double degrees, double anchorX, double anchorY) {
    if (_disposed) return;
    _animToken++; // a gesture supersedes any running fly-to
    // Anchor passes STRAIGHT THROUGH — no `_renderHeight - anchorY`. mbgl
    // documents CameraOptions' anchor as top-left origin and converts it
    // itself; a briefly-shipped flip here mirrored the Windows pinch anchor.
    // The clockwise/bearing sign lives in the C shim, once, not per controller.
    _coreMap.rotateBy(degrees, anchorX, anchorY);
    // Bearing changes where EVERY projected marker lands, so glued overlays
    // must reproject — omit this and markers swim during a twist while pan and
    // zoom look perfectly fine.
    notifyCameraChanged();
  }

  @override
  void pitchBy(double degrees) {
    if (_disposed) return;
    _animToken++;
    _coreMap.pitchBy(degrees);
    notifyCameraChanged();
  }

  // --- MapLibreStyleLayers ----------------------------------------------------
  // Straight pass-through to the core: mbgl owns the style, and the shim already
  // validates the JSON synchronously and marshals the mutation onto the render
  // thread. Silently ignored after dispose (matches the rest of this controller,
  // where late calls from a torn-down widget are a no-op rather than a throw).

  @override
  void addSourceJson(String id, String json) {
    if (_disposed) return;
    _coreMap.addSourceJson(id, json);
  }

  @override
  void addLayerJson(String json, {String? beforeId}) {
    if (_disposed) return;
    _coreMap.addLayerJson(json, beforeId: beforeId);
  }

  @override
  void setGeoJsonData(String sourceId, String geoJson) {
    if (_disposed) return;
    _coreMap.setGeoJsonData(sourceId, geoJson);
  }

  @override
  void removeLayer(String id) {
    if (_disposed) return;
    _coreMap.removeLayer(id);
  }

  @override
  void removeSource(String id) {
    if (_disposed) return;
    _coreMap.removeSource(id);
  }

  @override
  void addImage(
    String id,
    Uint8List rgba,
    int width,
    int height, {
    double pixelRatio = 1.0,
    bool sdf = false,
  }) {
    if (_disposed) return;
    _coreMap.addImage(
      id,
      rgba,
      width,
      height,
      pixelRatio: pixelRatio,
      sdf: sdf,
    );
  }

  @override
  void removeImage(String id) {
    if (_disposed) return;
    _coreMap.removeImage(id);
  }

  @override
  void setTransitionOptions({
    Duration? duration,
    Duration? delay,
    bool placementTransitions = true,
  }) {
    if (_disposed) return;
    _coreMap.setTransitionOptions(
      duration: duration,
      delay: delay,
      placementTransitions: placementTransitions,
    );
  }

  @override
  String? queryRenderedFeaturesJson(
    double minX,
    double minY,
    double maxX,
    double maxY, {
    List<String>? layerIds,
  }) {
    if (_disposed) return null;
    return _coreMap.queryRenderedFeatures(
      minX,
      minY,
      maxX,
      maxY,
      layerIds: layerIds,
    );
  }

  // --- MapLibreMapProjector ---------------------------------------------------
  // Projection runs synchronously over the core's lock-free transform snapshot,
  // so it is cheap to call from a Flow paint every camera tick. Screen space is
  // logical points, top-left origin (matching the gesture deltas above).

  // Reused across frames so projecting markers every camera tick allocates
  // nothing on the Dart side (the core reuses native buffers in turn).
  Float64List _projIn = Float64List(0);
  Float64List _projOut = Float64List(0);
  Int32List _projVis = Int32List(0);

  @override
  int project(List<LatLng> points, List<ui.Offset> out, {List<bool>? visible}) {
    if (_disposed || points.isEmpty) return 0;
    final n = points.length;
    if (_projIn.length < n * 2) {
      _projIn = Float64List(n * 2);
      _projOut = Float64List(n * 2);
      _projVis = Int32List(n);
    }
    for (var i = 0; i < n; i++) {
      _projIn[i * 2] = points[i].latitude;
      _projIn[i * 2 + 1] = points[i].longitude;
    }
    // Project against the transform of the frame ON SCREEN, not the newest one.
    // Camera commands apply asynchronously on the render thread, so the newest
    // transform typically leads the visible frame — projecting against it makes
    // markers swim/lag during movement. (0 before the first frame, which the
    // core treats as "newest".)
    final gen = _coreMap.projectBatch(
      n,
      _projIn,
      _projOut,
      visible: _projVis,
      generation: _coreMap.presentedGeneration,
    );
    if (gen == 0) return 0;
    for (var i = 0; i < n; i++) {
      out[i] = ui.Offset(_projOut[i * 2], _projOut[i * 2 + 1]);
      if (visible != null) visible[i] = _projVis[i] != 0;
    }
    return gen;
  }

  @override
  LatLng? unproject(ui.Offset point) {
    if (_disposed) return null;
    // Same frame the user is looking at (and the same one project() used), so a
    // tap maps to the point actually under the cursor mid-movement.
    final r = _coreMap.unproject(
      point.dx,
      point.dy,
      generation: _coreMap.presentedGeneration,
    );
    return r == null ? null : LatLng(r.latitude, r.longitude);
  }

  @override
  void addModel(MapLibreModel model) {
    if (_disposed) return;
    // Throws ArgumentError with the native reason if the .glb cannot be loaded;
    // let it propagate so a bad path is loud rather than a silently absent model.
    _coreMap.addModel(
      layerId: model.id,
      path: model.assetPath,
      latitude: model.point.latitude,
      longitude: model.point.longitude,
      scale: model.scale,
      headingDegrees: model.headingDegrees,
      spinDegreesPerSecond: model.spinDegreesPerSecond,
      elevationMetres: model.elevationMetres,
    );
    _models[model.id] = model;
    _syncModelPump();
  }

  @override
  void updateModel(MapLibreModel model) {
    if (_disposed || !_models.containsKey(model.id)) return;
    // Mutates the native placement only — the mesh is never re-uploaded, which is
    // what makes per-frame movement affordable.
    _coreMap.setModelTransform(
      layerId: model.id,
      latitude: model.point.latitude,
      longitude: model.point.longitude,
      scale: model.scale,
      headingDegrees: model.headingDegrees,
      elevationMetres: model.elevationMetres,
    );
    _models[model.id] = model;
  }

  @override
  int? get renderedFrameCount => _disposed ? null : _coreMap.renderedFrameCount;

  @override
  int? modelPartCount(String assetPath) =>
      core.MapLibreCoreMap.modelPartCount(assetPath);

  @override
  void removeModel(String id) {
    if (_disposed) return;
    if (_models.remove(id) == null) return;
    _coreMap.removeModel(id);
    _syncModelPump();
  }

  /// Starts or stops the repaint pump depending on whether anything animates.
  void _syncModelPump() {
    final needsPump = _models.values.any((m) => m.spinDegreesPerSecond != 0);
    if (needsPump && _modelTicker == null) {
      _modelTicker = Ticker((_) {
        if (_disposed) return;
        _coreMap.triggerRepaint();
      })..start();
    } else if (!needsPump && _modelTicker != null) {
      _modelTicker!
        ..stop()
        ..dispose();
      _modelTicker = null;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    disposeCameraTick();
    // Stop the pump BEFORE the awaited channel round trip: awaiting first
    // leaves a window in which the ticker can fire against a texture that is
    // already unregistered.
    _modelTicker?.stop();
    _modelTicker?.dispose();
    _modelTicker = null;
    await _registrar.invokeMethod<void>('unregisterTexture', _textureId);
    // Unregisters the native diagnostic callback before the core is torn
    // down, so nothing can arrive after the streams close.
    _coreMap.dispose();
    unawaited(_errors.close());
    unawaited(_styleLoads.close());
    unawaited(_missingImages.close());
  }
}
