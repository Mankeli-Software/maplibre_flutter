import 'dart:async';

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import '../maplibre_map_controller.dart';

/// Keyboard control of the camera — gl-js `KeyboardHandler`.
///
/// The map is unreachable by keyboard without this, on every desktop tier and
/// on web, which is a WCAG 2.2 SC 2.1.1 (Level A) failure on its own. It also
/// serves sighted keyboard-only and switch-access users who never touch a
/// screen reader.
@immutable
class MapKeyboard {
  const MapKeyboard({
    this.enabled = true,
    this.rotateEnabled = true,
    this.panStep = 100.0,
    this.bearingStep = 15.0,
    this.pitchStep = 10.0,
  });

  const MapKeyboard.disabled()
    : enabled = false,
      rotateEnabled = false,
      panStep = 100.0,
      bearingStep = 15.0,
      pitchStep = 10.0;

  /// Whether the map takes focus and handles keys at all.
  final bool enabled;

  /// Whether `Shift` + arrows rotate and tilt — gl-js
  /// `KeyboardHandler.disableRotation()`. Named with the `…Enabled` suffix per
  /// the API naming policy rather than gl-js's handler-method spelling.
  final bool rotateEnabled;

  /// Logical pixels per arrow press — gl-js `panStep`, same default.
  final double panStep;

  /// Degrees per `Shift`+left/right — gl-js `bearingStep`, same default.
  final double bearingStep;

  /// Degrees per `Shift`+up/down — gl-js `pitchStep`, same default.
  final double pitchStep;
}

/// Gives the map a focus node, a visible focus ring and gl-js's key bindings.
@internal
class MapLibreMapKeyboard extends StatefulWidget {
  const MapLibreMapKeyboard({
    required this.controller,
    required this.keyboard,
    required this.child,
    this.focusNode,
    this.autofocus = false,
    super.key,
  });

  final MapLibreMapController controller;
  final MapKeyboard keyboard;
  final FocusNode? focusNode;
  final bool autofocus;
  final Widget child;

  @override
  State<MapLibreMapKeyboard> createState() => _MapLibreMapKeyboardState();
}

class _MapLibreMapKeyboardState extends State<MapLibreMapKeyboard> {
  FocusNode? _internalNode;
  FocusNode get _node => widget.focusNode ?? (_internalNode ??= FocusNode());
  bool _showRing = false;

  /// gl-js's `KeyboardHandler` duration, copied exactly.
  ///
  /// Its easing is NOT copied, and that is a limit rather than a choice: gl-js
  /// eases with `t * (2 - t)`, a quadratic, while our `easing` parameter takes
  /// a [Cubic] because it maps 1:1 onto mbgl's `UnitBezier`. No cubic Bézier
  /// reproduces that quadratic exactly, so the engine default applies and a
  /// keyboard pan is a few milliseconds' worth of curve away from gl-js's.
  static const Duration _duration = Duration(milliseconds: 300);

  @override
  void dispose() {
    _internalNode?.dispose();
    super.dispose();
  }

  void _pan(Offset fingerDelta) => unawaited(
    widget.controller.camera.panBy(fingerDelta, duration: _duration),
  );

  Future<void> _zoomBy(double levels) async {
    final camera = await widget.controller.camera.getCamera();
    await widget.controller.camera.zoomTo(
      camera.zoom + levels,
      duration: _duration,
    );
  }

  Future<void> _rotateBy(double degrees) async {
    final camera = await widget.controller.camera.getCamera();
    await widget.controller.camera.rotateTo(
      camera.bearing + degrees,
      duration: _duration,
    );
  }

  Future<void> _pitchBy(double degrees) async {
    final camera = await widget.controller.camera.getCamera();
    await widget.controller.camera.easeTo(
      CameraOptions(pitch: (camera.pitch + degrees).clamp(0.0, 60.0)),
      duration: _duration,
      easing: null,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (!widget.keyboard.enabled) return KeyEventResult.ignored;

    final keys = HardwareKeyboard.instance;
    // gl-js's very first statement, and it is what keeps OS and browser
    // shortcuts working over a focused map.
    if (keys.isAltPressed || keys.isControlPressed || keys.isMetaPressed) {
      return KeyEventResult.ignored;
    }

    final shift = keys.isShiftPressed;
    final k = event.logicalKey;
    final kb = widget.keyboard;

    // Under directional navigation the arrows belong to focus traversal — this
    // is a TV or a tvOS-style host, and stealing them strands the user.
    final directional =
        MediaQuery.maybeNavigationModeOf(context) == NavigationMode.directional;

    if (k == LogicalKeyboardKey.arrowUp) {
      if (shift) {
        if (!kb.rotateEnabled) return KeyEventResult.ignored;
        unawaited(_pitchBy(kb.pitchStep));
      } else {
        if (directional) return KeyEventResult.ignored;
        // Dragging the map DOWN reveals what is north of it, and panBy takes a
        // finger delta — so "north" is a positive dy.
        _pan(Offset(0, kb.panStep));
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (shift) {
        if (!kb.rotateEnabled) return KeyEventResult.ignored;
        unawaited(_pitchBy(-kb.pitchStep));
      } else {
        if (directional) return KeyEventResult.ignored;
        _pan(Offset(0, -kb.panStep));
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (shift) {
        if (!kb.rotateEnabled) return KeyEventResult.ignored;
        unawaited(_rotateBy(-kb.bearingStep));
      } else {
        if (directional) return KeyEventResult.ignored;
        _pan(Offset(kb.panStep, 0));
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      if (shift) {
        if (!kb.rotateEnabled) return KeyEventResult.ignored;
        unawaited(_rotateBy(kb.bearingStep));
      } else {
        if (directional) return KeyEventResult.ignored;
        _pan(Offset(-kb.panStep, 0));
      }
      return KeyEventResult.handled;
    }

    // `+`, `=` and `-` are single-character shortcuts, which SC 2.1.4 allows
    // only under the active-on-focus-only exception. This handler lives on the
    // map's own FocusNode and is never installed through
    // HardwareKeyboard.addHandler, so that exception holds by construction
    // rather than by discipline.
    if (k == LogicalKeyboardKey.equal ||
        k == LogicalKeyboardKey.add ||
        k == LogicalKeyboardKey.numpadAdd) {
      unawaited(_zoomBy(shift ? 2 : 1));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.minus ||
        k == LogicalKeyboardKey.numpadSubtract) {
      unawaited(_zoomBy(shift ? -2 : -1));
      return KeyEventResult.handled;
    }

    // Tab, Shift+Tab and everything else pass through. That is SC 2.1.2, No
    // Keyboard Trap.
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.keyboard.enabled) return widget.child;
    final highContrast = MediaQuery.highContrastOf(context);
    return FocusableActionDetector(
      focusNode: _node,
      autofocus: widget.autofocus,
      onShowFocusHighlight: (show) {
        if (show != _showRing) setState(() => _showRing = show);
      },
      onFocusChange: (focused) {
        // Mirrors gl-js's window `blur` handler: without it a held arrow key
        // survives an app switch and the map keeps moving after the user has
        // gone somewhere else.
        if (!focused) unawaited(widget.controller.camera.stop());
      },
      // FocusableActionDetector owns the node, so the key handler goes on the
      // node rather than into a competing Focus wrapper.
      descendantsAreFocusable: true,
      child: Builder(
        builder: (context) {
          _node.onKeyEvent = _onKey;
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              widget.child,
              if (_showRing)
                // Drawn as an overlay because we cannot draw into the texture.
                // gl-js's canvas has no focus style at all, so this is a
                // straight win over upstream rather than parity with it.
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: highContrast
                              ? const Color(0xFF000000)
                              : const Color(0xFF1565C0),
                          width: highContrast ? 4 : 3,
                        ),
                      ),
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
