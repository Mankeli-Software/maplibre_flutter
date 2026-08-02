import 'package:flutter/material.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';

const _style = 'https://demotiles.maplibre.org/style.json';

/// Every accessibility knob in one place, and the manual-test harness for them.
///
/// A texture-backed semantics tree is **invisible by construction**: there is no
/// DOM to inspect, and this repo already knows that screenshots lie about what a
/// texture actually composites. So this page exists to make the invisible part
/// checkable — by a developer adopting the package, and by whoever runs the
/// on-device VoiceOver / TalkBack / NVDA / Orca pass that nothing here has had.
class AccessibilityDemoPage extends StatefulWidget {
  const AccessibilityDemoPage({super.key});

  @override
  State<AccessibilityDemoPage> createState() => _AccessibilityDemoPageState();
}

class _AccessibilityDemoPageState extends State<AccessibilityDemoPage> {
  final MapLibreMapController _controller = MapLibreMapController();

  bool _semanticsEnabled = true;
  bool _speakCentre = false;
  bool _speakBearing = false;
  bool _controlsExpanded = false;
  bool _showControls = true;
  bool _keyboard = true;
  bool _reduceMotion = false;
  bool _highContrast = false;
  bool _showDebugger = false;
  bool _showList = true;
  MapSemanticsAnnouncements _announce =
      MapSemanticsAnnouncements.accessibilityActions;

  static const List<MapLibreMarker> _markers = <MapLibreMarker>[
    MapLibreMarker(
      point: LatLng(60.1699, 24.9384),
      semanticLabel: 'Helsinki',
      semanticValue: 'Capital of Finland',
      child: Icon(Icons.place, color: Color(0xFFD32F2F), size: 32),
    ),
    MapLibreMarker(
      point: LatLng(59.437, 24.7536),
      semanticLabel: 'Tallinn',
      semanticValue: 'Capital of Estonia',
      draggable: true,
      child: Icon(Icons.place, color: Color(0xFF1565C0), size: 32),
    ),
    // No semanticLabel on purpose: this one demonstrates the default, where the
    // child's own tree is left exactly as the app wrote it.
    MapLibreMarker(
      point: LatLng(59.3293, 18.0686),
      child: Text('🇸🇪', style: TextStyle(fontSize: 28)),
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final map = MapLibreMap(
      controller: _controller,
      style: _style,
      options: const MapOptions(
        initialCamera: MapCamera(center: LatLng(59.9, 22), zoom: 5),
      ),
      markers: _markers,
      semantics: _semanticsEnabled
          ? MapLibreSemantics(
              value: MapCameraSummaryValue(
                center: _speakCentre,
                bearing: _speakBearing,
              ),
              announcements: _announce,
            )
          : const MapLibreSemantics.excluded(),
      controls: _showControls
          ? (_controlsExpanded
                ? const MapControls.expanded()
                : const MapControls())
          : const MapControls.none(),
      keyboard: _keyboard ? const MapKeyboard() : const MapKeyboard.disabled(),
      onAttributionTap: (url) => ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(url))),
    );

    // The OS settings are simulated here rather than only read, so the whole
    // matrix is testable on one machine without diving into System Settings
    // between every case.
    final mq = MediaQuery.of(context);
    Widget body = MediaQuery(
      data: mq.copyWith(
        disableAnimations: _reduceMotion || mq.disableAnimations,
        highContrast: _highContrast || mq.highContrast,
      ),
      child: map,
    );
    // Flutter's own tool, which draws the real semantics rects. Reimplementing
    // it would have been the wrong instinct — the gap was discoverability.
    if (_showDebugger) body = SemanticsDebugger(child: body);

    return Scaffold(
      appBar: AppBar(title: const Text('Accessibility')),
      body: Column(
        children: <Widget>[
          Expanded(flex: 3, child: body),
          if (_showList)
            Expanded(
              flex: 2,
              child: DecoratedBox(
                decoration: const BoxDecoration(color: Color(0xFFF5F5F5)),
                child: MapLibreFeatureList(
                  controller: _controller,
                  markers: _markers,
                ),
              ),
            ),
          SizedBox(
            height: 168,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: <Widget>[_toggles(), _announcePicker()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggles() => Wrap(
    spacing: 4,
    children: <Widget>[
      _chip('Semantics', _semanticsEnabled, (v) => _semanticsEnabled = v),
      _chip('Speak centre', _speakCentre, (v) => _speakCentre = v),
      _chip('Speak bearing', _speakBearing, (v) => _speakBearing = v),
      _chip('Controls', _showControls, (v) => _showControls = v),
      _chip(
        'Controls expanded',
        _controlsExpanded,
        (v) => _controlsExpanded = v,
      ),
      _chip('Keyboard', _keyboard, (v) => _keyboard = v),
      _chip('Reduce motion', _reduceMotion, (v) => _reduceMotion = v),
      _chip('High contrast', _highContrast, (v) => _highContrast = v),
      _chip('Semantics debugger', _showDebugger, (v) => _showDebugger = v),
      _chip('Alternative list', _showList, (v) => _showList = v),
    ],
  );

  Widget _chip(String label, bool value, ValueChanged<bool> onChanged) =>
      FilterChip(
        label: Text(label),
        selected: value,
        onSelected: (v) => setState(() => onChanged(v)),
      );

  Widget _announcePicker() => Row(
    children: <Widget>[
      const Text('Announce: '),
      for (final mode in MapSemanticsAnnouncements.values)
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: ChoiceChip(
            label: Text(mode.name),
            selected: _announce == mode,
            onSelected: (_) => setState(() => _announce = mode),
          ),
        ),
    ],
  );
}
