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

/// Two keyless styles to toggle between (no API key required).
const _demotiles = 'https://demotiles.maplibre.org/style.json';
const _liberty = 'https://tiles.openfreemap.org/styles/liberty';

/// A few places the "fly to" button cycles through.
const _places = <(String, LatLng, double)>[
  ('London', LatLng(51.5074, -0.1278), 10),
  ('Turku', _turku, 10),
  ('Stockholm', _stockholm, 10),
  ('Tokyo', LatLng(35.6812, 139.7671), 10),
  ('New York', LatLng(40.7128, -74.0060), 10),
];

/// Turku, Finland — centre of the marker stress-test cluster.
const _turku = LatLng(60.4518, 22.2666);

/// Stockholm, Sweden — home of the self-animating marker.
const _stockholm = LatLng(59.3293, 18.0686);

/// Cluster sizes the stress button cycles through. Every marker is reprojected
/// on every camera tick, so this is the load knob for the overlay.
const _stressCounts = <int>[0, 100, 500, 2000];

class MapDemoPage extends StatefulWidget {
  const MapDemoPage({super.key});

  @override
  State<MapDemoPage> createState() => _MapDemoPageState();
}

class _MapDemoPageState extends State<MapDemoPage> {
  // We construct and own the controller, so we dispose it (see [dispose]).
  final MapLibreMapController _controller = MapLibreMapController();
  bool _ready = false;
  String _style = _demotiles;
  int _placeIndex = 0;

  // A draggable marker (start at Paris) and pins dropped by tapping the map —
  // both demonstrate the projection round-trip (screen <-> LatLng).
  LatLng _draggable = const LatLng(48.8566, 2.3522);
  final List<LatLng> _dropped = <LatLng>[];

  // Stress-test cluster around Turku. Generated once per size change (not per
  // build) so a rebuild never pays the generation cost.
  int _stressIndex = 0;
  List<LatLng> _stressPoints = const <LatLng>[];

  // Perf A/B switches for the cluster.
  bool _stressBoundaries = true; // per-marker RepaintBoundary
  bool _fancyMarkers = false; // expensive child instead of a plain dot

  /// Scatters [count] points around Turku. Seeded so every run — and every
  /// before/after comparison — gets the identical layout.
  static List<LatLng> _cluster(int count) {
    final rnd = math.Random(42);
    return List<LatLng>.generate(count, (_) {
      // ~±0.15 deg lat / ±0.30 deg lng: a spread that stays on screen around
      // Turku at city zoom, and spills off it when zoomed in (exercising the
      // off-screen parking path too).
      return LatLng(
        _turku.latitude + (rnd.nextDouble() - 0.5) * 0.30,
        _turku.longitude + (rnd.nextDouble() - 0.5) * 0.60,
      );
    });
  }

  void _cycleStress() {
    setState(() {
      _stressIndex = (_stressIndex + 1) % _stressCounts.length;
      _stressPoints = _cluster(_stressCounts[_stressIndex]);
    });
  }

  @override
  void initState() {
    super.initState();
    // The controller exists immediately; the native map is ready a bit later.
    // Wait for it, then enable the camera/style controls.
    _controller.onReady.then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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

  // Style is declarative: change the widget's `style` prop and rebuild. The
  // widget pushes the new style to the native map (CLAUDE.md §3).
  void _toggleStyle() {
    setState(() => _style = _style == _demotiles ? _liberty : _demotiles);
  }

  List<MapLibreMarker> _buildMarkers() {
    return <MapLibreMarker>[
      // A fixed, tappable pin glued to London (tip on the point).
      MapLibreMarker(
        point: _places[0].$2,
        alignment: Alignment.bottomCenter,
        child: GestureDetector(
          onTap: () => ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Tapped London'))),
          child: const Icon(Icons.location_on, color: Colors.red, size: 40),
        ),
      ),
      // A draggable pin: update its point from the drag callbacks so it settles.
      MapLibreMarker(
        point: _draggable,
        alignment: Alignment.bottomCenter,
        draggable: true,
        onDragUpdate: (p) => setState(() => _draggable = p),
        onDragEnd: (p) => setState(() => _draggable = p),
        child: const Icon(Icons.push_pin, color: Colors.indigo, size: 40),
      ),
      // A marker that animates itself. Markers are repositioned by the overlay
      // at PAINT time (no rebuild), so a child with its own ticker keeps
      // animating smoothly while the map pans/zooms — this is the check that
      // markers really are live widgets, not baked pictures.
      const MapLibreMarker(
        point: _stockholm,
        child: _PulsingMarker(),
      ),
      // Pins dropped by tapping the map.
      for (final p in _dropped)
        MapLibreMarker(
          point: p,
          child: const Icon(Icons.circle, color: Colors.green, size: 16),
        ),
      // Stress cluster around Turku. Deliberately last: a long list here is the
      // load the Flow delegate reprojects on every camera tick. `repaintBoundary`
      // is A/B-able from the UI: it should WIN for expensive children and LOSE
      // for thousands of trivial dots (a layer each costs more than a redraw).
      for (final p in _stressPoints)
        MapLibreMarker(
          point: p,
          repaintBoundary: _stressBoundaries,
          child: _fancyMarkers ? const _FancyMarker() : const _Dot(),
        ),
    ];
  }

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
                initialCamera: MapCamera(center: LatLng(0, 0), zoom: 1),
              ),
              markers: _buildMarkers(),
              onTap: (point) => setState(() => _dropped.add(point)),
            ),
          ),
          // Frame timings, so the stress test is measured rather than guessed.
          const Positioned(top: 16, left: 16, child: _FrameStats()),
          Positioned(
            right: 16,
            bottom: 16,
            // On web the map is a DOM element under the Flutter scene, so
            // controls drawn over it must intercept pointer events or the
            // clicks leak through to the map (CLAUDE.md §3 web tier).
            // PointerInterceptor is a no-op on non-web platforms.
            child: PointerInterceptor(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton(
                    heroTag: 'zoom_in',
                    onPressed: _ready ? () => _zoomBy(1) : null,
                    child: const Icon(Icons.add),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton(
                    heroTag: 'zoom_out',
                    onPressed: _ready ? () => _zoomBy(-1) : null,
                    child: const Icon(Icons.remove),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.extended(
                    heroTag: 'fly',
                    onPressed: _ready ? _flyToNextPlace : null,
                    icon: const Icon(Icons.flight),
                    label: Text('Fly to ${_places[_placeIndex].$1}'),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.extended(
                    heroTag: 'style',
                    onPressed: _ready ? _toggleStyle : null,
                    icon: const Icon(Icons.layers),
                    label: Text(_style == _demotiles ? 'Demotiles' : 'Liberty'),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.extended(
                    heroTag: 'stress',
                    onPressed: _ready ? _cycleStress : null,
                    icon: const Icon(Icons.scatter_plot),
                    label: Text('Turku ×${_stressCounts[_stressIndex]}'),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.extended(
                    heroTag: 'boundary',
                    backgroundColor: _stressBoundaries ? null : Colors.grey,
                    onPressed: () => setState(
                      () => _stressBoundaries = !_stressBoundaries,
                    ),
                    icon: const Icon(Icons.layers_outlined),
                    label: Text('Layers ${_stressBoundaries ? 'on' : 'off'}'),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.extended(
                    heroTag: 'fancy',
                    backgroundColor: _fancyMarkers ? null : Colors.grey,
                    onPressed: () =>
                        setState(() => _fancyMarkers = !_fancyMarkers),
                    icon: const Icon(Icons.auto_awesome),
                    label: Text('Fancy ${_fancyMarkers ? 'on' : 'off'}'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One dot of the Turku stress cluster. `const` so a rebuild reuses the same
/// widget instance for every marker in the list.
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

/// A deliberately expensive marker — rounded card, gradient, shadow, border and
/// text. This is what "complicated markers" costs to paint, and it is the case
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

/// A marker that drives its own animation (a pulsing ring around a dot).
///
/// The overlay repositions markers by paint-time transform without rebuilding
/// them, so this keeps ticking at full rate while the map moves — and equally,
/// it animates while the map sits still.
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
          final t = _c.value; // 0 -> 1, repeating
          return Stack(
            alignment: Alignment.center,
            children: [
              // Expanding, fading ring.
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

/// Rolling average of Flutter's own frame timings (UI = build+layout on the
/// platform thread, raster = GPU work). Watch `raster` while cycling the Turku
/// cluster: that is where marker reprojection + compositing shows up.
class _FrameStats extends StatefulWidget {
  const _FrameStats();

  @override
  State<_FrameStats> createState() => _FrameStatsState();
}

class _FrameStatsState extends State<_FrameStats> {
  static const _window = 60; // frames averaged
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
    // 16.7ms is the 60fps budget; flag frames that blow it.
    final over = _raster > 16.7 || _ui > 16.7;
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          'ui ${_ui.toStringAsFixed(1)}ms   '
          'raster ${_raster.toStringAsFixed(1)}ms',
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
