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
      home: Scaffold(
        appBar: AppBar(title: const Text('maplibre_flutter')),
        body: const MapLibreMap(
          options: MapOptions(
            styleUri: 'https://demotiles.maplibre.org/style.json',
            initialCamera: MapCamera(center: LatLng(0, 0), zoom: 1),
          ),
        ),
      ),
    );
  }
}
