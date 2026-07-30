import 'package:flutter/material.dart';
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
  ('Tokyo', LatLng(35.6812, 139.7671), 10),
  ('New York', LatLng(40.7128, -74.0060), 10),
];

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

  @override
  void initState() {
    super.initState();
    // The controller exists immediately; the native map is ready a bit later.
    // Wait for it, then enable the camera/style controls.
    _controller.onReady.then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
      // If a model was supplied on the command line, place it straight away so
      // `flutter run --dart-define=MODEL_GLB=...` is all it takes to see one.
      if (_modelPath.isNotEmpty) _toggleModel();
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
  // --- 3D model (EXPERIMENTAL) ----------------------------------------------
  //
  // The path is read natively, so it must be a real file on disk — not a Flutter
  // asset key. Override with:
  //   flutter run -d macos --dart-define=MODEL_GLB=/abs/path/to/model.glb
  static const String _modelPath = String.fromEnvironment(
    'MODEL_GLB',
    defaultValue: '',
  );
  // Many models are not authored in metres (Sketchfab exports especially), and
  // glTF's -Z-forward convention is widely ignored, so both are overridable.
  // Dart only has bool/int/String fromEnvironment, so these come in as strings.
  static const String _modelScaleRaw = String.fromEnvironment(
    'MODEL_SCALE',
    defaultValue: '1',
  );
  static const String _modelHeadingRaw = String.fromEnvironment(
    'MODEL_HEADING',
    defaultValue: '0',
  );
  static double get _modelScale => double.tryParse(_modelScaleRaw) ?? 1;
  static double get _modelHeading => double.tryParse(_modelHeadingRaw) ?? 0;
  bool _modelAdded = false;
  String? _modelError;

  // Where to put the model when the map is still zoomed out. A few-metre object
  // is sub-pixel below roughly z18, and the example opens at world view, so
  // "place it at the current centre" would drop it at null island invisibly.
  static const LatLng _modelSite = LatLng(51.50735, -0.12776); // Westminster

  Future<void> _toggleModel() async {
    if (_modelAdded) {
      // ignore: experimental_member_use
      _controller.removeModel('demo-model');
      setState(() {
        _modelAdded = false;
        _modelError = null;
      });
      return;
    }
    if (_modelPath.isEmpty) {
      setState(() {
        _modelError = 'Pass --dart-define=MODEL_GLB=/abs/path/model.glb';
      });
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
      // Deliberately exercising the 3D-model API before the declarative
      // `models:` widget prop lands.
      // ignore: experimental_member_use
      _controller.addModel(
        MapLibreModel(
          id: 'demo-model',
          assetPath: _modelPath,
          point: site,
          scale: _modelScale,
          headingDegrees: _modelHeading,
        ),
      );
      debugPrint('[model] added $_modelPath at $site '
          'scale=$_modelScale heading=$_modelHeading');
      setState(() {
        _modelAdded = true;
        _modelError = null;
      });
    } on ArgumentError catch (e) {
      debugPrint('[model] FAILED: ${e.message}');
      setState(() => _modelError = '${e.message}');
    }
  }

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
          onTap: () => ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tapped London')),
          ),
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
      // Pins dropped by tapping the map.
      for (final p in _dropped)
        MapLibreMarker(
          point: p,
          child: const Icon(Icons.circle, color: Colors.green, size: 16),
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
                    heroTag: 'model',
                    onPressed: _ready ? _toggleModel : null,
                    icon: const Icon(Icons.view_in_ar),
                    label: Text(_modelAdded ? 'Remove model' : 'Add 3D model'),
                  ),
                  if (_modelError != null)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(maxWidth: 320),
                      color: Colors.red.shade700,
                      child: Text(
                        _modelError!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  const SizedBox(height: 8),
                  FloatingActionButton.extended(
                    heroTag: 'style',
                    onPressed: _ready ? _toggleStyle : null,
                    icon: const Icon(Icons.layers),
                    label: Text(_style == _demotiles ? 'Demotiles' : 'Liberty'),
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
