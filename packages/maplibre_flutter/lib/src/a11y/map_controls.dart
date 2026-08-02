import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/widgets.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import '../maplibre_map_controller.dart';
import 'locale.dart';

/// When the compass button is shown.
enum MapCompassVisibility {
  /// Never — the app draws its own, or the map cannot rotate.
  hidden,

  /// Only when the map is not north-up. Apple's `MLNCompassButton` rule.
  whenRotated,

  /// Always, so its position never shifts under a returning user.
  always,
}

/// Whether the cluster starts collapsed behind one button.
enum MapControlsPresentation {
  /// One 48×48 disclosure button that expands to the full pad.
  ///
  /// WCAG requires the single-pointer alternative to be **operable and
  /// programmatically discoverable**, not permanently visible — and this is the
  /// difference between a default a designer keeps and a default a designer
  /// deletes. Note the trade honestly: a Voice Control user must say "Show map
  /// controls" before they can say "Zoom in", so [MapControls.expanded] is the
  /// better setting for kiosk and assisted-use apps.
  collapsible,

  /// Everything visible immediately.
  expanded,
}

/// The single-pointer alternatives to the map's multipoint gestures.
///
/// **On by default, and that is the most consequential decision in this
/// package's accessibility work.** WCAG 2.2 SC 2.5.1 Pointer Gestures (Level A)
/// and SC 2.5.7 Dragging Movements (AA) are *pointer* criteria: no amount of
/// `Semantics` discharges them, and the obligation is created by the
/// pinch-zoom, two-finger rotate and two-finger shove that **this package
/// ships**. Shipping those with no single-pointer alternative hands every
/// consumer a conformance failure they did not choose and probably cannot see.
///
/// The precedent is exact — `MapLibreMap.showAttribution` already defaults true
/// because displaying a credit is a licence condition.
///
/// Use [MapControls.none] to opt out; the app then owns 2.5.1 and 2.5.7.
@immutable
class MapControls {
  const MapControls({
    this.zoom = true,
    this.compass = MapCompassVisibility.whenRotated,
    this.pan = true,
    this.pitch = true,
    this.presentation = MapControlsPresentation.collapsible,
    this.alignment = Alignment.topRight,
    this.padding = const EdgeInsets.all(8),
  });

  /// Ship nothing. **The app then owns SC 2.5.1 and SC 2.5.7** — it must
  /// provide its own single-pointer path to zoom, rotate, tilt and pan, or the
  /// map is a Level A failure.
  const MapControls.none()
    : zoom = false,
      compass = MapCompassVisibility.hidden,
      pan = false,
      pitch = false,
      presentation = MapControlsPresentation.expanded,
      alignment = Alignment.topRight,
      padding = const EdgeInsets.all(8);

  /// Everything visible with no disclosure step — the recommended setting for
  /// kiosk, assisted-use and voice-control-heavy apps.
  const MapControls.expanded()
    : zoom = true,
      compass = MapCompassVisibility.always,
      pan = true,
      pitch = true,
      presentation = MapControlsPresentation.expanded,
      alignment = Alignment.topRight,
      padding = const EdgeInsets.all(8);

  /// Plus and minus buttons — the 2.5.1 alternative to pinch-zoom.
  final bool zoom;

  /// The compass, which resets north — the 2.5.1 alternative to two-finger
  /// rotate.
  final MapCompassVisibility compass;

  /// A four-way pad — the 2.5.7 alternative to drag-panning.
  final bool pan;

  /// Tilt up and down — the 2.5.1 alternative to the two-finger shove.
  final bool pitch;

  final MapControlsPresentation presentation;
  final Alignment alignment;
  final EdgeInsets padding;

  bool get _anyVisible =>
      zoom || pan || pitch || compass != MapCompassVisibility.hidden;
}

/// Paints the control glyphs.
///
/// Deliberately drawn rather than set in an icon font: an `Icon` needs the
/// Material icon font to be present, and this package must work in an app built
/// on `WidgetsApp`. Drawing also means the stroke weight can respond to
/// `MediaQuery.highContrastOf` without hunting for a heavier glyph.
enum _Glyph { plus, minus, chevron, compass, tiltUp, tiltDown, controls }

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(
    this.glyph, {
    required this.color,
    required this.strokeWidth,
    this.rotation = 0,
  });

  final _Glyph glyph;
  final Color color;
  final double strokeWidth;

  /// Radians, clockwise. Used for the pan chevrons and the compass needle.
  final double rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas
      ..save()
      ..translate(centre.dx, centre.dy)
      ..rotate(rotation);

    const arm = 6.0;
    switch (glyph) {
      case _Glyph.plus:
        canvas
          ..drawLine(const Offset(-arm, 0), const Offset(arm, 0), paint)
          ..drawLine(const Offset(0, -arm), const Offset(0, arm), paint);
      case _Glyph.minus:
        canvas.drawLine(const Offset(-arm, 0), const Offset(arm, 0), paint);
      case _Glyph.chevron:
        // Points UP before rotation.
        canvas.drawPath(
          Path()
            ..moveTo(-arm, arm / 2)
            ..lineTo(0, -arm / 2)
            ..lineTo(arm, arm / 2),
          paint,
        );
      case _Glyph.compass:
        // A needle whose north half is filled, so the direction survives being
        // seen without colour.
        canvas
          ..drawPath(
            Path()
              ..moveTo(0, -arm - 2)
              ..lineTo(arm - 2, arm)
              ..lineTo(0, arm / 2)
              ..close(),
            Paint()..color = color,
          )
          ..drawPath(
            Path()
              ..moveTo(0, -arm - 2)
              ..lineTo(-(arm - 2), arm)
              ..lineTo(0, arm / 2)
              ..close(),
            paint..style = PaintingStyle.stroke,
          );
      case _Glyph.tiltUp:
      case _Glyph.tiltDown:
        // A horizon line plus a chevron away from it.
        final sign = glyph == _Glyph.tiltUp ? -1.0 : 1.0;
        canvas
          ..drawLine(const Offset(-arm, 2), const Offset(arm, 2), paint)
          ..drawPath(
            Path()
              ..moveTo(-arm / 2, sign * arm - 2)
              ..lineTo(0, sign * (arm + 3) - 2)
              ..lineTo(arm / 2, sign * arm - 2),
            paint,
          );
      case _Glyph.controls:
        for (final dy in <double>[-arm / 1.5, 0, arm / 1.5]) {
          canvas.drawLine(Offset(-arm, dy), Offset(arm, dy), paint);
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph ||
      old.color != color ||
      old.rotation != rotation ||
      old.strokeWidth != strokeWidth;
}

/// One control button.
///
/// **48×48 minimum**, which is Android's guideline and above both WCAG 2.5.8's
/// 24×24 and Apple's 44×44. gl-js ships 29×29 and that is its still-open
/// accessibility issue #363.
///
/// A null [onPressed] renders and announces as **disabled** — one property
/// gives the visual, `SemanticsFlag.hasEnabledState` and `isEnabled` together.
/// gl-js needs two explicit calls for that and forgetting them was its WCAG
/// issue #361.
class MapLibreControlButton extends StatelessWidget {
  const MapLibreControlButton({
    required this.semanticLabel,
    required this.child,
    super.key,
    this.onPressed,
    this.size = 48,
  });

  final String semanticLabel;
  final Widget child;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final highContrast = MediaQuery.highContrastOf(context);
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      onTap: onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        // Opaque, or the map beneath takes the tap: decoration is paint, and
        // paint has no bearing on hit testing.
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: highContrast
                  ? const Color(0xFFFFFFFF)
                  : const Color(0xF2FFFFFF),
              borderRadius: BorderRadius.circular(4),
              border: highContrast
                  ? Border.all(color: const Color(0xFF000000), width: 2)
                  : null,
            ),
            child: Opacity(opacity: enabled ? 1.0 : 0.35, child: child),
          ),
        ),
      ),
    );
  }
}

/// The shipped control cluster.
@internal
class MapLibreMapControls extends StatefulWidget {
  const MapLibreMapControls({
    required this.controller,
    required this.controls,
    required this.locale,
    required this.rotateEnabled,
    required this.tiltEnabled,
    super.key,
  });

  final MapLibreMapController controller;
  final MapControls controls;
  final MapLibreLocale locale;
  final bool rotateEnabled;
  final bool tiltEnabled;

  @override
  State<MapLibreMapControls> createState() => _MapLibreMapControlsState();
}

class _MapLibreMapControlsState extends State<MapLibreMapControls> {
  MapCamera _camera = const MapCamera(center: LatLng(0, 0));
  MapCameraConstraints? _constraints;
  StreamSubscription<void>? _moves;
  late bool _expanded =
      widget.controls.presentation == MapControlsPresentation.expanded;

  @override
  void initState() {
    super.initState();
    _moves = widget.controller.onCameraMoveEnd.listen((_) => _sync());
    unawaited(_sync());
    unawaited(_loadConstraints());
  }

  @override
  void dispose() {
    _moves?.cancel();
    super.dispose();
  }

  Future<void> _sync() async {
    try {
      final camera = await widget.controller.camera.getCamera();
      if (mounted && camera != _camera) setState(() => _camera = camera);
    } on Object {
      // A controller torn down mid-flight is not a control failure.
    }
  }

  Future<void> _loadConstraints() async {
    try {
      final c = await widget.controller.camera.getConstraints();
      if (mounted) setState(() => _constraints = c);
    } on Object {
      // Constraints are an optimisation here; without them the zoom buttons
      // simply never render disabled.
    }
  }

  bool get _canZoomIn {
    final max = _constraints?.maxZoom;
    return max == null || _camera.zoom < max - 0.001;
  }

  bool get _canZoomOut {
    final min = _constraints?.minZoom;
    return min == null || _camera.zoom > min + 0.001;
  }

  String _s(String key) => widget.locale.getUIString(key);

  Widget _glyph(_Glyph glyph, {double rotation = 0}) => Builder(
    builder: (context) => CustomPaint(
      painter: _GlyphPainter(
        glyph,
        color: const Color(0xDD000000),
        strokeWidth: MediaQuery.highContrastOf(context) ? 2.6 : 1.8,
        rotation: rotation,
      ),
    ),
  );

  void _pan(Offset fingerDelta) =>
      unawaited(widget.controller.camera.panBy(fingerDelta));

  double get _panStep {
    final size = context.size;
    return (size == null ? 200.0 : math.min(size.width, size.height)) * 0.5;
  }

  Future<void> _zoomBy(double levels) async {
    final camera = await widget.controller.camera.getCamera();
    await widget.controller.camera.zoomTo(camera.zoom.roundToDouble() + levels);
  }

  Future<void> _pitchBy(double degrees) async {
    final camera = await widget.controller.camera.getCamera();
    await widget.controller.camera.easeTo(
      CameraOptions(pitch: (camera.pitch + degrees).clamp(0.0, 60.0)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controls;
    if (!c._anyVisible) return const SizedBox.shrink();

    final showCompass = switch (c.compass) {
      MapCompassVisibility.hidden => false,
      // Auto-suppressed when the gesture it substitutes for is disabled — a map
      // that cannot rotate must not grow a button that resets a rotation it can
      // never have.
      MapCompassVisibility.always => widget.rotateEnabled,
      MapCompassVisibility.whenRotated =>
        widget.rotateEnabled && _camera.bearing % 360 != 0,
    };

    final children = <Widget>[
      if (c.zoom) ...<Widget>[
        MapLibreControlButton(
          semanticLabel: _s('NavigationControl.ZoomIn'),
          onPressed: _canZoomIn ? () => unawaited(_zoomBy(1)) : null,
          child: _glyph(_Glyph.plus),
        ),
        MapLibreControlButton(
          semanticLabel: _s('NavigationControl.ZoomOut'),
          onPressed: _canZoomOut ? () => unawaited(_zoomBy(-1)) : null,
          child: _glyph(_Glyph.minus),
        ),
      ],
      if (showCompass)
        MapLibreControlButton(
          semanticLabel: _s('COMPASS_A11Y_LABEL'),
          onPressed: () => unawaited(widget.controller.camera.resetNorth()),
          // The needle turns with the map, so the button reports the bearing
          // rather than merely offering to reset it. The Android SDK rotates
          // its compass and never updates its contentDescription, so TalkBack
          // there can never say which way the map faces.
          child: _glyph(
            _Glyph.compass,
            rotation: -_camera.bearing * math.pi / 180,
          ),
        ),
      if (c.pitch && widget.tiltEnabled) ...<Widget>[
        MapLibreControlButton(
          semanticLabel: _s('Action.TiltUp'),
          onPressed: _camera.pitch < 60 ? () => unawaited(_pitchBy(10)) : null,
          child: _glyph(_Glyph.tiltUp),
        ),
        MapLibreControlButton(
          semanticLabel: _s('Action.TiltDown'),
          onPressed: _camera.pitch > 0 ? () => unawaited(_pitchBy(-10)) : null,
          child: _glyph(_Glyph.tiltDown),
        ),
      ],
      if (c.pan) _panPad(),
    ];

    final cluster = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        for (final child in children)
          Padding(padding: const EdgeInsets.only(bottom: 4), child: child),
      ],
    );

    final Widget body;
    if (c.presentation == MapControlsPresentation.collapsible && !_expanded) {
      body = MapLibreControlButton(
        semanticLabel: _s('Controls.Expand'),
        onPressed: () => setState(() => _expanded = true),
        child: _glyph(_Glyph.controls),
      );
    } else if (c.presentation == MapControlsPresentation.collapsible) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: MapLibreControlButton(
              semanticLabel: _s('Controls.Collapse'),
              onPressed: () => setState(() => _expanded = false),
              child: _glyph(_Glyph.controls),
            ),
          ),
          cluster,
        ],
      );
    } else {
      body = cluster;
    }

    return Align(
      alignment: c.alignment,
      child: Padding(padding: c.padding, child: body),
    );
  }

  /// Four chevrons. This is the SC 2.5.7 discharge: a path-free, single-pointer
  /// way to move the view that a drag-only map does not have.
  Widget _panPad() {
    Widget arrow(String key, double rotation, Offset Function() delta) =>
        MapLibreControlButton(
          semanticLabel: _s(key),
          onPressed: () => _pan(delta()),
          child: _glyph(_Glyph.chevron, rotation: rotation),
        );

    // Dragging the map DOWN reveals what is north of it, and panBy takes a
    // finger delta — so "north" is a positive dy.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        arrow('Action.PanNorth', 0, () => Offset(0, _panStep)),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            arrow('Action.PanWest', -math.pi / 2, () => Offset(_panStep, 0)),
            SizedBox(width: 48, height: 48),
            arrow('Action.PanEast', math.pi / 2, () => Offset(-_panStep, 0)),
          ],
        ),
        arrow('Action.PanSouth', math.pi, () => Offset(0, -_panStep)),
      ],
    );
  }
}
