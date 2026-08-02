import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_flutter/maplibre_flutter.dart';

import 'accessibility_page.dart';

// Conditional: the engine reads a real filesystem path, which web does not
// have. Without this split the unconditional `dart:io` import made the whole
// example unbuildable for web — so the one app that demonstrates the plugin
// could not demonstrate the default web renderer at all.
import 'model_asset_io.dart'
    if (dart.library.js_interop) 'model_asset_web.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'maplibre_flutter example',
      home: const MapDemoPage(),
      routes: <String, WidgetBuilder>{
        '/accessibility': (_) => const AccessibilityDemoPage(),
      },
    );
  }
}

// --- Styles ------------------------------------------------------------------

/// Two keyless styles to toggle between (no API key required).
const _demotiles = 'https://demotiles.maplibre.org/style.json';

/// A whole style document, written here rather than fetched — the third way to
/// say "this is the map". No glyphs and no label layers, so it needs no font
/// endpoint.
const _inlineStyle = '''
{
  "version": 8,
  "sources": {
    "maplibre": {
      "type": "vector",
      "url": "https://demotiles.maplibre.org/tiles/tiles.json"
    }
  },
  "layers": [
    {"id": "bg", "type": "background",
     "paint": {"background-color": "#f6f1e7"}},
    {"id": "land", "type": "fill", "source": "maplibre",
     "source-layer": "countries",
     "paint": {"fill-color": "#c9b79c", "fill-outline-color": "#8a7a5f"}}
  ]
}
''';

/// A style shipped in the app bundle, listed under `assets:` in pubspec.yaml.
/// `asset://` is ours, not MapLibre's: the engine cannot read a Flutter asset,
/// so [MapLibreMapController] reads it and hands the engine the document.
const _assetStyle = 'asset://assets/styles/nordic_night.json';

/// The three forms, in the order the scenario cycles them.
const _styleForms = <(String, String, String)>[
  ('URL', _demotiles, 'style.json fetched over HTTP — the usual case'),
  (
    'Inline document',
    _inlineStyle,
    'the JSON itself, passed straight in — the engine sees a leading { and '
        'calls Style::loadJSON rather than loadURL',
  ),
  (
    'Bundled asset',
    _assetStyle,
    'asset://assets/styles/nordic_night.json, read from the app bundle by the '
        'controller before the engine ever sees it',
  ),
];
const _liberty = 'https://tiles.openfreemap.org/styles/liberty';

/// A font BOTH styles actually serve.
///
/// This matters more than it looks. A symbol layer naming a font the style
/// cannot serve makes mbgl 404 the glyph range, and that failure comes back out
/// of the render itself — no frame is produced and the whole source disappears.
/// Verified by probing the glyph endpoints: demotiles has "Open Sans Semibold"
/// (NOT Regular) and "Noto Sans Regular"; Liberty has the Noto family only. So
/// Noto Sans Regular is the one safe choice across both.
const _safeFont = <String>['Noto Sans Regular'];

// --- Places ------------------------------------------------------------------

const _turku = LatLng(60.4518, 22.2666);
const _stockholm = LatLng(59.3293, 18.0686);
const _london = LatLng(51.5074, -0.1278);

const _places = <(String, LatLng, double)>[
  ('Finland', LatLng(64.5, 26.0), 4.2),
  ('Turku', _turku, 10),
  ('Stockholm', _stockholm, 10),
  ('London', _london, 10),
];

// --- Scenarios ---------------------------------------------------------------

/// One thing under test at a time. The example used to be a pile of interacting
/// toggles, which made it unclear what any given frame was demonstrating.
enum Scenario {
  interaction(
    'Interaction',
    'Widget markers that must stay live: tap London for a snackbar, drag the '
        'indigo pin, watch Stockholm pulse. Tap empty map to drop a pin '
        '(projection round-trip).',
  ),
  widgetMarkers(
    'Widget markers (stress)',
    'Flutter widgets glued to points, the interactive tier. Watch frame times '
        'as the count rises — this tier tops out in the hundreds of rich '
        'children. Pins must track the map exactly, including near the edges.',
  ),
  enginePoints(
    'Engine points',
    'Points drawn by mbgl itself, unclustered. Glued by construction and '
        'GPU-scaled: 50k should cost far less than 2k widget markers.',
  ),
  engineClusters(
    'Engine clustering',
    'Same data, clustered inside the engine by supercluster. Bubbles are '
        'labelled with their point count and split apart as you zoom in.',
  ),
  engineIcons(
    'Engine icons from a widget',
    'A Flutter widget painted once and drawn by the engine at every point. '
        'Clustered, so leaves appear as you zoom in. Static snapshots — no '
        'animation, no gestures.',
  ),
  engineIconsFlat(
    'Engine icons — no clustering',
    'The same widget-derived icon at EVERY point, unclustered: raw symbol '
        'throughput with nothing hidden. At 50k zoomed out this is a solid '
        'mass by design — zoom in to read it, and watch frame times.',
  ),
  typedStyle(
    'Typed style API',
    'The generated style API, used directly — no addPoints. One GeoJsonSource '
        'with per-point properties feeds a CircleLayer whose colour comes from '
        'Expr.match and radius from Expr.interpolate, a SymbolLayer labelling '
        'each city, and a dashed LineLayer route. Data-driven styling with no '
        'JSON in sight.',
  ),
  geojsonFeatures(
    'Typed GeoJSON + queries',
    'A FeatureCollection built from GeoJsonPolygon / GeoJsonLineString / '
        'GeoJsonPoint — no JSON strings — each carrying an id and properties. '
        'TAP ANYWHERE: queryRenderedFeatures reports what the engine drew '
        'there, with full geometry and the feature id. Tap the shaded region '
        'or the route to see a polygon and a line come back; both used to be '
        'dropped silently, so a fill or line layer answered every query with '
        'nothing.',
  ),
  cameraVerbs(
    'Camera verbs',
    'The gl-js camera API running in the ENGINE, not in Dart: jumpTo with a '
        'PARTIAL camera (zoom only — centre, bearing and pitch survive), easeTo '
        'along a straight line, flyTo along mbgl\'s own van Wijk arc, rotateTo, '
        'resetNorth, and zoomIn/zoomOut anchored on a CORNER so you can see the '
        'anchor is honoured. Each step is awaited: the Future completes when the '
        'engine says the transition ended, and a superseded one completes too '
        'rather than hanging. Then fitBounds frames the dataset.',
  ),
  cameraConstraints(
    'Camera constraints',
    'gl-js setMaxBounds semantics: the whole VIEWPORT is kept inside the '
        'Nordics, and zoom is clamped to 3..12. Try to pan away or zoom out — '
        'the engine refuses. mbgl\'s own BoundOptions constrains the camera '
        'CENTRE under that same word, so the controller sets the constrain mode '
        'to match gl-js rather than shipping Android semantics under a gl-js '
        'name.',
  ),
  diagnostics(
    'Engine diagnostics',
    'Everything mbgl fails at asynchronously used to be a blank map and total '
        'silence. This provokes three DIFFERENT failures — removing a layer '
        'that is not there, removing a source a layer still uses, and a font no '
        'style serves — and shows each arriving on controller.onError. The font '
        'one is the important one: mbgl reports a glyph 404 ONLY through its '
        'log, never through the observer.',
  ),
  capabilities(
    'Capabilities + value types',
    'What this renderer can actually do, read live from '
        'controller.capabilities — the tiers genuinely differ, and this is the '
        'supported way to ask rather than calling something and watching it '
        'no-op. Also shows LatLngBounds over the engine dataset, a partial '
        'CameraOptions, and LatLng.sanitized/wrapped against values mbgl::LatLng '
        'would throw on (a throw across the FFI boundary being undefined '
        'behaviour rather than a catchable error).',
  ),
  hybrid(
    'Hybrid: animated + 50k',
    'All 50k live in the engine, clustered there. queryRenderedFeatures asks '
        'the engine what it actually drew, and each of those becomes a REAL '
        'animated Flutter widget — pulsing bubbles carrying the engine\'s own '
        'point_count, individual pins once zoomed in. Live widget count stays '
        'small however big the dataset is.',
  ),
  retainRuntimeStyle(
    'Style swap: keep my layers',
    'A style load REPLACES the document, so every source and layer you added '
        'goes with it — that is mbgl, and gl-js, Apple and Android all tell you '
        'to re-add from the style-loaded event. Set '
        'MapLibreMap.retainRuntimeStyle and the widget does it for you: it '
        'snapshots each layer AS IT STANDS (the red recolour below is applied '
        'after the add, and survives) and re-adds it once the new style is in. '
        'Hit the Demotiles/Liberty toggle with the switch off, then on, and '
        'compare. Engine ICONS and 3D models survive either way — they have no '
        'form in a style document, so only the engine can put them back.',
  ),
  styleForms(
    'Style: URL, document, asset',
    'The same widget property, `MapLibreMap.style`, given a style three ways: '
        'a URL, the style DOCUMENT itself as inline JSON, and a JSON file '
        'shipped in the app bundle as `asset://…`. The engine sniffs a leading '
        '`{` and calls loadJSON instead of loadURL; the asset form is resolved '
        'in Dart, because mbgl has no idea what a Flutter asset is. A bundled '
        'document is how you ship a map that renders with no style server.',
  ),
  models3d(
    '3D model',
    'A .glb model drawn INSIDE the engine (mbgl CustomDrawableLayer), so it '
        'depth-occludes against buildings instead of floating over them. Tilt '
        'and rotate with the map controls; Drive walks it around a 20 m loop, '
        'facing along its own tangent.',
  ),
  models3dStress(
    '3D models (stress)',
    'N models each wandering its own way, to price 3D: draw calls, per-frame '
        'updateModel traffic, and whether the repaint pump keeps up. The HUD '
        'reports the MAP\'s frame rate separately from Flutter\'s vsync — they '
        'are different questions. Swap to the 24-triangle box to separate '
        'geometry-bound from draw-call-bound.',
  );

  const Scenario(this.label, this.blurb);
  final String label;
  final String blurb;

  /// Scenarios that put .glb models in the engine, so leaving one has to tear
  /// them down and the model controls only appear for them.
  bool get usesModels => this == models3d || this == models3dStress;
}

/// One model wandering the stress field: a heading that curves, and a bounce off
/// the field edge so they stay in view instead of dispersing.
class _Wanderer {
  _Wanderer({
    required this.id,
    required this.x,
    required this.y,
    required this.bearing,
    required this.speed,
    required this.turnRate,
  });

  final String id;
  final double speed;
  double x;
  double y;
  double bearing;
  double turnRate;

  void advance(double dt, double field) {
    bearing = (bearing + turnRate * dt) % 360;
    final rad = bearing * math.pi / 180;
    // Bearing is clockwise from north: north is +y, east is +x.
    x += math.sin(rad) * speed * dt;
    y += math.cos(rad) * speed * dt;

    final half = field / 2;
    if (x.abs() > half || y.abs() > half) {
      // Turn back toward the middle rather than teleporting, so motion stays
      // continuous and the heading keeps matching the direction of travel.
      bearing = (math.atan2(-x, -y) * 180 / math.pi) % 360;
      x = x.clamp(-half, half);
      y = y.clamp(-half, half);
    }
  }
}

class MapDemoPage extends StatefulWidget {
  const MapDemoPage({super.key});

  @override
  State<MapDemoPage> createState() => _MapDemoPageState();
}

class _MapDemoPageState extends State<MapDemoPage> {
  final MapLibreMapController _controller = MapLibreMapController();
  bool _ready = false;

  /// Whether a style has finished loading at least once. Separate from [_ready]
  /// so the UI can say WHICH half of readiness is outstanding — an eternal
  /// spinner that cannot say why is indistinguishable from a hang.
  bool _styleSeen = false;

  /// Ticks while waiting, so the loading label can report how long it has been.
  Timer? _readyWatchdog;
  int _waitingSeconds = 0;
  String _style = _demotiles;
  int _placeIndex = 0;

  Scenario _scenario = Scenario.interaction;

  /// How to undo whatever the current scenario added, in reverse order.
  ///
  /// Each setup path appends its own cleanup, so teardown removes exactly what
  /// exists — see the note in [_applyScenario].
  final List<void Function()> _teardown = <void Function()>[];

  // Interaction scenario state.
  LatLng _draggable = const LatLng(48.8566, 2.3522);
  final List<LatLng> _dropped = <LatLng>[];

  // Widget-marker stress state.
  static const _widgetCounts = <int>[100, 500, 1000, 1500, 2000];
  int _widgetCountIndex = 0;
  List<LatLng> _widgetPoints = const <LatLng>[];
  bool _repaintBoundaries = false; // measured: no effect; see MapLibreMarker
  bool _fancyMarkers = false;

  // Engine dataset state.
  static const _engineCounts = <int>[5000, 50000];
  int _engineCountIndex = 1;

  // Hybrid state: what the engine reports drawing, promoted to real widgets.
  List<QueriedFeature> _liveFeatures = const [];

  // Typed-GeoJSON scenario: whatever the last tap found under the finger.
  List<QueriedFeature> _tapped = const [];
  LatLng? _tappedAt;

  // Live engine diagnostics. Kept short — this is a demo, not a log viewer.
  final List<String> _diagnostics = <String>[];
  bool _showDiagnostics = false;
  bool _showCapabilities = false;

  /// Why the camera is moving right now; empty when it is still.
  Set<MapCameraChangeReason> _moveReasons = const {};
  int _styleLoadCount = 0;

  /// Which of [_styleForms] the styleForms scenario is showing.
  int _styleFormIndex = 0;

  /// Drives MapLibreMap.retainRuntimeStyle for the retainRuntimeStyle scenario.
  bool _retainRuntimeStyle = false;
  final List<StreamSubscription<Object?>> _eventSubscriptions =
      <StreamSubscription<Object?>>[];

  /// The dataset every engine scenario draws. Deterministic, so runs compare.
  static List<LatLng> _dataset(int count) {
    final rnd = math.Random(7);
    return List<LatLng>.generate(
      count,
      (_) => LatLng(
        59.9 + rnd.nextDouble() * 10.0, // ~59.9..69.9 N
        21.0 + rnd.nextDouble() * 10.0, // ~21..31 E
      ),
    );
  }

  // --- 3D model state (ported from feat/3d-model-spike) ----------------------
  //
  // A bundled demo vehicle is used by default, so the scenario shows a model
  // with no setup. Point at your own with:
  //   flutter run -d macos --dart-define=MODEL_GLB=/abs/path/to/model.glb
  //
  // MODEL_GLB must be a real path on disk. Under the macOS/iOS sandbox an app
  // can only read its own container, so a path in ~/Downloads additionally needs
  // an entitlement — which is why the default ships as an asset.

  /// Pre-slimmed and pre-normalised by tool/slim_glb.py: unused attributes
  /// stripped, scale and heading baked into a wrapper node so it is life size and
  /// nose-north at scale 1 / heading 0. Attribution in assets/models/README.md
  /// (CC BY 4.0, redistributed here).
  static const String _carAsset = 'assets/models/alto_k10.glb';

  /// The authored test box: 2 parts, 24 triangles. Switching to it holds instance
  /// count and updateModel traffic constant while cutting triangles ~30000x and
  /// draw calls 28x — which is what separates "geometry bound" from "draw-call
  /// bound". Same scene, one variable changed.
  static const String _boxAsset = 'assets/models/demo_vehicle.glb';

  String _demoAsset = _carAsset;
  final Map<String, String> _resolvedAssets = <String, String>{};
  static const String _modelPath = String.fromEnvironment(
    'MODEL_GLB',
    defaultValue: '',
  );

  // Many models are not authored in metres (Sketchfab exports especially), and
  // glTF's -Z-forward convention is widely ignored, so both are overridable.
  // Dart only has bool/int/String fromEnvironment, so these arrive as strings.
  static const String _modelScaleRaw = String.fromEnvironment(
    'MODEL_SCALE',
    defaultValue: '1',
  );
  static const String _modelHeadingRaw = String.fromEnvironment(
    'MODEL_HEADING',
    defaultValue: '0',
  );

  /// Lift off the ground. A model sitting exactly at ground level is coplanar
  /// with the basemap and z-fights, so the map bleeds through the bodywork.
  static const String _modelElevationRaw = String.fromEnvironment(
    'MODEL_ELEVATION',
    defaultValue: '0.15',
  );
  static double get _modelScale => double.tryParse(_modelScaleRaw) ?? 1;
  static double get _modelHeading => double.tryParse(_modelHeadingRaw) ?? 0;
  static double get _modelElevation =>
      double.tryParse(_modelElevationRaw) ?? 0.15;

  bool _modelAdded = false;
  String? _modelError;

  /// Where to put the model. A few-metre object is sub-pixel below roughly z18,
  /// and the example opens at world view, so "place it at the current centre"
  /// would drop it at null island invisibly.
  static const LatLng _modelSite = LatLng(51.50735, -0.12776); // Westminster
  LatLng _modelAnchor = _modelSite;

  // Driving: the model is walked around a circle by mutating its placement each
  // frame. Re-adding it would re-parse the whole .glb every frame, so this uses
  // updateModel, which only touches the native placement.
  Ticker? _driveTicker;
  bool _driving = false;

  // Following a circle rotates the model 360 degrees per lap — that is simply
  // what driving a roundabout is. But how it READS depends on the loop size
  // relative to the car: at 10 m the loop is ~6 car lengths across and the car
  // looks like it is spinning; 20 m is ~11 car lengths, which reads as a vehicle
  // following a curve. The loop then needs the camera pulled back to fit: at z19
  // a metre is ~11 logical pixels, so a 20 m radius is a ~430 px loop.
  static const double _driveRadiusMetres = 20;
  static const double _drivePeriodSeconds = 26;
  static const double _driveZoom = 19;

  // --- Stress mode -----------------------------------------------------------
  int _stressCount = 24; // adjustable, so the knee can be found
  static const double _stressFieldMetres = 120;
  Ticker? _stressTicker;
  bool _stressing = false;
  final List<_Wanderer> _wanderers = <_Wanderer>[];
  String? _stressAsset;
  LatLng? _stressCentre;
  int _stressNextId = 0;
  final math.Random _stressRng = math.Random(7); // seeded: runs stay comparable
  int _stressFrames = 0;
  Duration _stressLastReport = Duration.zero;
  double _stressFps = 0;
  double _stressWorstMs = 0; // worst frame in the last window, not the average
  int _partsPerModel = 0;

  /// The MAP's own frame rate, from the renderer's published-frame counter. The
  /// Ticker figure is FLUTTER's vsync, which stays pinned at the display rate
  /// however far behind the map falls — the map is a texture, so Flutter has
  /// nothing to wait for. Two numbers because they answer two questions.
  double _mapFps = 0;
  int _lastRenderedFrames = 0;

  /// Widget markers cluster tightly around Turku so they share a viewport.
  static List<LatLng> _widgetCluster(int count) {
    final rnd = math.Random(42);
    return List<LatLng>.generate(
      count,
      (_) => LatLng(
        _turku.latitude + (rnd.nextDouble() - 0.5) * 0.30,
        _turku.longitude + (rnd.nextDouble() - 0.5) * 0.60,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // Subscribe BEFORE the map is built. The engine's most useful report is a
    // first style load that fails, and that happens during creation — the
    // controller's streams are live from construction precisely so this works.
    _eventSubscriptions.addAll([
      // WHY the camera is moving. Nothing in the engine can answer this —
      // mbgl reports only {Immediate, Animated} — so the reason is synthesised
      // by the Dart gesture layer, which is the one place that can tell a pan
      // from a pinch from a twist from a shove.
      _controller.onCameraMoveStart.listen((reasons) {
        if (mounted) setState(() => _moveReasons = reasons);
      }),
      _controller.onCameraMoveEnd.listen((_) {
        if (mounted) setState(() => _moveReasons = const {});
      }),
      _controller.onStyleLoaded.listen((_) {
        if (mounted && !_styleSeen) setState(() => _styleSeen = true);
      }),
      _controller.onError.listen((error) => _logDiagnostic('$error')),
      _controller.onStyleImageMissing.listen(
        (id) => _logDiagnostic('style image missing: $id'),
      ),
    ]);
    _controller.onReady.then((_) async {
      if (!mounted) return;
      _readyWatchdog?.cancel();
      setState(() {
        _ready = true;
        _waitingSeconds = 0;
      });
      await _applyScenario();
    });
    // Report how long readiness is taking, and to say what is missing. A map
    // whose style 404s never becomes ready — correctly, since gl-js never fires
    // `load` either — and without this the app would just sit there.
    _readyWatchdog = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _ready) {
        timer.cancel();
        return;
      }
      setState(() => _waitingSeconds++);
      if (_waitingSeconds == 8) {
        _logDiagnostic(
          'still waiting: attached=${_controller.isAttached} '
          'style=$_styleSeen — check the network, or watch for an error above',
        );
      }
    });
  }

  /// Appends one engine report to the on-screen list.
  void _logDiagnostic(String line) {
    if (!mounted) return;
    setState(() {
      _diagnostics.insert(0, line);
      if (_diagnostics.length > 12) _diagnostics.removeLast();
      _showDiagnostics = true;
    });
  }

  @override
  void dispose() {
    _readyWatchdog?.cancel();
    for (final subscription in _eventSubscriptions) {
      subscription.cancel();
    }
    _controller.onCameraChanged?.removeListener(_onCameraChangedForHybrid);
    _trailingQuery?.cancel();
    _driveTicker
      ?..stop()
      ..dispose();
    _stressTicker
      ?..stop()
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  // --- Scenario wiring --------------------------------------------------------

  Future<void> _selectScenario(Scenario s) async {
    setState(() => _scenario = s);
    await _applyScenario();
  }

  /// Tears down whatever the previous scenario built and sets up the new one.
  ///
  /// Also re-run after a style swap: loading a style REPLACES the whole
  /// document, so every source and layer we added goes with it.
  Future<void> _applyScenario() async {
    // Needs a bound map, not a fully READY one: engine calls before the style
    // lands are dropped by mbgl, but onStyleLoaded re-runs this the moment the
    // document is in, so an early switch costs nothing and an early return
    // would leave the scenario unapplied.
    if (!_controller.isAttached) return;
    final layers = _controller.style;

    // Clear everything the PREVIOUS scenario added — exactly that, and nothing
    // else.
    //
    // This used to be a blanket list of every id any scenario might have used,
    // fired unconditionally. That was invisible until `controller.onError`
    // existed: now each removal of something that was never added reports a
    // MapCommandError, and a scenario switch produced seven of them. Removing
    // optimistically is a habit an error channel immediately makes untenable,
    // which is a fair advertisement for having one.
    _controller.onCameraChanged?.removeListener(_onCameraChangedForHybrid);
    _trailingQuery?.cancel();
    _stopDriving();
    _stopStress();
    _removeModel();
    for (final undo in _teardown.reversed) {
      undo();
    }
    _teardown.clear();
    setState(() {
      _liveFeatures = const [];
      _widgetPoints = const [];
    });

    // KNOWN, ACCEPTED: a cluster's count label outlives its bubble by ~300 ms.
    // Symbol layers fade (mbgl ramps their opacity over the style's transition
    // duration); a circle is a feature that simply stops being drawn. So the
    // number hangs in the air for a few frames after the circle has gone.
    //
    // Deliberately NOT worked around here. Every lever is style-wide — see
    // MapLibreStyleController.setTransitionOptions — so buying this back means
    // overriding the style's own transition behaviour and changing how the
    // BASEMAP's labels fade, which is a worse trade than the artifact. The knob
    // is there for apps that decide otherwise. maplibre-gl-js behaves the same.

    switch (_scenario) {
      case Scenario.interaction:
        break;

      case Scenario.widgetMarkers:
        setState(
          () =>
              _widgetPoints = _widgetCluster(_widgetCounts[_widgetCountIndex]),
        );

      case Scenario.enginePoints:
        layers.addCircleLayersFromPoints(
          'bulk',
          _dataset(_engineCounts[_engineCountIndex]),
          radius: 3,
        );
        _teardown.add(() => layers.removeCircleLayersFromPoints('bulk'));

      case Scenario.engineClusters:
        layers.addCircleLayersFromPoints(
          'bulk',
          _dataset(_engineCounts[_engineCountIndex]),
          cluster: true,
          radius: 4,
          clusterTextFont: _safeFont,
        );
        _teardown.add(() => layers.removeCircleLayersFromPoints('bulk'));

      case Scenario.typedStyle:
        _applyTypedStyle();

      case Scenario.geojsonFeatures:
        _applyGeoJsonFeatures();

      case Scenario.cameraVerbs:
        // Runs on entry so the scenario demonstrates itself; the Replay button
        // in the control bar runs it again.
        await _runCameraTour();

      case Scenario.cameraConstraints:
        await _applyConstraints(on: true);
        _teardown.add(() => unawaited(_applyConstraints(on: false)));

      case Scenario.diagnostics:
        setState(() => _showDiagnostics = true);
        _breakSomething();

      case Scenario.capabilities:
        setState(() => _showCapabilities = true);
        _teardown.add(() => setState(() => _showCapabilities = false));

      case Scenario.retainRuntimeStyle:
        // A source and a layer added the ordinary way, then a property changed
        // AFTER the add — that recolour is what proves the snapshot is the live
        // state rather than a replay of the original addLayer call.
        layers
          ..addSource(
            'retain-src',
            GeoJsonSource(
              data: GeoJsonData.featureCollection(
                const GeoJsonFeatureCollection([
                  GeoJsonFeature(geometry: GeoJsonPoint(_turku)),
                  GeoJsonFeature(geometry: GeoJsonPoint(_stockholm)),
                  GeoJsonFeature(geometry: GeoJsonPoint(_london)),
                ]),
              ),
            ),
          )
          ..addLayer(
            const CircleLayer(
              id: 'retain-dots',
              source: 'retain-src',
              circleRadius: StyleValue(9),
              circleColor: StyleValue(Color(0xFF2196F3)),
            ),
          )
          // AFTER the add, on purpose: a replay of the original addLayer call
          // would lose this, so red-not-blue after a style swap is the proof
          // that the snapshot is the layer's LIVE state.
          ..setPaintProperty(
            'retain-dots',
            'circle-color',
            const Color(0xFFE53935),
          );
        _teardown.add(() {
          layers
            ..removeLayer('retain-dots')
            ..removeSource('retain-src');
        });

      case Scenario.styleForms:
        // The scenario OWNS the style while it is on screen, so entering it
        // pushes the current form and leaving it restores the default. Setting
        // it to the value it already holds is a no-op: MapLibreMap only pushes
        // a style when the property actually changed, so the reload this very
        // callback came from does not start another one.
        setState(() => _style = _styleForms[_styleFormIndex].$2);
        _teardown.add(() => setState(() => _style = _demotiles));

      case Scenario.models3d:
        await _placeModel();

      case Scenario.models3dStress:
        await _placeModel();
        await _startStress();

      case Scenario.engineIcons:
        await _applyEngineIcons();

      case Scenario.engineIconsFlat:
        await _applyEngineIconsFlat();

      case Scenario.hybrid:
        _teardown.add(() => layers.removeCircleLayersFromPoints('bulk'));
        layers.addCircleLayersFromPoints(
          'bulk',
          _dataset(_engineCounts[_engineCountIndex]),
          cluster: true,
          radius: 4,
          clusterTextFont: _safeFont,
        );
        // Driven by the camera, not a timer: re-query exactly when the view
        // changed. Throttled, because each query is a round trip to the render
        // thread and the camera ticks at frame rate.
        _controller.onCameraChanged?.addListener(_onCameraChangedForHybrid);
        _refreshLiveWidgets();
    }
  }

  /// Typed GeoJSON on the way in, typed features on the way out.
  ///
  /// Everything the engine draws here is built from the value types in
  /// `package:maplibre_flutter/geojson.dart` — a [GeoJsonPolygon], a
  /// [GeoJsonLineString] and three [GeoJsonPoint]s, each wrapped in a
  /// [GeoJsonFeature] with an `id` and `properties`, collected into a
  /// [GeoJsonFeatureCollection] and handed over as
  /// `GeoJsonData.featureCollection(...)`. No JSON string is written anywhere,
  /// and the `[lng, lat]` flip happens once, inside the types.
  void _applyGeoJsonFeatures() {
    final layers = _controller.style;
    _teardown.add(() {
      layers
        ..removeCircleLayersFromPoints('gj-sensors')
        ..removeLayer('gj-buoys-dots')
        ..removeSource('gj-buoys')
        ..removeLayer('gj-cities-labels')
        ..removeLayer('gj-cities-dots')
        ..removeLayer('gj-route-line')
        ..removeLayer('gj-region-fill')
        ..removeSource('gj-cities')
        ..removeSource('gj-route')
        ..removeSource('gj-region');
      setState(() {
        _tapped = const [];
        _tappedAt = null;
      });
    });

    // An asymmetric region: it must be obvious which corner is which, so a
    // mirrored axis would be visible rather than hiding behind symmetry.
    const region = GeoJsonFeature(
      id: 'gulf-of-bothnia',
      geometry: GeoJsonPolygon([
        [
          LatLng(60.0, 18.0),
          LatLng(60.0, 25.0),
          LatLng(66.0, 25.0),
          LatLng(66.0, 18.0),
          LatLng(60.0, 18.0),
        ],
      ]),
      properties: {'name': 'Gulf of Bothnia', 'kind': 'region'},
    );

    const route = GeoJsonFeature(
      id: 'route-e18',
      geometry: GeoJsonLineString([_stockholm, _turku, LatLng(62.24, 25.75)]),
      properties: {'name': 'Stockholm to Jyvaskyla', 'kind': 'route'},
    );

    final cities = <GeoJsonFeature>[
      const GeoJsonFeature(
        id: 'city-turku',
        geometry: GeoJsonPoint(_turku),
        properties: {'name': 'Turku', 'kind': 'city', 'population': 200000},
      ),
      const GeoJsonFeature(
        id: 'city-stockholm',
        geometry: GeoJsonPoint(_stockholm),
        properties: {'name': 'Stockholm', 'kind': 'city', 'population': 980000},
      ),
      const GeoJsonFeature(
        id: 'city-jyvaskyla',
        geometry: GeoJsonPoint(LatLng(62.24, 25.75)),
        properties: {'name': 'Jyvaskyla', 'kind': 'city', 'population': 145000},
      ),
    ];

    // One source per geometry family, because a fill, a line and a circle layer
    // want different data — but all three from the same typed constructors.
    layers
      ..addSource('gj-region', GeoJsonSource(data: GeoJsonData.feature(region)))
      ..addSource('gj-route', GeoJsonSource(data: GeoJsonData.feature(route)))
      ..addSource(
        'gj-cities',
        GeoJsonSource(
          data: GeoJsonData.featureCollection(GeoJsonFeatureCollection(cities)),
        ),
      )
      ..addLayer(
        const FillLayer(
          id: 'gj-region-fill',
          source: 'gj-region',
          fillColor: StyleValue(Color(0xFF7E57C2)),
          fillOpacity: StyleValue(0.25),
          fillOutlineColor: StyleValue(Color(0xFF4527A0)),
        ),
      )
      ..addLayer(
        const LineLayer(
          id: 'gj-route-line',
          source: 'gj-route',
          lineColor: StyleValue(Color(0xFFEF6C00)),
          lineWidth: StyleValue(4),
          lineCap: StyleValue(LineCap.round),
          lineJoin: StyleValue(LineJoin.round),
        ),
      )
      // Radius driven by a property that came in through the typed feature —
      // data-driven styling with the data authored in Dart.
      ..addLayer(
        CircleLayer(
          id: 'gj-cities-dots',
          source: 'gj-cities',
          // Radius from a property that came in through the typed feature —
          // data-driven styling with the data authored in Dart, not JSON.
          circleRadius: Expr.interpolate(
            Expr.raw(['linear']),
            Expr.get('population'),
            145000,
            7,
            980000,
            18,
          ),
          circleColor: const StyleValue(Color(0xFF00897B)),
          circleStrokeWidth: const StyleValue(2),
          circleStrokeColor: const StyleValue(Color(0xFFFFFFFF)),
        ),
      );
    // A MULTI geometry, to show the sealed hierarchy is complete and that
    // multi-part features round-trip as well as simple ones.
    layers
      ..addSource(
        'gj-buoys',
        GeoJsonSource(
          data: GeoJsonData.feature(
            const GeoJsonFeature(
              id: 'buoys',
              geometry: GeoJsonMultiPoint([
                LatLng(61.0, 20.0),
                LatLng(62.5, 21.0),
                LatLng(64.0, 22.5),
              ]),
              properties: {'name': 'Channel buoys', 'kind': 'buoy'},
            ),
          ),
        ),
      )
      ..addLayer(
        const CircleLayer(
          id: 'gj-buoys-dots',
          source: 'gj-buoys',
          circleRadius: StyleValue(5),
          circleColor: StyleValue(Color(0xFFFDD835)),
          circleStrokeWidth: StyleValue(1),
          circleStrokeColor: StyleValue(Color(0xFF616161)),
        ),
      );

    // And the OTHER way of getting per-point properties in: addPoints now takes
    // them, so a recipe-built layer can carry data-driven attributes too. Query
    // one of these and its properties come back with it.
    layers.addCircleLayersFromPoints(
      'gj-sensors',
      const [LatLng(63.0, 19.5), LatLng(65.0, 24.0)],
      properties: const [
        {'name': 'Sensor A', 'kind': 'sensor', 'reading': 4.2},
        {'name': 'Sensor B', 'kind': 'sensor', 'reading': 7.9},
      ],
      radius: 6,
      color: const Color(0xFFD81B60),
    );

    layers.addLayer(
      SymbolLayer(
        id: 'gj-cities-labels',
        source: 'gj-cities',
        textField: Expr.get('name'),
        textFont: const StyleValue(_safeFont),
        textSize: const StyleValue(12),
        textAnchor: const StyleValue(TextAnchor.top),
        textOffset: const StyleValue([0, 1.2]),
        textColor: const StyleValue(Color(0xFF004D40)),
        textHaloColor: const StyleValue(Color(0xFFFFFFFF)),
        textHaloWidth: const StyleValue(1.5),
      ),
    );
  }

  /// What the engine actually drew under a tap.
  ///
  /// The whole point of this handler is what comes BACK: a
  /// [QueriedFeature] per hit, carrying the full [GeoJsonFeature.geometry] and
  /// the feature [GeoJsonFeature.id]. Tapping the shaded region returns a
  /// polygon and tapping the route returns a line — both of which a query used
  /// to answer with nothing at all, because the decoder kept only points.
  /// The tap carries the SCREEN point as well as the geographic one, which is
  /// what makes this two lines. It used to need a [Listener] wrapped around the
  /// map recording every pointer-down by hand, because `onTap` reported only
  /// the unprojected [LatLng] and there was no public `project`.
  void _queryAtTap(MapTapEvent tap) {
    if (!_controller.capabilities.styleLayers) return;
    // queryRenderedFeaturesAt pads the point into a box: a four-pixel line is
    // hard to hit dead-on with a finger.
    final found = _controller.style.queryRenderedFeaturesAt(
      tap.screenPoint,
      tolerance: 12,
    );
    setState(() {
      _tappedAt = tap.point;
      _tapped = found;
    });
  }

  /// The typed style API, used the way an app would use it.
  ///
  /// Nothing here is a JSON string and nothing goes through `addPoints`: the
  /// source, all three layers, the enums and every expression are the classes
  /// generated from the MapLibre Style Spec vendored in this repo
  /// (`maplibre_flutter/tool/generate_style_api.dart`). Compare with
  /// [_applyEngineIconsFlat] before this existed — the same document was a
  /// nested pile of maps.
  void _applyTypedStyle() {
    final layers = _controller.style;
    // Layers before sources: mbgl refuses to remove a source a layer still
    // references, and now says so out loud.
    _teardown.add(() {
      layers
        ..removeLayer('typed-labels')
        ..removeLayer('typed-circles')
        ..removeLayer('typed-route')
        ..removeSource('typed')
        ..removeSource('typed-route');
    });

    // Per-point properties are what make data-driven styling possible: the
    // expressions below read `kind` and `pop` off each feature.
    layers.addSource(
      'typed',
      GeoJsonSource(
        data: GeoJsonData.points(
          [for (final c in _showcase) c.$2],
          properties: [
            for (final c in _showcase)
              {'name': c.$1, 'kind': c.$3, 'pop': c.$4},
          ],
        ),
      ),
    );

    // A dashed route through the same cities, from an inline LineString.
    layers.addSource(
      'typed-route',
      GeoJsonSource(
        data: GeoJsonData.lineThrough([for (final c in _showcase) c.$2]),
      ),
    );
    layers.addLayer(
      LineLayer(
        id: 'typed-route',
        source: 'typed-route',
        // Enums, not strings: the spec's `line-cap` / `line-join` values.
        lineCap: const StyleValue(LineCap.round),
        lineJoin: const StyleValue(LineJoin.round),
        lineColor: const StyleValue(Color(0xFF5E35B1)),
        lineOpacity: const StyleValue(0.8),
        // Thickens as you zoom in: interpolate over ["zoom"].
        lineWidth: Expr.interpolate(
          Expr.raw(['linear']),
          Expr.zoom(),
          4,
          1.5,
          10,
          5,
        ),
        lineDasharray: const StyleValue([2, 1.5]),
      ),
    );

    layers.addLayer(
      CircleLayer(
        id: 'typed-circles',
        source: 'typed',
        // Colour BY CATEGORY, evaluated in the engine per feature. Colours are
        // real dart:ui Colors even inside the expression.
        circleColor: Expr.match(
          Expr.get('kind'),
          'capital',
          const Color(0xFFD81B60),
          'coastal',
          const Color(0xFF1E88E5),
          const Color(0xFF43A047), // fallback: inland
        ),
        // Radius BY POPULATION, interpolated between two stops.
        circleRadius: Expr.interpolate(
          Expr.raw(['linear']),
          Expr.get('pop'),
          60,
          6,
          650,
          26,
        ),
        circleOpacity: const StyleValue(0.85),
        circleStrokeWidth: const StyleValue(2),
        circleStrokeColor: const StyleValue(Color(0xFFFFFFFF)),
      ),
    );

    layers.addLayer(
      SymbolLayer(
        id: 'typed-labels',
        source: 'typed',
        // `text-field` is a data expression too, so the label is per feature.
        textField: Expr.get('name'),
        textFont: const StyleValue(_safeFont),
        textSize: Expr.interpolate(
          Expr.raw(['linear']),
          Expr.zoom(),
          4,
          11,
          9,
          15,
        ),
        textAnchor: const StyleValue(TextAnchor.top),
        textOffset: const StyleValue([0, 1.1]),
        textAllowOverlap: const StyleValue(true),
        textColor: const StyleValue(Color(0xFF12232E)),
        // A halo keeps labels readable over both styles' basemaps.
        textHaloColor: const StyleValue(Color(0xFFFFFFFF)),
        textHaloWidth: const StyleValue(1.5),
      ),
    );
  }

  /// Cities for the typed-API scenario: (name, point, category, population/1000).
  ///
  /// Categories and magnitudes exist so the layer can be styled FROM THE DATA
  /// rather than hard-coded per point.
  static const _showcase = <(String, LatLng, String, int)>[
    ('Helsinki', LatLng(60.1699, 24.9384), 'capital', 632),
    ('Espoo', LatLng(60.2055, 24.6559), 'coastal', 300),
    ('Turku', _turku, 'coastal', 195),
    ('Tampere', LatLng(61.4978, 23.7610), 'inland', 244),
    ('Jyväskylä', LatLng(62.2426, 25.7473), 'inland', 144),
    ('Vaasa', LatLng(63.0951, 21.6165), 'coastal', 67),
    ('Kuopio', LatLng(62.8924, 27.6770), 'inland', 121),
    ('Oulu', LatLng(65.0121, 25.4651), 'coastal', 209),
    ('Rovaniemi', LatLng(66.5039, 25.7294), 'inland', 64),
  ];

  /// Registers the widget-derived icon used by both icon scenarios.
  ///
  /// Returns false if the widget went away mid-rasterize (it is async).
  Future<bool> _registerWidgetIcon() async {
    await _controller.style.addWidgetIcon(
      'bulk-pin',
      const _IconFrame(child: _FancyMarker()),
      // A generous CAP, not a demand: the widget lays out loose and the icon
      // comes out at its natural size. Too small a cap is what cropped the
      // label before — as did wrapping it in a Center, which expands to fill
      // whatever it is given.
      size: const Size(240, 120),
    );
    return mounted;
  }

  /// Engine icons, UNCLUSTERED: the widget-derived icon at every single point.
  ///
  /// Raw symbol throughput with nothing hidden by clustering. At 50k and world
  /// zoom this is deliberately a solid mass — that is the honest picture of
  /// what "an icon per point" means, and the reason the clustered variant
  /// exists next to it.
  Future<void> _applyEngineIconsFlat() async {
    if (!await _registerWidgetIcon()) return;
    final layers = _controller.style;
    _teardown.add(() {
      layers
        ..removeLayer('bulk-icons')
        ..removeSource('bulk');
    });
    layers
      ..addSource(
        'bulk',
        GeoJsonSource(
          data: GeoJsonData.points(_dataset(_engineCounts[_engineCountIndex])),
        ),
      )
      ..addLayer(
        const SymbolLayer(
          id: 'bulk-icons',
          source: 'bulk',
          iconImage: StyleValue('bulk-pin'),
          // Without this the engine hides colliding labels, which would look
          // like the icons "not all rendering" rather than the intended
          // every-point picture.
          iconAllowOverlap: StyleValue(true),
        ),
      );
  }

  /// Engine icons: a rasterized Flutter widget as `icon-image`.
  ///
  /// Clustered like the circle scenario — an unclustered 50k icon layer with
  /// allow-overlap paints a solid mass at world view, which is useless to look
  /// at. Cluster bubbles carry the counts; leaves appear as you zoom in.
  Future<void> _applyEngineIcons() async {
    if (!await _registerWidgetIcon()) return;
    final layers = _controller.style;
    _teardown.add(() {
      layers
        ..removeLayer('bulk-icons')
        ..removeCircleLayersFromPoints('bulk');
    });
    layers.addCircleLayersFromPoints(
      'bulk',
      _dataset(_engineCounts[_engineCountIndex]),
      cluster: true,
      radius: 4,
      clusterTextFont: _safeFont,
    );
    // Leaves (non-cluster features) drawn with the widget-derived icon, on top
    // of the plain circles addPoints made for them.
    layers.addLayer(
      SymbolLayer(
        id: 'bulk-icons',
        source: 'bulk',
        filter: Expr.not(Expr.has('point_count')),
        iconImage: const StyleValue('bulk-pin'),
        iconAllowOverlap: const StyleValue(true),
      ),
    );
  }

  /// Hybrid: ask the ENGINE what it drew in the viewport, and wrap each of those
  /// features in a real, animated Flutter widget.
  ///
  /// This is why it uses queryRenderedFeatures rather than filtering the source
  /// list in Dart: on a clustered source the engine returns the CLUSTERS it
  /// created — position and `point_count` — which Dart cannot recompute without
  /// reimplementing supercluster. So zoomed out you get a few animated cluster
  /// bubbles; zoomed in, individual animated pins. The full 50k never leaves the
  /// engine, so the widget count stays tiny no matter how large the dataset is.
  /// Throttle: at most ~10 queries a second while the camera moves, plus one
  /// trailing query so the final resting view is always correct.
  DateTime _lastQuery = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _trailingQuery;

  void _onCameraChangedForHybrid() {
    final now = DateTime.now();
    if (now.difference(_lastQuery) > const Duration(milliseconds: 100)) {
      _lastQuery = now;
      _refreshLiveWidgets();
    }
    _trailingQuery?.cancel();
    _trailingQuery = Timer(
      const Duration(milliseconds: 150),
      _refreshLiveWidgets,
    );
  }

  void _refreshLiveWidgets() {
    if (!mounted || _scenario != Scenario.hybrid) return;
    final size = MediaQuery.sizeOf(context);
    final found = _controller.queryRenderedFeatures(
      Offset.zero & size,
      // Only our own layers — otherwise every basemap road comes back too.
      layerIds: const ['bulk-clusters', 'bulk-points'],
    );
    // Cap purely as a safety net; clustering already keeps this small.
    final capped = found.length > 250 ? found.sublist(0, 250) : found;
    if (!mounted) return;
    setState(() => _liveFeatures = capped);
  }

  // --- Camera / style ---------------------------------------------------------

  // --- 3D models --------------------------------------------------------------

  /// The engine opens a real filesystem path natively and knows nothing about
  /// Flutter's asset bundle, so the asset is copied to a temp file once and that
  /// path is handed over. Under the sandbox this lands inside the app container,
  /// which is readable without any entitlement.
  /// Null on web, which has no filesystem — the caller reports that rather
  /// than trying a path the engine could never open.
  Future<String?> _resolveModelPath() async {
    if (_modelPath.isNotEmpty) return _modelPath;
    final cached = _resolvedAssets[_demoAsset];
    if (cached != null && modelFileExists(cached)) return cached;

    final bytes = await rootBundle.load(_demoAsset);
    final path = await writeModelToTemp(_demoAsset, bytes.buffer.asUint8List());
    if (path == null) return null;
    _resolvedAssets[_demoAsset] = path;
    return path;
  }

  /// Places the demo model and frames it: a car-sized object needs street-level
  /// zoom and some pitch before it reads as 3D at all.
  Future<void> _placeModel() async {
    if (_modelAdded) return;
    final String? assetPath;
    try {
      assetPath = await _resolveModelPath();
    } catch (e) {
      setState(() => _modelError = 'could not read model: $e');
      return;
    }
    if (assetPath == null) {
      setState(
        () => _modelError =
            '3D models need a filesystem path the engine can open, which the '
            'web tier does not have (see docs/decision-log.md)',
      );
      return;
    }

    // Use wherever the user is already looking if it is close enough to see a
    // car-sized object; otherwise go to a known street-level site.
    final current = await _controller.camera.getCamera();
    final zoomedIn = current.zoom >= 15;
    final site = zoomedIn ? current.center : _modelSite;
    // easeTo, not the old move(duration:) — that one FLEW, arcing out and back
    // in, which for an 800 ms hop to a street-level site read as a glitch. An
    // eased straight line had no API at all before this.
    await _controller.camera.easeTo(
      CameraOptions(
        center: site,
        zoom: zoomedIn && current.zoom >= 19 ? current.zoom : 20,
        bearing: current.bearing,
        pitch: current.pitch < 30 ? 60 : current.pitch,
      ),
      duration: const Duration(milliseconds: 800),
    );
    try {
      // ignore: experimental_member_use
      _controller.addModel(
        MapLibreModel(
          id: 'demo-model',
          assetPath: assetPath,
          point: site,
          scale: _modelScale,
          headingDegrees: _modelHeading,
          elevationMetres: _modelElevation,
        ),
      );
      _modelAnchor = site;
      if (!mounted) return;
      setState(() {
        _modelAdded = true;
        _modelError = null;
      });
    } on ArgumentError catch (e) {
      if (!mounted) return;
      setState(() => _modelError = '${e.message}');
    }
  }

  void _removeModel() {
    if (!_modelAdded) return;
    // ignore: experimental_member_use
    _controller.removeModel('demo-model');
    _modelAdded = false;
    _modelError = null;
  }

  Future<void> _toggleDriving() async {
    if (_driving) {
      _stopDriving();
      return;
    }
    if (!_modelAdded) return;

    final centre = _modelAnchor;
    // Frame the whole loop, else most of it happens off-screen and the car just
    // crosses the view while yawing.
    final camera = await _controller.camera.getCamera();
    if (camera.zoom > _driveZoom) {
      await _controller.camera.easeTo(
        CameraOptions(center: centre, zoom: _driveZoom),
        duration: const Duration(milliseconds: 700),
      );
    }

    final startedAt = DateTime.now();
    // Metres -> degrees. Longitude degrees shrink with latitude, so scale by
    // cos(lat) or the circle comes out as an ellipse.
    const latPerMetre = 1 / 111320.0;
    final lngPerMetre =
        1 / (111320.0 * math.cos(centre.latitude * math.pi / 180));

    _driveTicker = Ticker((_) {
      final t = DateTime.now().difference(startedAt).inMilliseconds / 1000.0;
      final theta = 2 * math.pi * (t / _drivePeriodSeconds);
      final point = LatLng(
        centre.latitude + _driveRadiusMetres * latPerMetre * math.cos(theta),
        centre.longitude + _driveRadiusMetres * lngPerMetre * math.sin(theta),
      );
      // Face along the tangent of travel. Bearing is clockwise from north, and
      // the model's own forward offset (_modelHeading) still applies.
      final tangentBearing = (theta * 180 / math.pi + 90) % 360;
      // ignore: experimental_member_use
      _controller.updateModel(
        MapLibreModel(
          id: 'demo-model',
          assetPath: _resolvedAssets[_demoAsset] ?? _modelPath,
          point: point,
          scale: _modelScale,
          headingDegrees: _modelHeading + tangentBearing,
          elevationMetres: _modelElevation,
        ),
      );
    })..start();
    setState(() => _driving = true);
  }

  void _stopDriving() {
    _driveTicker
      ?..stop()
      ..dispose();
    _driveTicker = null;
    if (_driving && mounted) setState(() => _driving = false);
  }

  /// Starts the wandering field: N models each moving its own way, with the HUD
  /// reporting what it costs.
  Future<void> _startStress() async {
    if (_stressing) return;
    final String? assetPath;
    try {
      assetPath = await _resolveModelPath();
    } catch (e) {
      setState(() => _modelError = 'could not read model: $e');
      return;
    }
    if (assetPath == null) {
      setState(
        () => _modelError =
            '3D models need a filesystem path the engine can open, which the '
            'web tier does not have (see docs/decision-log.md)',
      );
      return;
    }
    // Bound to a non-nullable local: the null promotion above does not reach
    // inside the setState closure below.
    final glbPath = assetPath;

    final centre = _modelAnchor;
    // Pull back far enough that the whole field is in view, else most of the
    // models are off-screen and the number on screen means nothing.
    // No read-modify-write: a partial camera says "these three fields, leave
    // the rest", which also cannot race the render thread the way an
    // await-then-copyWith could.
    await _controller.camera.easeTo(
      CameraOptions(center: centre, zoom: 17, pitch: 55),
      duration: const Duration(milliseconds: 700),
    );

    _stressAsset = assetPath;
    _stressCentre = centre;
    _wanderers.clear();
    _spawnCars(_stressCount, assetPath, centre);

    const latPerMetre = 1 / 111320.0;
    final lngPerMetre =
        1 / (111320.0 * math.cos(centre.latitude * math.pi / 180));

    _stressFrames = 0;
    _stressLastReport = Duration.zero;
    _stressWorstMs = 0;
    // ignore: experimental_member_use
    _lastRenderedFrames = _controller.renderedFrameCount ?? 0;
    var worst = 0.0;
    var last = Duration.zero;
    _stressTicker = Ticker((elapsed) {
      final dt = last == Duration.zero
          ? 0.0
          : (elapsed - last).inMicroseconds / 1e6;
      // Track the WORST frame as well as the mean: an average hides the stalls
      // that actually read as jank.
      if (dt > 0) worst = math.max(worst, dt * 1000);
      last = elapsed;

      final centreNow = _stressCentre ?? centre;
      for (final w in List<_Wanderer>.of(_wanderers)) {
        w.advance(dt, _stressFieldMetres);
        // ignore: experimental_member_use
        _controller.updateModel(
          MapLibreModel(
            id: w.id,
            assetPath: glbPath,
            point: LatLng(
              centreNow.latitude + w.y * latPerMetre,
              centreNow.longitude + w.x * lngPerMetre,
            ),
            scale: _modelScale,
            headingDegrees: _modelHeading + w.bearing,
            elevationMetres: _modelElevation,
          ),
        );
      }

      _stressFrames++;
      if (elapsed - _stressLastReport > const Duration(seconds: 1)) {
        final secs = (elapsed - _stressLastReport).inMicroseconds / 1e6;
        // ignore: experimental_member_use
        final rendered = _controller.renderedFrameCount ?? 0;
        final mapFrames = rendered - _lastRenderedFrames;
        _lastRenderedFrames = rendered;
        setState(() {
          _stressFps = _stressFrames / secs;
          _stressWorstMs = worst;
          _mapFps = mapFrames / secs;
        });
        worst = 0;
        _stressFrames = 0;
        _stressLastReport = elapsed;
      }
    })..start();

    if (!mounted) return;
    setState(() {
      _stressing = true;
      _modelError = null;
      // Parts per model comes from the core's own count, so the draw-call figure
      // reflects what is actually submitted rather than a guess.
      // ignore: experimental_member_use
      _partsPerModel = _controller.modelPartCount(glbPath) ?? 0;
    });
  }

  void _stopStress() {
    if (!_stressing) return;
    _stressTicker
      ?..stop()
      ..dispose();
    _stressTicker = null;
    for (final w in _wanderers) {
      // ignore: experimental_member_use
      _controller.removeModel(w.id);
    }
    _wanderers.clear();
    _stressing = false;
    _stressFps = 0;
  }

  /// Adds or removes cars WITHOUT restarting the field.
  ///
  /// Respawning everything would re-add every model and reset the wanderers,
  /// which is both slower and a worse measurement — the interesting number is how
  /// the frame time moves as cars are added to a RUNNING scene.
  Future<void> _changeCars(int delta) async {
    if (!_stressing) {
      if (delta > 0) await _startStress();
      return;
    }
    final asset = _stressAsset;
    final centre = _stressCentre;
    if (asset == null || centre == null) return;

    if (delta > 0) {
      _spawnCars(delta, asset, centre);
    } else {
      final n = math.min(-delta, _wanderers.length - 1); // keep at least one
      for (var i = 0; i < n; i++) {
        final w = _wanderers.removeLast();
        // ignore: experimental_member_use
        _controller.removeModel(w.id);
      }
    }
    setState(() => _stressCount = _wanderers.length);
  }

  /// Appends [n] wanderers and adds a model for each. Only the new ones are
  /// touched; existing cars keep moving.
  void _spawnCars(int n, String assetPath, LatLng centre) {
    const latPerMetre = 1 / 111320.0;
    final lngPerMetre =
        1 / (111320.0 * math.cos(centre.latitude * math.pi / 180));

    for (var i = 0; i < n; i++) {
      final w = _Wanderer(
        id: 'stress-${_stressNextId++}',
        x: (_stressRng.nextDouble() - 0.5) * _stressFieldMetres,
        y: (_stressRng.nextDouble() - 0.5) * _stressFieldMetres,
        bearing: _stressRng.nextDouble() * 360,
        speed: 6 + _stressRng.nextDouble() * 14,
        turnRate: (_stressRng.nextDouble() - 0.5) * 30,
      );
      _wanderers.add(w);
      try {
        // ignore: experimental_member_use
        _controller.addModel(
          MapLibreModel(
            id: w.id,
            assetPath: assetPath,
            point: LatLng(
              centre.latitude + w.y * latPerMetre,
              centre.longitude + w.x * lngPerMetre,
            ),
            scale: _modelScale,
            headingDegrees: _modelHeading + w.bearing,
            elevationMetres: _modelElevation,
          ),
        );
      } on ArgumentError catch (e) {
        setState(() => _modelError = '${e.message}');
        return;
      }
    }
  }

  /// Swaps car <-> box and rebuilds whatever the scenario had running.
  Future<void> _swapModel() async {
    final wasStressing = _stressing;
    final count = _wanderers.length;
    _stopStress();
    _stopDriving();
    _removeModel();
    setState(() {
      _demoAsset = _demoAsset == _carAsset ? _boxAsset : _carAsset;
      if (count != 0) _stressCount = count;
    });
    await _placeModel();
    if (wasStressing) await _startStress();
  }

  /// Turns the map [degrees] CLOCKWISE (to the right) — so the argument reads the
  /// way the button is labelled.
  ///
  /// That means SUBTRACTING from the bearing, which is the counter-intuitive
  /// part. Bearing is the compass direction that is "up", so raising it swings
  /// the camera clockwise and the ground therefore appears to swing
  /// anti-clockwise. Measured, not assumed: at bearing 0 a point 1° due north of
  /// centre projects to (128.0, 82.5) in a 256 px view; at bearing 45 it projects
  /// to (95.8, 95.8) — left and down, i.e. the content rotated anti-clockwise.
  /// Passing the delta straight through is what made these buttons mirrored.
  ///
  /// Trackpad rotate gestures are not wired on the desktop tier yet, so this is
  /// the only way to get a bearing at all.
  Future<void> _rotateBy(double degrees) async {
    final camera = await _controller.camera.getCamera();
    var bearing = (camera.bearing - degrees) % 360;
    if (bearing < 0) bearing += 360;
    // gl-js `rotateTo`. Pass `around:` to turn about a screen point instead of
    // the centre — but never alongside a centre, which mbgl would let win.
    await _controller.camera.rotateTo(
      bearing,
      duration: const Duration(milliseconds: 400),
    );
  }

  /// Cycles pitch rather than only increasing it. mbgl clamps pitch to
  /// DEFAULT_PITCH_MAX = 60 degrees (util/constants.hpp), and placing a model
  /// already sets 60, so an "increase" button had nothing left to do and looked
  /// broken.
  static const List<double> _pitchSteps = [0, 30, 60];

  Future<void> _cyclePitch() async {
    final camera = await _controller.camera.getCamera();
    var next = _pitchSteps.first;
    for (var i = 0; i < _pitchSteps.length; i++) {
      if (camera.pitch < _pitchSteps[i] - 1) {
        next = _pitchSteps[i];
        break;
      }
      next = _pitchSteps[(i + 1) % _pitchSteps.length];
    }
    await _controller.camera.easeTo(
      CameraOptions(pitch: next),
      duration: const Duration(milliseconds: 400),
    );
  }

  /// gl-js `zoomIn` / `zoomOut` — one level, eased, no read-modify-write.
  Future<void> _zoomBy(double delta) async {
    const duration = Duration(milliseconds: 300);
    if (delta > 0) {
      await _controller.camera.zoomIn(duration: duration);
    } else {
      await _controller.camera.zoomOut(duration: duration);
    }
  }

  Future<void> _flyToNextPlace() async {
    final (_, center, zoom) = _places[_placeIndex];
    _placeIndex = (_placeIndex + 1) % _places.length;
    // A real engine-native flyTo — the van Wijk arc mbgl computes itself,
    // replacing the Dart-side arc this app used to step. The Future completes
    // when the flight ENDS, and a superseding move completes it too rather than
    // leaving it hanging, which is what makes awaiting it safe.
    await _controller.camera.flyTo(
      CameraOptions(center: center, zoom: zoom),
      duration: const Duration(milliseconds: 2000),
    );
  }

  Future<void> _toggleStyle() async {
    // Just swap the declarative property. Re-applying the scenario is
    // [_onStyleLoaded]'s job, because only the engine knows when the new
    // document is actually in.
    setState(() => _style = _style == _demotiles ? _liberty : _demotiles);
  }

  /// Cycles the styleForms scenario through URL, inline document and asset.
  void _nextStyleForm() {
    setState(() {
      _styleFormIndex = (_styleFormIndex + 1) % _styleForms.length;
      _style = _styleForms[_styleFormIndex].$2;
    });
  }

  /// Re-applies the scenario every time a style finishes loading.
  ///
  /// mbgl REPLACES the whole layer list on a style load, so every source, layer
  /// and image this app added is gone the moment [_style] changes — and
  /// `MapLibreMap.style` is declarative, so that can happen on any rebuild.
  /// This callback is the only correct moment to put them back.
  ///
  /// It replaced `await Future.delayed(700ms)`, which was a guess: too short and
  /// the layers were added to the outgoing style and lost, too long and the map
  /// sat empty. Widget markers are unaffected either way — they live in Flutter,
  /// not in the style document.
  void _onStyleLoaded() {
    if (!mounted) return;
    setState(() => _styleLoadCount++);
    _logDiagnostic('style loaded (#$_styleLoadCount) — re-applying scenario');
    unawaited(_applyScenario());
  }

  // --- Markers ----------------------------------------------------------------

  List<MapLibreMarker> _buildMarkers() {
    switch (_scenario) {
      case Scenario.interaction:
        return [
          MapLibreMarker(
            point: _london,
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () => ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Tapped London'))),
              child: const Icon(Icons.location_on, color: Colors.red, size: 40),
            ),
          ),
          MapLibreMarker(
            point: _draggable,
            alignment: Alignment.bottomCenter,
            draggable: true,
            onDragUpdate: (p) => setState(() => _draggable = p),
            onDragEnd: (p) => setState(() => _draggable = p),
            child: const Icon(Icons.push_pin, color: Colors.indigo, size: 40),
          ),
          const MapLibreMarker(point: _stockholm, child: _PulsingMarker()),
          for (final p in _dropped)
            MapLibreMarker(
              point: p,
              child: const Icon(Icons.circle, color: Colors.green, size: 16),
            ),
        ];

      case Scenario.widgetMarkers:
        return [
          for (final p in _widgetPoints)
            MapLibreMarker(
              point: p,
              repaintBoundary: _repaintBoundaries,
              child: _fancyMarkers ? const _FancyMarker() : const _Dot(),
            ),
        ];

      case Scenario.hybrid:
        // Animated widgets, but only for what is on screen.
        return [
          // `point` is null for a line or polygon feature; these layers only
          // ever draw points, so anything else is not ours to promote.
          for (final f in _liveFeatures)
            if (f.point case final point?)
              MapLibreMarker(
                point: point,
                // Clusters become animated bubbles carrying the engine's own
                // point_count; single points become animated pins.
                child: f.isCluster
                    ? _PulsingCluster(count: f.pointCount)
                    : const _PulsingMarker(),
              ),
        ];

      case Scenario.enginePoints:
      case Scenario.engineClusters:
      case Scenario.engineIcons:
      case Scenario.engineIconsFlat:
      // Everything in these is drawn by the engine from the typed style.
      case Scenario.typedStyle:
      case Scenario.geojsonFeatures:
      case Scenario.cameraVerbs:
      case Scenario.cameraConstraints:
      case Scenario.diagnostics:
      case Scenario.capabilities:
      case Scenario.styleForms:
      case Scenario.retainRuntimeStyle:
      // And these are drawn by the engine from a .glb.
      case Scenario.models3d:
      case Scenario.models3dStress:
        return const [];
    }
  }

  /// A live readout of WHY the camera is moving.
  ///
  /// Drag, pinch, twist and shove the map and watch this change. mbgl cannot
  /// tell these apart — its `CameraChangeMode` is only `{Immediate, Animated}`
  /// — so every value here is synthesised by the Dart gesture layer. A twisting
  /// pinch shows two reasons at once, which is why the payload is a Set.
  Widget _reasonBadge() {
    final gesture = _moveReasons.isGesture;
    return PointerInterceptor(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: (gesture ? Colors.teal : Colors.indigo).withValues(
            alpha: 0.85,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white, fontSize: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                gesture ? 'moving: user' : 'moving: app',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(_moveReasons.map((r) => r.name).join(' + ')),
              Text(
                'zoom ${_moveReasons.isZoom} · rotate ${_moveReasons.isRotation}'
                ' · tilt ${_moveReasons.isTilt}',
                style: const TextStyle(fontSize: 10, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// What the last tap found, straight off [QueriedFeature].
  ///
  /// Every line here is something the old query result could not carry: the
  /// geometry type (non-points were dropped outright), the feature id (parsed
  /// and thrown away), and the properties of a fill or line feature (which
  /// never arrived at all).
  Widget _queryResultPanel() {
    final at = _tappedAt;
    return PointerInterceptor(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white, fontSize: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'queryRenderedFeatures',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              if (at == null)
                const Text('Tap the map — the region and the route answer too.')
              else ...[
                Text(
                  'at ${at.latitude.toStringAsFixed(3)}, '
                  '${at.longitude.toStringAsFixed(3)}',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 4),
                if (_tapped.isEmpty)
                  const Text('nothing drawn here')
                else
                  for (final feature in _tapped.take(4))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${feature.geometry?.type ?? "no geometry"}'
                            '  id: ${feature.id ?? "—"}',
                            style: const TextStyle(
                              color: Colors.tealAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            feature.properties.isEmpty
                                ? '(no properties)'
                                : feature.properties.entries
                                      .map((e) => '${e.key}: ${e.value}')
                                      .join('  ·  '),
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                if (_tapped.length > 4)
                  Text(
                    '+ ${_tapped.length - 4} more',
                    style: const TextStyle(color: Colors.white54),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Live engine reports: `controller.onError`, `onStyleLoaded` and
  /// `onStyleImageMissing`.
  ///
  /// Before this channel existed every one of these was a blank or half-drawn
  /// map and no signal at all — the failures are asynchronous, so none of them
  /// could be caught as a thrown exception.
  Widget _diagnosticsPanel() {
    return PointerInterceptor(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 220),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white, fontSize: 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Engine diagnostics',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Hide',
                    iconSize: 16,
                    color: Colors.white70,
                    onPressed: () => setState(() => _showDiagnostics = false),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_diagnostics.isEmpty)
                        const Text(
                          'Nothing reported yet. "Break something" below '
                          'provokes three different failures.',
                          style: TextStyle(color: Colors.white54),
                        ),
                      for (final line in _diagnostics)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            line,
                            style: TextStyle(
                              color: line.startsWith('style loaded')
                                  ? Colors.greenAccent
                                  : Colors.orangeAccent,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Provokes three genuinely different failures, to show they all arrive.
  void _breakSomething() {
    final layers = _controller.style;
    // 1. A command that cannot be applied: mbgl returns a null unique_ptr, and
    //    the shim now reports it instead of discarding it.
    layers.removeLayer('a-layer-that-was-never-added');
    // 2. A source a layer still references — the failure that looks exactly
    //    like the call doing nothing.
    layers
      ..addSource(
        'diag-src',
        GeoJsonSource(data: GeoJsonData.points(const [_turku])),
      )
      ..addLayer(
        const CircleLayer(
          id: 'diag-layer',
          source: 'diag-src',
          circleRadius: StyleValue(0),
        ),
      )
      ..removeSource('diag-src')
      // 3. A font no style serves. mbgl 404s the glyph range and reports it
      //    ONLY through its log — MapObserver::onGlyphsError never fires — so
      //    this line is what proves the log observer is wired.
      ..addLayer(
        const SymbolLayer(
          id: 'diag-bad-font',
          source: 'diag-src',
          textField: StyleValue('x'),
          textFont: StyleValue(['No Such Font Regular']),
        ),
      );
  }

  /// What this renderer can do, and the value types that describe it.
  ///
  /// Everything shown is computed live: the tiers genuinely differ, and
  /// [MapLibreCapabilities] is the supported way to ask rather than calling
  /// something and watching it no-op.
  Widget _capabilitiesPanel() {
    final capabilities = _controller.capabilities;
    // LatLngBounds over the dataset this scenario draws — mbgl's own shape,
    // south-west/north-east, never gl-js's longitude-first ordering.
    final bounds = LatLngBounds.fromPoints(
      _dataset(_engineCounts[_engineCountIndex]),
    );
    // A PARTIAL camera: "zoom to 6, leave everything else" without a
    // read-modify-write that races the render thread.
    const partial = CameraOptions(zoom: 6);

    return PointerInterceptor(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 460),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'controller.capabilities',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              _kv('projection', '${capabilities.projection}'),
              _kv('style layers', '${capabilities.styleLayers}'),
              _kv('3D models', '${capabilities.models}'),
              _kv('rotate / tilt', '${capabilities.rotateAndTilt}'),
              _kv('Dart gestures', '${capabilities.gestures}'),
              _kv('engine events', '${capabilities.events}'),
              _kv('camera commands', '${capabilities.cameraCommands}'),
              const Divider(),
              const Text(
                'LatLngBounds over the engine dataset',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              _kv('south-west', '${bounds.southwest}'),
              _kv('north-east', '${bounds.northeast}'),
              _kv('centre', '${bounds.center}'),
              _kv('crosses antimeridian', '${bounds.crossesAntimeridian}'),
              const Divider(),
              const Text(
                'CameraOptions — a partial camera',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              _kv('options', '$partial'),
              const Divider(),
              const Text(
                'LatLng hardening',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Text(
                'mbgl::LatLng THROWS on these, and a C++ throw crossing the FFI '
                'boundary is undefined behaviour rather than a catchable error.',
                style: TextStyle(fontSize: 11),
              ),
              _kv('sanitized(120, 190)', '${LatLng.sanitized(120, 190)}'),
              _kv(
                'sanitized(NaN, NaN)',
                '${LatLng.sanitized(double.nan, double.nan)}',
              ),
              _kv(
                'LatLng(60.45, 190).wrapped()',
                '${const LatLng(60.45, 190).wrapped()}',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String key, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 170,
          child: Text(key, style: const TextStyle(color: Colors.black54)),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );

  /// Runs the gl-js camera verbs in sequence, so the difference between them is
  /// visible rather than described.
  ///
  /// Each `await` here returns when the ENGINE says the transition ended — not
  /// after a timer — so the steps cannot overlap. That is the completion
  /// contract: a Future resolves on transition end, and a superseded transition
  /// resolves too rather than hanging.
  Future<void> _runCameraTour() async {
    if (!_controller.capabilities.cameraCommands) {
      _logDiagnostic('this tier has no engine camera commands');
      return;
    }
    final camera = _controller.camera;
    _logDiagnostic('camera tour: jumpTo(zoom) — partial, nothing else changes');
    // A PARTIAL camera: no centre, no bearing, no read-modify-write.
    await camera.jumpTo(const CameraOptions(zoom: 5));
    await Future<void>.delayed(const Duration(milliseconds: 400));

    _logDiagnostic('easeTo — a straight eased line (unreachable before)');
    await camera.easeTo(
      CameraOptions(center: _stockholm, zoom: 9),
      duration: const Duration(milliseconds: 900),
    );

    _logDiagnostic('flyTo — the van Wijk arc, computed by the engine');
    await camera.flyTo(
      CameraOptions(center: _london, zoom: 11),
      duration: const Duration(milliseconds: 1800),
    );

    _logDiagnostic('rotateTo + resetNorth');
    await camera.rotateTo(45, duration: const Duration(milliseconds: 600));
    await camera.resetNorth(duration: const Duration(milliseconds: 600));

    _logDiagnostic('zoomIn / zoomOut about a CORNER, not the centre');
    // Anchoring on a corner is the only way to see that the anchor survives:
    // mbgl drops it whenever a centre is set, and a centre-anchored zoom looks
    // identical either way because the centre is a fixed point.
    await camera.zoomIn(
      around: Offset.zero,
      duration: const Duration(milliseconds: 600),
    );
    await camera.zoomOut(
      around: Offset.zero,
      duration: const Duration(milliseconds: 600),
    );

    final where = await camera.getBounds();
    _logDiagnostic(
      where == null
          ? 'camera tour done'
          : 'camera tour done — visible '
                '${where.south.toStringAsFixed(1)}..'
                '${where.north.toStringAsFixed(1)} N',
    );
  }

  /// gl-js `setMaxBounds` — the WHOLE VIEWPORT is kept inside the box.
  ///
  /// mbgl's own `BoundOptions.bounds` constrains only the camera CENTRE under
  /// that same word, so the controller sets the constrain mode too. Driven by
  /// the scenario rather than a button, so leaving the scenario always takes
  /// the constraint back off.
  Future<void> _applyConstraints({required bool on}) async {
    final camera = _controller.camera;
    if (on) {
      await camera.setMaxBounds(
        const LatLngBounds(
          southwest: LatLng(54.0, 4.0),
          northeast: LatLng(71.0, 32.0),
        ),
      );
      await camera.setMinZoom(3);
      await camera.setMaxZoom(12);
      await camera.fitBounds(
        const LatLngBounds(
          southwest: LatLng(54.0, 4.0),
          northeast: LatLng(71.0, 32.0),
        ),
        transition: CameraTransition.ease,
      );
      _logDiagnostic('constrained: viewport locked to the Nordics, zoom 3..12');
      final limits = await camera.getConstraints();
      if (limits != null) _logDiagnostic('constraints now: $limits');
    } else {
      await camera.setMaxBounds(null);
      await camera.setMinZoom(0);
      await camera.setMaxZoom(22);
      _logDiagnostic('unconstrained');
    }
  }

  /// Frames the camera on the engine dataset — gl-js `fitBounds`.
  ///
  /// This used to be a hand-rolled approximation: [LatLngBounds.center] plus a
  /// zoom guessed from the span, because `fitBounds` did not exist. The engine
  /// does it properly — it knows the viewport's aspect ratio, the padding and
  /// the projection — so the box actually ends up on screen instead of roughly
  /// on screen.
  ///
  /// The padding keeps the data clear of the scenario bar and the control
  /// column, which is what [EdgeInsets] is for at this boundary.
  Future<void> _fitToData() async {
    final bounds = LatLngBounds.fromPoints(
      _dataset(_engineCounts[_engineCountIndex]),
    );
    await _controller.camera.fitBounds(
      bounds,
      padding: const EdgeInsets.only(
        top: 140,
        left: 24,
        right: 220,
        bottom: 80,
      ),
      transition: CameraTransition.fly,
      duration: const Duration(milliseconds: 900),
    );
    // And prove it worked, with the engine's own answer rather than ours.
    final visible = await _controller.camera.getBounds();
    if (visible != null && mounted) {
      _logDiagnostic(
        'fitBounds → visible ${visible.south.toStringAsFixed(2)}..'
        '${visible.north.toStringAsFixed(2)} N, '
        '${visible.west.toStringAsFixed(2)}..'
        '${visible.east.toStringAsFixed(2)} E',
      );
    }
  }

  // --- UI ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('maplibre_flutter'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.accessibility_new),
            tooltip: 'Accessibility',
            onPressed: () => Navigator.pushNamed(context, '/accessibility'),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: Builder(
              builder: (context) => MapLibreMap(
                controller: _controller,
                style: _style,
                options: const MapOptions(
                  initialCamera: MapCamera(
                    center: LatLng(64.5, 26.0),
                    zoom: 4.2,
                  ),
                ),
                retainRuntimeStyle: _retainRuntimeStyle,
                markers: _buildMarkers(),
                // Fires on EVERY style load, so a style swap re-applies the
                // scenario the moment the new document is in — this replaced a
                // hardcoded 700 ms delay, which was a guess that raced.
                onStyleLoaded: _onStyleLoaded,
                onTap: switch (_scenario) {
                  Scenario.interaction => (tap) => setState(
                    () => _dropped.add(tap.point),
                  ),
                  Scenario.geojsonFeatures => _queryAtTap,
                  _ => null,
                },
              ),
            ),
          ),
          // Nothing here is wrapped in anything to keep the wheel off the map:
          // an overlay that hit-tests opaquely — every Card and button below —
          // already stops it. The gaps BETWEEN the floating controls are not
          // covered, and scrolling there zooms, which is right: that gap is the
          // map.
          Positioned(top: 12, left: 12, right: 12, child: _scenarioBar()),
          const Positioned(bottom: 12, left: 12, child: _FrameStats()),
          if (_moveReasons.isNotEmpty)
            Positioned(bottom: 60, left: 12, child: _reasonBadge()),
          if (_scenario == Scenario.geojsonFeatures)
            Positioned(top: 140, left: 12, child: _queryResultPanel()),
          if (_showDiagnostics)
            Positioned(top: 140, right: 12, child: _diagnosticsPanel()),
          if (_showCapabilities)
            Positioned(top: 140, left: 12, child: _capabilitiesPanel()),
          if (_stressing) Positioned(left: 12, bottom: 96, child: _modelHud()),
          if (_modelError != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 60,
              child: _modelErrorBar(),
            ),
          Positioned(right: 16, bottom: 16, child: _controls()),
        ],
      ),
    );
  }

  /// Says what is under test right now, and what to look for.
  Widget _scenarioBar() {
    return PointerInterceptor(
      child: Card(
        color: Colors.black.withValues(alpha: 0.8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text(
                    'Scenario:',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(width: 8),
                  if (!_ready) ...[
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      // Says WHICH half is outstanding. A style that 404s never
                      // completes onReady — correctly, since gl-js never fires
                      // `load` either — so an unexplained spinner would be
                      // indistinguishable from a hang.
                      'waiting for '
                      '${!_controller.isAttached
                          ? "the map"
                          : !_styleSeen
                          ? "the style"
                          : "the first frame"}'
                      '${_waitingSeconds > 2 ? " (${_waitingSeconds}s)" : ""}…',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  // Disabled until the map is ready — switching scenarios adds
                  // engine layers, and mbgl drops everything added before the
                  // style lands. Without the spinner above, that greyed-out
                  // control reads as broken rather than as "not yet".
                  // Present but DISABLED until the map is ready — switching
                  // scenarios adds engine layers, and mbgl drops everything
                  // added before the style lands. Kept in the tree rather than
                  // removed so the bar does not jump, and so a test can see it;
                  // the spinner above is what stops a greyed-out control
                  // reading as broken.
                  DropdownButton<Scenario>(
                    value: _scenario,
                    dropdownColor: Colors.black87,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    underline: const SizedBox.shrink(),
                    // Enabled as soon as the map is ATTACHED, not on onReady.
                    // Gating the whole demo on a successful style load meant one
                    // slow or 404ing style made the app untestable, and
                    // _applyScenario re-runs from onStyleLoaded anyway — so
                    // switching early is safe.
                    onChanged: _controller.isAttached
                        ? (s) => s == null ? null : _selectScenario(s)
                        : null,
                    items: [
                      for (final s in Scenario.values)
                        DropdownMenuItem(value: s, child: Text(s.label)),
                    ],
                  ),
                  const Spacer(),
                  if (_scenario == Scenario.hybrid)
                    Text(
                      'live widgets: ${_liveFeatures.length}',
                      style: const TextStyle(
                        color: Colors.lightGreenAccent,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
              Text(
                _scenario.blurb,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Only the controls the active scenario actually uses.
  Widget _controls() {
    final usesEngineCount =
        _scenario == Scenario.enginePoints ||
        _scenario == Scenario.engineClusters ||
        _scenario == Scenario.engineIcons ||
        _scenario == Scenario.engineIconsFlat ||
        _scenario == Scenario.hybrid;

    return PointerInterceptor(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (_scenario == Scenario.widgetMarkers) ...[
            _mini(
              'Count ${_widgetCounts[_widgetCountIndex]}',
              Icons.numbers,
              () {
                _widgetCountIndex =
                    (_widgetCountIndex + 1) % _widgetCounts.length;
                _applyScenario();
              },
            ),
            _mini(
              'Layers ${_repaintBoundaries ? 'on' : 'off'}',
              Icons.layers_outlined,
              () => setState(() => _repaintBoundaries = !_repaintBoundaries),
            ),
            _mini(
              'Fancy ${_fancyMarkers ? 'on' : 'off'}',
              Icons.auto_awesome,
              () => setState(() => _fancyMarkers = !_fancyMarkers),
            ),
          ],
          if (usesEngineCount)
            _mini(
              'Points ${_engineCounts[_engineCountIndex]}',
              Icons.blur_on,
              () {
                _engineCountIndex =
                    (_engineCountIndex + 1) % _engineCounts.length;
                _applyScenario();
              },
            ),
          if (_scenario == Scenario.models3d)
            _mini(
              _driving ? 'Stop driving' : 'Drive model',
              _driving ? Icons.stop : Icons.play_arrow,
              _toggleDriving,
            ),
          if (_scenario == Scenario.models3dStress)
            _mini('8 more cars', Icons.add_road, () => _changeCars(8)),
          if (_scenario == Scenario.models3dStress)
            _mini('8 fewer cars', Icons.remove_road, () => _changeCars(-8)),
          if (_scenario.usesModels)
            _mini(
              _demoAsset == _carAsset
                  ? 'Model: car (728k tris)'
                  : 'Model: box (24 tris)',
              Icons.swap_horiz,
              _swapModel,
            ),
          _mini('Zoom in', Icons.add, () => _zoomBy(1)),
          _mini('Zoom out', Icons.remove, () => _zoomBy(-1)),
          // Turning and tilting the map. Not model-specific — the desktop tier
          // has no rotate/pitch gesture yet, so buttons are the only way to get
          // a bearing or a pitch at all, and both matter well beyond 3D (label
          // orientation, fill-extrusion, checking a pitched projection).
          _mini('Rotate left', Icons.rotate_left, () => _rotateBy(-45)),
          _mini('Rotate right', Icons.rotate_right, () => _rotateBy(45)),
          _mini('Tilt', Icons.threed_rotation, _cyclePitch),
          _mini(
            'Fly: ${_places[_placeIndex].$1}',
            Icons.flight,
            _flyToNextPlace,
          ),
          // The styleForms scenario drives the style itself, so the global
          // toggle would fight it.
          if (_scenario != Scenario.styleForms)
            _mini(
              _style == _demotiles ? 'Demotiles' : 'Liberty',
              Icons.map_outlined,
              _toggleStyle,
            ),
          // Scenario-specific actions only appear for their scenario, so the
          // control bar stays the set of things that make sense ANYWHERE. Each
          // demo is a Scenario case; this is not a second menu.
          if (_scenario == Scenario.cameraVerbs) ...[
            _mini('Replay the tour', Icons.replay, _runCameraTour),
            _mini('Fit to data', Icons.crop_free, _fitToData),
          ],
          if (_scenario == Scenario.diagnostics)
            _mini('Break something again', Icons.bug_report, _breakSomething),
          if (_scenario == Scenario.retainRuntimeStyle)
            _mini(
              _retainRuntimeStyle ? 'Retain: ON' : 'Retain: OFF',
              _retainRuntimeStyle ? Icons.lock : Icons.lock_open,
              () => setState(() => _retainRuntimeStyle = !_retainRuntimeStyle),
            ),
          if (_scenario == Scenario.styleForms)
            _mini(
              'Form: ${_styleForms[_styleFormIndex].$1}',
              Icons.data_object,
              _nextStyleForm,
            ),
        ],
      ),
    );
  }

  /// What the 3D field actually costs. Reports the MAP's frame rate and
  /// Flutter's separately: the map is a texture, so Flutter's vsync stays pinned
  /// at the display rate however far behind the map falls, and quoting only that
  /// number would say "60 fps" over a map rendering at 12.
  Widget _modelHud() {
    return PointerInterceptor(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'map   ${_mapFps.toStringAsFixed(1)} fps',
                style: TextStyle(
                  color: _mapFps < 30
                      ? Colors.orangeAccent
                      : Colors.greenAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'flutter ${_stressFps.toStringAsFixed(1)} fps  '
                '(vsync, not the map)',
              ),
              Text('worst UI frame ${_stressWorstMs.toStringAsFixed(1)} ms'),
              const SizedBox(height: 4),
              Text('$_stressCount models x $_partsPerModel parts'),
              Text('= ${_stressCount * _partsPerModel} draw calls'),
              Text('$_stressCount updateModel/frame'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modelErrorBar() {
    return PointerInterceptor(
      child: Container(
        padding: const EdgeInsets.all(8),
        color: Colors.red.shade700,
        child: Text(_modelError!, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  Widget _mini(String label, IconData icon, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: FloatingActionButton.extended(
        heroTag: label,
        onPressed: _controller.isAttached ? onPressed : null,
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }
}

// --- Marker widgets ----------------------------------------------------------

/// One dot of the widget-marker stress cluster.
class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.85),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
    );
  }
}

/// Padding around a marker being rasterized into an engine icon.
///
/// [MapLibreStyleController.rasterizeWidget] captures exactly the box it is
/// given, so anything drawn OUTSIDE the child's bounds — a shadow, a glow — is
/// clipped at the edges. Framing the child leaves room for it.
class _IconFrame extends StatelessWidget {
  const _IconFrame({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Padding ONLY — no Center. Align/Center expands to fill whatever
    // constraints it is given, so wrapping in one turned the rasterizer's
    // "max size" back into a fixed box and the padding ate into the marker,
    // clipping its text. Padding shrink-wraps, so the icon comes out at the
    // marker's natural size plus room for its shadow.
    return Padding(padding: const EdgeInsets.all(8), child: child);
  }
}

/// A deliberately expensive marker — gradient, shadow, border and text. The case
/// where a per-marker `RepaintBoundary` should pay for itself.
class _FancyMarker extends StatelessWidget {
  const _FancyMarker();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Colors.deepPurple, Colors.pinkAccent],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: const Text(
        '12',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// An animated CLUSTER bubble: a pulsing ring around the engine's point count.
///
/// The count comes from supercluster inside mbgl (via queryRenderedFeatures),
/// not from anything Dart worked out — this is a real widget drawn over a real
/// engine cluster.
class _PulsingCluster extends StatefulWidget {
  const _PulsingCluster({required this.count});
  final int count;

  @override
  State<_PulsingCluster> createState() => _PulsingClusterState();
}

class _PulsingClusterState extends State<_PulsingCluster>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Bigger clusters get a bigger bubble, like the engine's own step scale.
    final radius = widget.count >= 750
        ? 34.0
        : widget.count >= 100
        ? 28.0
        : 22.0;
    return SizedBox(
      width: radius * 2 + 16,
      height: radius * 2 + 16,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: radius * 2 + 16 * t,
                height: radius * 2 + 16 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.orangeAccent.withValues(
                      alpha: (1 - t).clamp(0.0, 1.0),
                    ),
                    width: 3,
                  ),
                ),
              ),
              Container(
                width: radius * 2,
                height: radius * 2,
                decoration: BoxDecoration(
                  color: Colors.deepOrange.withValues(alpha: 0.85),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${widget.count}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A marker that drives its own animation, to prove markers stay live widgets:
/// the overlay repositions them at paint time without rebuilding, so this keeps
/// ticking while the map moves.
class _PulsingMarker extends StatefulWidget {
  const _PulsingMarker();

  @override
  State<_PulsingMarker> createState() => _PulsingMarkerState();
}

class _PulsingMarkerState extends State<_PulsingMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 16 + 32 * t,
                height: 16 + 32 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.lightBlueAccent.withValues(
                      alpha: (1 - t).clamp(0.0, 1.0),
                    ),
                    width: 3,
                  ),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.blue,
                  shape: BoxShape.circle,
                ),
                child: SizedBox(width: 16, height: 16),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Rolling average of Flutter's frame timings. `raster` is where marker
/// compositing shows up; `ui` is Dart-side build/layout/paint.
class _FrameStats extends StatefulWidget {
  const _FrameStats();

  @override
  State<_FrameStats> createState() => _FrameStatsState();
}

class _FrameStatsState extends State<_FrameStats> {
  static const _window = 60;
  final List<FrameTiming> _recent = <FrameTiming>[];
  double _ui = 0;
  double _raster = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    _recent.addAll(timings);
    if (_recent.length > _window) {
      _recent.removeRange(0, _recent.length - _window);
    }
    if (_recent.isEmpty) return;
    var ui = 0.0;
    var raster = 0.0;
    for (final t in _recent) {
      ui += t.buildDuration.inMicroseconds / 1000.0;
      raster += t.rasterDuration.inMicroseconds / 1000.0;
    }
    final n = _recent.length;
    if (!mounted) return;
    setState(() {
      _ui = ui / n;
      _raster = raster / n;
    });
  }

  @override
  Widget build(BuildContext context) {
    final over = _raster > 16.7 || _ui > 16.7;
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          'ui ${_ui.toStringAsFixed(1)}ms   raster ${_raster.toStringAsFixed(1)}ms',
          style: TextStyle(
            color: over ? Colors.orangeAccent : Colors.greenAccent,
            fontFeatures: const [FontFeature.tabularFigures()],
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
