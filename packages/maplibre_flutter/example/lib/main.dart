import 'dart:io';
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
      _toggleModel();
    });
  }

  @override
  void dispose() {
    _driveTicker?.stop();
    _driveTicker?.dispose();
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
  // A bundled demo vehicle is used by default, so `flutter run` shows a model
  // with no setup. Point at your own with:
  //   flutter run -d macos --dart-define=MODEL_GLB=/abs/path/to/model.glb
  //
  // Note MODEL_GLB must be a real path on disk. Under the macOS/iOS sandbox an
  // app can only read its own container, so a path in ~/Downloads additionally
  // needs an entitlement (this example's DebugProfile has one) — which is exactly
  // why the default ships as an asset instead.
  static const String _demoAsset = 'assets/models/demo_vehicle.glb';
  static const String _modelPath = String.fromEnvironment(
    'MODEL_GLB',
    defaultValue: '',
  );

  // Resolved path of the bundled asset once copied out of the bundle.
  String? _bundledModelPath;

  /// The engine opens a real filesystem path natively and knows nothing about
  /// Flutter's asset bundle, so the asset is copied to a temp file once and that
  /// path is handed over. Under the sandbox this lands inside the app container,
  /// which is readable without any entitlement.
  Future<String> _resolveModelPath() async {
    if (_modelPath.isNotEmpty) return _modelPath;
    final cached = _bundledModelPath;
    if (cached != null && File(cached).existsSync()) return cached;

    final bytes = await rootBundle.load(_demoAsset);
    final file = File(
      '${Directory.systemTemp.path}/${_demoAsset.split('/').last}',
    );
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    _bundledModelPath = file.path;
    return file.path;
  }
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
  // Lift off the ground. A model sitting exactly at ground level is coplanar
  // with the basemap and z-fights, so the map bleeds through the bodywork.
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

  // Driving: the model is walked around a circle by mutating its placement each
  // frame. Re-adding it would re-parse the whole .glb every frame, so this uses
  // updateModel, which only touches the native placement.
  Ticker? _driveTicker;
  bool _driving = false;
  LatLng _modelAnchor = _modelSite;
  // Following a circle rotates the model 360 degrees per lap — that is simply
  // what driving a roundabout is, and it is correct. But how it READS depends
  // entirely on the loop size relative to the car: at a 10 m radius the loop is
  // only ~6 car lengths across, so the car visibly pivots and looks like it is
  // spinning rather than driving. 20 m is ~11 car lengths, which reads as a
  // vehicle following a curve.
  //
  // The loop then needs the camera pulled back to fit: at z19 a metre is ~11
  // logical pixels, so a 20 m radius is a ~430 px loop inside an 800 px view.
  static const double _driveRadiusMetres = 20;
  static const double _drivePeriodSeconds = 26;
  static const double _driveZoom = 19;

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
      _stopDriving();
      return;
    }
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
      // Deliberately exercising the 3D-model API before the declarative
      // `models:` widget prop lands.
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
      debugPrint('[model] added $assetPath at $site '
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

  // Rotates the camera. Trackpad/mouse rotate gestures are not wired on the
  // desktop tier yet, so this is the way to check a model from other angles.
  Future<void> _rotateBy(double degrees) async {
    final camera = await _controller.camera.getPosition();
    var bearing = (camera.bearing + degrees) % 360;
    if (bearing < 0) bearing += 360;
    await _controller.camera.move(
      camera.copyWith(bearing: bearing),
      duration: const Duration(milliseconds: 400),
    );
  }

  // Cycles pitch rather than only increasing it. mbgl clamps pitch to
  // DEFAULT_PITCH_MAX = 60 degrees (util/constants.hpp), and adding a model
  // already sets 60, so an "increase" button had nothing left to do and looked
  // broken.
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

  Future<void> _toggleDriving() async {
    if (_driving) {
      _stopDriving();
      return;
    }
    if (!_modelAdded) return;

    // Circle the marker nearest the model, so the loop has an obvious subject.
    final centre = _nearestMarkerTo(_modelAnchor) ?? _modelAnchor;

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
    final latPerMetre = 1 / 111320.0;
    final lngPerMetre =
        1 / (111320.0 * math.cos(centre.latitude * math.pi / 180));

    _driveTicker = Ticker((_) {
      final t =
          DateTime.now().difference(startedAt).inMilliseconds / 1000.0;
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
          assetPath: _bundledModelPath ?? _modelPath,
          point: point,
          scale: _modelScale,
          headingDegrees: _modelHeading + tangentBearing,
          elevationMetres: _modelElevation,
        ),
      );
    })..start();
    setState(() => _driving = true);
  }

  /// The marker closest to [to], or null if there are none. Plain equirectangular
  /// distance — fine over the tens of metres this is used across.
  LatLng? _nearestMarkerTo(LatLng to) {
    final candidates = <LatLng>[_places[0].$2, _draggable, ..._dropped];
    if (candidates.isEmpty) return null;
    final cosLat = math.cos(to.latitude * math.pi / 180);
    LatLng? best;
    var bestSq = double.infinity;
    for (final c in candidates) {
      final dy = c.latitude - to.latitude;
      final dx = (c.longitude - to.longitude) * cosLat;
      final sq = dy * dy + dx * dx;
      if (sq < bestSq) {
        bestSq = sq;
        best = c;
      }
    }
    return best;
  }

  void _stopDriving() {
    _driveTicker?.stop();
    _driveTicker?.dispose();
    _driveTicker = null;
    if (_driving && mounted) setState(() => _driving = false);
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
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FloatingActionButton(
                        heroTag: 'rotL',
                        tooltip: 'Rotate map left',
                        onPressed: _ready ? () => _rotateBy(-45) : null,
                        child: const Icon(Icons.rotate_left),
                      ),
                      const SizedBox(width: 8),
                      FloatingActionButton(
                        heroTag: 'rotR',
                        tooltip: 'Rotate map right',
                        onPressed: _ready ? () => _rotateBy(45) : null,
                        child: const Icon(Icons.rotate_right),
                      ),
                      const SizedBox(width: 8),
                      FloatingActionButton(
                        heroTag: 'tilt',
                        tooltip: 'Tilt map',
                        onPressed: _ready ? _cyclePitch : null,
                        child: const Icon(Icons.threed_rotation),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.extended(
                    heroTag: 'drive',
                    onPressed: _ready && _modelAdded
                        ? () => _toggleDriving()
                        : null,
                    icon: Icon(_driving ? Icons.stop : Icons.play_arrow),
                    label: Text(_driving ? 'Stop driving' : 'Drive model'),
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
