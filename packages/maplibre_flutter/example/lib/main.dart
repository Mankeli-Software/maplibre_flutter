import 'package:flutter/material.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

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
  MapLibreMapController? _controller;
  String _style = _demotiles;
  int _placeIndex = 0;

  Future<void> _zoomBy(double delta) async {
    final controller = _controller;
    if (controller == null) return;
    final camera = await controller.getCamera();
    await controller.moveCamera(
      camera.copyWith(zoom: camera.zoom + delta),
      duration: const Duration(milliseconds: 300),
    );
  }

  Future<void> _flyToNextPlace() async {
    final controller = _controller;
    if (controller == null) return;
    final (_, center, zoom) = _places[_placeIndex];
    _placeIndex = (_placeIndex + 1) % _places.length;
    await controller.moveCamera(
      MapCamera(center: center, zoom: zoom),
      duration: const Duration(milliseconds: 2000),
    );
  }

  Future<void> _toggleStyle() async {
    final controller = _controller;
    if (controller == null) return;
    _style = _style == _demotiles ? _liberty : _demotiles;
    await controller.setStyle(_style);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('maplibre_flutter')),
      body: Stack(
        children: [
          Positioned.fill(
            child: MapLibreMap(
              options: const MapOptions(
                styleUri: _demotiles,
                initialCamera: MapCamera(center: LatLng(0, 0), zoom: 1),
              ),
              onMapCreated: (c) => _controller = c,
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton(
                  heroTag: 'zoom_in',
                  onPressed: () => _zoomBy(1),
                  child: const Icon(Icons.add),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'zoom_out',
                  onPressed: () => _zoomBy(-1),
                  child: const Icon(Icons.remove),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.extended(
                  heroTag: 'fly',
                  onPressed: _flyToNextPlace,
                  icon: const Icon(Icons.flight),
                  label: Text('Fly to ${_places[_placeIndex].$1}'),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.extended(
                  heroTag: 'style',
                  onPressed: _toggleStyle,
                  icon: const Icon(Icons.layers),
                  label: Text(_style == _demotiles ? 'Demotiles' : 'Liberty'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
