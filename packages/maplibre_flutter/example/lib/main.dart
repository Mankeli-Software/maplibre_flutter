import 'dart:async';
import 'dart:io' show Directory, File;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_flutter/maplibre_flutter.dart';
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
    );
  }
}

// --- Styles ------------------------------------------------------------------

/// Two keyless styles to toggle between (no API key required).
const _demotiles = 'https://demotiles.maplibre.org/style.json';
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
  hybrid(
    'Hybrid: animated + 50k',
    'All 50k live in the engine, clustered there. queryRenderedFeatures asks '
        'the engine what it actually drew, and each of those becomes a REAL '
        'animated Flutter widget — pulsing bubbles carrying the engine\'s own '
        'point_count, individual pins once zoomed in. Live widget count stays '
        'small however big the dataset is.',
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
  String _style = _demotiles;
  int _placeIndex = 0;

  Scenario _scenario = Scenario.interaction;

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
  List<MapLibreQueriedFeature> _liveFeatures = const [];

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
    _controller.onReady.then((_) async {
      if (!mounted) return;
      setState(() => _ready = true);
      await _applyScenario();
    });
  }

  @override
  void dispose() {
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
    if (!_ready) return;
    final layers = _controller.layers;

    // Clear everything any scenario might have added.
    _controller.onCameraChanged?.removeListener(_onCameraChangedForHybrid);
    _trailingQuery?.cancel();
    _stopDriving();
    _stopStress();
    _removeModel();
    // Every layer first, THEN the source: mbgl refuses to remove a source while
    // any layer still references it ("Source 'bulk' is in use, cannot remove").
    layers
      ..removeLayer('bulk-icons')
      ..removePoints('bulk')
      ..removeSource('bulk')
      // The typed-API scenario's own ids.
      ..removeLayer('typed-labels')
      ..removeLayer('typed-circles')
      ..removeLayer('typed-route')
      ..removeSource('typed')
      ..removeSource('typed-route');
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
    // MapLibreLayersController.setTransitionOptions — so buying this back means
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
        layers.addPoints(
          'bulk',
          _dataset(_engineCounts[_engineCountIndex]),
          radius: 3,
        );

      case Scenario.engineClusters:
        layers.addPoints(
          'bulk',
          _dataset(_engineCounts[_engineCountIndex]),
          cluster: true,
          radius: 4,
          clusterTextFont: _safeFont,
        );

      case Scenario.typedStyle:
        _applyTypedStyle();

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
        layers.addPoints(
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

  /// The typed style API, used the way an app would use it.
  ///
  /// Nothing here is a JSON string and nothing goes through `addPoints`: the
  /// source, all three layers, the enums and every expression are the classes
  /// generated from the MapLibre Style Spec vendored in this repo
  /// (`maplibre_flutter/tool/generate_style_api.dart`). Compare with
  /// [_applyEngineIconsFlat] before this existed — the same document was a
  /// nested pile of maps.
  void _applyTypedStyle() {
    final layers = _controller.layers;

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
    await _controller.layers.addWidgetIcon(
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
    final layers = _controller.layers;
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
    final layers = _controller.layers;
    layers.addPoints(
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
    final found = _controller.layers.queryRenderedFeatures(
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
  Future<String> _resolveModelPath() async {
    if (_modelPath.isNotEmpty) return _modelPath;
    final cached = _resolvedAssets[_demoAsset];
    if (cached != null && File(cached).existsSync()) return cached;

    final bytes = await rootBundle.load(_demoAsset);
    final file = File(
      '${Directory.systemTemp.path}/${_demoAsset.split('/').last}',
    );
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    _resolvedAssets[_demoAsset] = file.path;
    return file.path;
  }

  /// Places the demo model and frames it: a car-sized object needs street-level
  /// zoom and some pitch before it reads as 3D at all.
  Future<void> _placeModel() async {
    if (_modelAdded) return;
    final String assetPath;
    try {
      assetPath = await _resolveModelPath();
    } catch (e) {
      setState(() => _modelError = 'could not read model: $e');
      return;
    }

    // Use wherever the user is already looking if it is close enough to see a
    // car-sized object; otherwise go to a known street-level site.
    final current = await _controller.camera.getPosition();
    final zoomedIn = current.zoom >= 15;
    final site = zoomedIn ? current.center : _modelSite;
    await _controller.camera.move(
      MapCamera(
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
    final camera = await _controller.camera.getPosition();
    if (camera.zoom > _driveZoom) {
      await _controller.camera.move(
        camera.copyWith(center: centre, zoom: _driveZoom),
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
    final String assetPath;
    try {
      assetPath = await _resolveModelPath();
    } catch (e) {
      setState(() => _modelError = 'could not read model: $e');
      return;
    }

    final centre = _modelAnchor;
    // Pull back far enough that the whole field is in view, else most of the
    // models are off-screen and the number on screen means nothing.
    final camera = await _controller.camera.getPosition();
    await _controller.camera.move(
      camera.copyWith(center: centre, zoom: 17, pitch: 55),
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
            assetPath: assetPath,
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
      _partsPerModel = _controller.modelPartCount(assetPath) ?? 0;
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
    final camera = await _controller.camera.getPosition();
    var bearing = (camera.bearing - degrees) % 360;
    if (bearing < 0) bearing += 360;
    await _controller.camera.move(
      camera.copyWith(bearing: bearing),
      duration: const Duration(milliseconds: 400),
    );
  }

  /// Cycles pitch rather than only increasing it. mbgl clamps pitch to
  /// DEFAULT_PITCH_MAX = 60 degrees (util/constants.hpp), and placing a model
  /// already sets 60, so an "increase" button had nothing left to do and looked
  /// broken.
  static const List<double> _pitchSteps = [0, 30, 60];

  Future<void> _cyclePitch() async {
    final camera = await _controller.camera.getPosition();
    var next = _pitchSteps.first;
    for (var i = 0; i < _pitchSteps.length; i++) {
      if (camera.pitch < _pitchSteps[i] - 1) {
        next = _pitchSteps[i];
        break;
      }
      next = _pitchSteps[(i + 1) % _pitchSteps.length];
    }
    await _controller.camera.move(
      camera.copyWith(pitch: next),
      duration: const Duration(milliseconds: 400),
    );
  }

  Future<void> _zoomBy(double delta) async {
    final camera = await _controller.camera.getPosition();
    await _controller.camera.move(
      camera.copyWith(zoom: camera.zoom + delta),
      duration: const Duration(milliseconds: 300),
    );
  }

  Future<void> _flyToNextPlace() async {
    final (_, center, zoom) = _places[_placeIndex];
    _placeIndex = (_placeIndex + 1) % _places.length;
    await _controller.camera.move(
      MapCamera(center: center, zoom: zoom),
      duration: const Duration(milliseconds: 2000),
    );
  }

  Future<void> _toggleStyle() async {
    setState(() => _style = _style == _demotiles ? _liberty : _demotiles);
    // A new style replaces the document, taking our sources and layers with it,
    // so rebuild the scenario once it has settled. (Widget markers are
    // unaffected — they live in Flutter, not the style.)
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (mounted) await _applyScenario();
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
          for (final f in _liveFeatures)
            MapLibreMarker(
              point: f.point,
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
      // Everything in this one is drawn by the engine from the typed style.
      case Scenario.typedStyle:
      // And these are drawn by the engine from a .glb.
      case Scenario.models3d:
      case Scenario.models3dStress:
        return const [];
    }
  }

  // --- UI ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('maplibre_flutter')),
      body: Stack(
        children: [
          Positioned.fill(
            child: MapLibreMap(
              controller: _controller,
              style: _style,
              options: const MapOptions(
                initialCamera: MapCamera(center: LatLng(64.5, 26.0), zoom: 4.2),
              ),
              markers: _buildMarkers(),
              onTap: _scenario == Scenario.interaction
                  ? (point) => setState(() => _dropped.add(point))
                  : null,
            ),
          ),
          Positioned(top: 12, left: 12, right: 12, child: _scenarioBar()),
          const Positioned(bottom: 12, left: 12, child: _FrameStats()),
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
                  DropdownButton<Scenario>(
                    value: _scenario,
                    dropdownColor: Colors.black87,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    underline: const SizedBox.shrink(),
                    onChanged: _ready
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
          _mini(
            _style == _demotiles ? 'Demotiles' : 'Liberty',
            Icons.map_outlined,
            _toggleStyle,
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
        onPressed: _ready ? onPressed : null,
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
/// [MapLibreLayersController.rasterizeWidget] captures exactly the box it is
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
