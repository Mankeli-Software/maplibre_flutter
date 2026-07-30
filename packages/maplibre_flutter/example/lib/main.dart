import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
  hybrid(
    'Hybrid: animated + 50k',
    'All 50k live in the engine, clustered there. queryRenderedFeatures asks '
        'the engine what it actually drew, and each of those becomes a REAL '
        'animated Flutter widget — pulsing bubbles carrying the engine\'s own '
        'point_count, individual pins once zoomed in. Live widget count stays '
        'small however big the dataset is.',
  );

  const Scenario(this.label, this.blurb);
  final String label;
  final String blurb;
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
  static const _widgetCounts = <int>[100, 500, 2000];
  int _widgetCountIndex = 0;
  List<LatLng> _widgetPoints = const <LatLng>[];
  bool _repaintBoundaries = true;
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
    // Every layer first, THEN the source: mbgl refuses to remove a source while
    // any layer still references it ("Source 'bulk' is in use, cannot remove").
    layers
      ..removeLayer('bulk-icons')
      ..removePoints('bulk')
      ..removeSource('bulk');
    setState(() {
      _liveFeatures = const [];
      _widgetPoints = const [];
    });

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

      case Scenario.engineIcons:
        await _applyEngineIcons();

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

  /// Engine icons: a rasterized Flutter widget as `icon-image`.
  ///
  /// Clustered like the circle scenario — an unclustered 50k icon layer with
  /// allow-overlap paints a solid mass at world view, which is useless to look
  /// at. Cluster bubbles carry the counts; leaves appear as you zoom in.
  Future<void> _applyEngineIcons() async {
    final layers = _controller.layers;
    // Padded, because rasterizeWidget captures exactly the box it is given and
    // the marker's shadow paints outside its own bounds.
    await layers.addWidgetIcon(
      'bulk-pin',
      const _IconFrame(child: _FancyMarker()),
      size: const Size(44, 34),
    );
    if (!mounted) return;

    layers.addPoints(
      'bulk',
      _dataset(_engineCounts[_engineCountIndex]),
      cluster: true,
      radius: 4,
      clusterTextFont: _safeFont,
    );
    // Leaves (non-cluster features) drawn with the widget-derived icon, on top
    // of the plain circles addPoints made for them.
    layers.addLayerJson(
      jsonEncode({
        'id': 'bulk-icons',
        'type': 'symbol',
        'source': 'bulk',
        'filter': [
          '!',
          ['has', 'point_count'],
        ],
        'layout': {'icon-image': 'bulk-pin', 'icon-allow-overlap': true},
      }),
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
          _mini('Zoom in', Icons.add, () => _zoomBy(1)),
          _mini('Zoom out', Icons.remove, () => _zoomBy(-1)),
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
    return Center(
      child: Padding(padding: const EdgeInsets.all(8), child: child),
    );
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
