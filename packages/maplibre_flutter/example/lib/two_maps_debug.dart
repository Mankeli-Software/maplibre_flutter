// A minimal two-map page for debugging the native engine with more than one map
// alive (the Windows Vulkan device-loss crash): one map at start, a button adds
// a second beside it. Run with:
//
//   flutter run -d windows -t lib/two_maps_debug.dart
import 'package:flutter/material.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

const _liberty = 'https://tiles.openfreemap.org/styles/liberty';

void main() {
  runApp(const MaterialApp(home: TwoMapsDebugPage()));
}

class TwoMapsDebugPage extends StatefulWidget {
  const TwoMapsDebugPage({super.key});

  @override
  State<TwoMapsDebugPage> createState() => _TwoMapsDebugPageState();
}

class _TwoMapsDebugPageState extends State<TwoMapsDebugPage> {
  bool _second = false;
  // A new key per show, so hiding and showing again builds a fresh engine.
  int _secondGeneration = 0;
  final List<String> _log = [];

  void _logLine(String line) {
    debugPrint('two_maps_debug: $line');
    setState(() {
      _log.insert(0, line);
      if (_log.length > 8) _log.removeLast();
    });
  }

  late final MapLibreMapController _first = _controller('map 1');
  MapLibreMapController? _secondController;

  MapLibreMapController _controller(String name) {
    final controller = MapLibreMapController();
    controller.onReady.then((_) => _logLine('$name ready'));
    controller.onError.listen((e) => _logLine('$name error: $e'));
    return controller;
  }

  Widget _map(MapLibreMapController controller, String style, Key key) {
    return MapLibreMap(
      key: key,
      controller: controller,
      style: style,
      options: const MapOptions(
        initialCamera: MapCamera(center: LatLng(61.5, 23.8), zoom: 10),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Two maps debug'),
        actions: [
          FilledButton(
            onPressed: () {
              setState(() {
                _second = !_second;
                if (_second) {
                  _secondGeneration++;
                  _secondController = _controller('map 2');
                }
              });
              _logLine(_second ? 'second map shown' : 'second map hidden');
            },
            child: Text(_second ? 'Hide second map' : 'Show second map'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _map(_first, _liberty, const ValueKey('m1'))),
                if (_second) ...[
                  const VerticalDivider(width: 4),
                  Expanded(
                    child: _map(
                      _secondController!,
                      _liberty,
                      ValueKey('m2-$_secondGeneration'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            height: 120,
            width: double.infinity,
            color: Colors.black87,
            padding: const EdgeInsets.all(8),
            child: Text(
              _log.join('\n'),
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
