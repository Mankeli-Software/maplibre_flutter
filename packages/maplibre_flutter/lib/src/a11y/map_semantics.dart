import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart'
    show Assertiveness, CustomSemanticsAction, SemanticsBinding, SemanticsRole;
import 'package:flutter/widgets.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import '../maplibre_map_controller.dart';
import 'announcer.dart';
import 'formatters.dart';
import 'locale.dart';

/// How much of the map is actually on screen.
///
/// **A failed style and the middle of the Pacific produce the same camera
/// summary** — "Zoom 12. 0 markers visible." — and a sighted user tells them
/// apart instantly. Without this the spoken map reproduces maplibre-gl-js's
/// most-complained-about gap: it announces no errors, anywhere.
enum MapLoadState {
  /// No style has finished loading yet.
  loading,

  /// A style is loaded and nothing has reported a failure.
  ready,

  /// Loaded, but something under it failed — a missing sprite, a source that
  /// would not resolve. The map is usable and incomplete.
  degraded,

  /// The style itself failed. There is nothing to look at.
  failed,
}

/// Everything the spoken map value and the accessible feature list are built
/// from, so the two can never disagree about what is on screen.
///
/// Apple's do disagree: `-[MLNMapView accessibilityValue]` reads the raw `name`
/// attribute while its per-feature elements read the localized, transliterated
/// `name_<lang>`, so the same place is announced under two different names
/// depending on how you reached it.
@immutable
class MapSemanticsSummary {
  const MapSemanticsSummary({
    required this.camera,
    required this.viewport,
    this.visibleMarkerCount = 0,
    this.loadState = MapLoadState.ready,
  });

  final MapCamera camera;
  final Size viewport;
  final int visibleMarkerCount;
  final MapLoadState loadState;

  /// The default spoken value, a port of `-[MLNMapView accessibilityValue]`
  /// with its two defects removed (see [MapCameraSummaryValue]).
  String describe(
    MapLibreLocale locale, {
    MapCameraSummaryValue parts = const MapCameraSummaryValue(),
  }) {
    final facts = <String>[];

    // Load state leads, because it changes what everything after it means.
    switch (loadState) {
      case MapLoadState.loading:
        facts.add(locale.getUIString('Map.Loading'));
      case MapLoadState.failed:
        facts.add(locale.getUIString('Map.LoadFailed'));
      case MapLoadState.degraded:
        facts.add(locale.getUIString('Map.PartiallyLoaded'));
      case MapLoadState.ready:
        break;
    }

    if (parts.zoom) {
      facts.add(
        locale.getUIString(
          'Map.ValueZoom',
          args: <String, Object?>{'zoom': camera.zoom.round()},
        ),
      );
    }
    if (parts.center) {
      facts.add(
        locale.getUIString(
          'Map.ValueCenter',
          args: <String, Object?>{
            'coordinate': formatCoordinate(
              camera.center,
              zoom: camera.zoom,
              locale: locale,
            ),
          },
        ),
      );
    }
    // Only when there is something to say: "Facing north" on every settle of a
    // north-up map is noise, and the utterance is already long.
    if (parts.bearing && camera.bearing % 360 != 0) {
      facts.add(
        locale.getUIString(
          'Map.ValueBearing',
          args: <String, Object?>{
            'direction': compassDirectionName(camera.bearing, locale: locale),
          },
        ),
      );
    }
    if (parts.pitch && camera.pitch != 0) {
      facts.add(
        locale.getUIString(
          'Map.ValuePitch',
          args: <String, Object?>{'pitch': camera.pitch.round()},
        ),
      );
    }
    if (parts.markerCount) {
      facts.add(
        locale.plural('MAP_A11Y_VALUE_ANNOTATIONS', visibleMarkerCount),
      );
    }
    return facts.join(' ');
  }

  MapSemanticsSummary copyWith({
    MapCamera? camera,
    Size? viewport,
    int? visibleMarkerCount,
    MapLoadState? loadState,
  }) => MapSemanticsSummary(
    camera: camera ?? this.camera,
    viewport: viewport ?? this.viewport,
    visibleMarkerCount: visibleMarkerCount ?? this.visibleMarkerCount,
    loadState: loadState ?? this.loadState,
  );
}

/// What the map node speaks as its value.
@immutable
sealed class MapSemanticsValue {
  const MapSemanticsValue();
}

/// Facts about the camera, joined into one sentence.
///
/// **Two deliberate divergences from Apple**, both defects there rather than
/// choices: it speaks `round(zoomLevel + 1)`, so its spoken zoom disagrees with
/// its own `zoomLevel` property; and it reads the raw `name` attribute in the
/// summary while its elements read the localized one.
///
/// [center], [bearing] and [pitch] are off by default because this string is
/// spoken on **every** camera settle, and a six-fact utterance is worse than a
/// two-fact one for exactly the users most likely to be listening to it.
@immutable
final class MapCameraSummaryValue extends MapSemanticsValue {
  const MapCameraSummaryValue({
    this.zoom = true,
    this.markerCount = true,
    this.center = false,
    this.bearing = false,
    this.pitch = false,
  });

  final bool zoom;
  final bool markerCount;
  final bool center;
  final bool bearing;
  final bool pitch;
}

/// The app composes the value itself from the same summary the map uses.
@immutable
final class MapCustomValue extends MapSemanticsValue {
  const MapCustomValue(this.builder);
  final String Function(MapSemanticsSummary summary, MapLibreLocale locale)
  builder;
}

/// The map node carries a label and no value.
@immutable
final class MapNoValue extends MapSemanticsValue {
  const MapNoValue();
}

/// Accessibility configuration for [MapLibreMap].
///
/// **Bucket: widget prop** (CLAUDE.md §3) — mutable, declarative,
/// low-frequency. It cannot live in [MapOptions]: that is init-only and handed
/// to `createMap`, so it never reaches the widget layer where every one of
/// these strings is actually consumed. Same reasoning as
/// `rotateGesturesEnabled`.
@immutable
class MapLibreSemantics {
  const MapLibreSemantics({
    this.enabled = true,
    this.label,
    this.hint,
    this.identifier = 'maplibre.map',
    this.value = const MapCameraSummaryValue(),
    this.announcements = MapSemanticsAnnouncements.accessibilityActions,
    this.haptics = true,
    this.zoomStep = 1.0,
    this.scrollStep = 0.5,
    this.bearingStep = 15.0,
    this.pitchStep = 10.0,
    this.settleDelay = const Duration(milliseconds: 100),
  });

  /// Publish nothing at all — the escape hatch for an app that describes the
  /// map itself, in its own words, somewhere else in its tree.
  const MapLibreSemantics.excluded()
    : enabled = false,
      label = null,
      hint = null,
      identifier = 'maplibre.map',
      value = const MapNoValue(),
      announcements = MapSemanticsAnnouncements.never,
      haptics = false,
      zoomStep = 1.0,
      scrollStep = 0.5,
      bearingStep = 15.0,
      pitchStep = 10.0,
      settleDelay = const Duration(milliseconds: 100);

  /// Whether the map publishes a semantics node at all.
  final bool enabled;

  /// What the map is called. Null uses `Map.Title`, gl-js's default `"Map"`.
  ///
  /// **Must never resolve to empty.** `SemanticsRole.region` is checked at
  /// frame time and a region with no label throws.
  final String? label;

  /// How to operate it. Null uses `Map.Hint`.
  final String? hint;

  /// A stable id for UI automation and for the voice-control stacks that
  /// address elements by identifier rather than by label.
  final String identifier;

  /// What the node speaks as its value.
  final MapSemanticsValue value;

  /// When the map speaks unprompted. Defaults to Apple's model: only after an
  /// assistive-technology or keyboard action, never after a gesture.
  final MapSemanticsAnnouncements announcements;

  /// Whether an assistive-technology camera step gives a haptic pulse, with a
  /// distinct one when the step is refused at a zoom limit.
  final bool haptics;

  /// Zoom levels per increase/decrease. The result is snapped to an integer, as
  /// Apple does (`round(zoomLevel) + log2(scaleFactor)`), so repeated swipes
  /// land on clean levels instead of drifting.
  final double zoomStep;

  /// Fraction of the viewport moved per pan action.
  final double scrollStep;

  /// Degrees per rotate action — gl-js `KeyboardHandler.bearingStep`.
  final double bearingStep;

  /// Degrees per tilt action — gl-js `KeyboardHandler.pitchStep`.
  final double pitchStep;

  /// How long the camera must be quiet before the value is recomputed. Apple's
  /// exact 100 ms, and for the same reason: the query should see settled tiles.
  final Duration settleDelay;

  MapLibreSemantics copyWith({String? label, String? hint}) =>
      MapLibreSemantics(
        enabled: enabled,
        label: label ?? this.label,
        hint: hint ?? this.hint,
        identifier: identifier,
        value: value,
        announcements: announcements,
        haptics: haptics,
        zoomStep: zoomStep,
        scrollStep: scrollStep,
        bearingStep: bearingStep,
        pitchStep: pitchStep,
        settleDelay: settleDelay,
      );
}

/// Wraps the whole map — surface, controls, attribution and markers — in one
/// semantics region and wires the assistive-technology actions to the camera.
///
/// **Everything here is gated on [SemanticsBinding.semanticsEnabled].** With no
/// assistive technology running there is no subscription, no settle timer and
/// no `setState`, so a map that nobody is listening to costs exactly nothing.
@internal
class MapLibreMapSemantics extends StatefulWidget {
  const MapLibreMapSemantics({
    required this.controller,
    required this.semantics,
    required this.locale,
    required this.child,
    this.markerCount = 0,
    super.key,
  });

  final MapLibreMapController controller;
  final MapLibreSemantics semantics;
  final MapLibreLocale locale;
  final int markerCount;
  final Widget child;

  @override
  State<MapLibreMapSemantics> createState() => _MapLibreMapSemanticsState();
}

class _MapLibreMapSemanticsState extends State<MapLibreMapSemantics> {
  MapSemanticsSummary? _summary;

  /// **`ready` on a tier that reports no engine events**, not `loading`.
  ///
  /// Load state is only knowable where `onStyleLoaded`/`onError` actually fire
  /// (`MapLibreCapabilities.events`). Claiming `loading` on a tier that will
  /// never say otherwise leaves a perfectly good map announcing "Map loading."
  /// for its whole life — which is worse than saying nothing, because it is
  /// confidently wrong rather than merely quiet.
  late MapLoadState _loadState = widget.controller.capabilities.events
      ? MapLoadState.loading
      : MapLoadState.ready;
  Timer? _settle;

  /// Armed by an assistive-technology or keyboard action and consumed by the
  /// next recompute — Apple's pending-flag model, verbatim. It is what makes a
  /// swipe-to-zoom speak while a two-finger pan stays silent.
  bool _announcePending = false;
  final List<StreamSubscription<void>> _subs = <StreamSubscription<void>>[];
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(MapLibreMapSemantics old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      _unsubscribe();
      _subscribe();
    }
    if (old.markerCount != widget.markerCount) _scheduleRefresh();
  }

  @override
  void dispose() {
    _settle?.cancel();
    _unsubscribe();
    super.dispose();
  }

  void _subscribe() {
    if (!SemanticsBinding.instance.semanticsEnabled) return;
    final c = widget.controller;
    _subs
      ..add(c.onCameraMoveEnd.listen((_) => _scheduleRefresh()))
      ..add(
        c.onStyleLoaded.listen((_) {
          _loadState = MapLoadState.ready;
          _scheduleRefresh();
        }),
      )
      ..add(
        c.onStyleImageMissing.listen((_) {
          // The style is up; something in it is not. Never downgrade a failure.
          if (_loadState == MapLoadState.ready) {
            _loadState = MapLoadState.degraded;
            _scheduleRefresh();
          }
        }),
      )
      ..add(
        c.onError.listen((_) {
          _loadState = _loadState == MapLoadState.loading
              ? MapLoadState.failed
              : MapLoadState.degraded;
          _scheduleRefresh();
        }),
      );
    // The map may already be up when semantics come on mid-session.
    _scheduleRefresh();
  }

  void _unsubscribe() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  /// Recomputes the value once the camera is quiet.
  ///
  /// Defensive on purpose. `onIdle` is deliberately **not** required here: a
  /// spinning [MapLibreModel] keeps mbgl repainting forever, so a design that
  /// waited for idle would starve permanently. And a `followWithHeading`
  /// tracking mode fires `onCameraMoveEnd` at GPS rate for as long as it runs,
  /// which is why this coalesces to the newest state rather than queueing.
  void _scheduleRefresh() {
    if (!SemanticsBinding.instance.semanticsEnabled) return;
    _settle?.cancel();
    _settle = Timer(widget.semantics.settleDelay, _refresh);
  }

  Future<void> _refresh() async {
    if (_refreshing || !mounted) return;
    _refreshing = true;
    try {
      final camera = await widget.controller.camera.getCamera();
      if (!mounted) return;
      final size = context.size ?? Size.zero;
      final summary = MapSemanticsSummary(
        camera: camera,
        viewport: size,
        visibleMarkerCount: widget.markerCount,
        loadState: _loadState,
      );
      setState(() => _summary = summary);
      _maybeAnnounce(summary);
    } on Object {
      // A controller torn down mid-flight is not an accessibility failure.
    } finally {
      _refreshing = false;
    }
  }

  void _maybeAnnounce(MapSemanticsSummary summary) {
    final mode = widget.semantics.announcements;
    final wanted =
        mode == MapSemanticsAnnouncements.always ||
        (mode == MapSemanticsAnnouncements.accessibilityActions &&
            _announcePending);
    _announcePending = false;
    if (!wanted || !mounted) return;
    final message = _describe(summary);
    if (message.isEmpty) return;
    // A failed load is the one case that earns an interruption, and it is not
    // gesture-triggered, so it does not violate the restraint above.
    MapLibreSemanticsAnnouncer.announce(
      context,
      message,
      assertiveness: summary.loadState == MapLoadState.failed
          ? Assertiveness.assertive
          : Assertiveness.polite,
    );
  }

  /// Arms the announcement and confirms the step in the hand.
  void _armFeedback({bool refused = false}) {
    _announcePending = true;
    if (!widget.semantics.haptics) return;
    refused
        ? MapLibreSemanticsAnnouncer.refuseStep()
        : MapLibreSemanticsAnnouncer.confirmStep();
  }

  String _describe(MapSemanticsSummary summary) =>
      switch (widget.semantics.value) {
        MapNoValue() => '',
        MapCustomValue(:final builder) => builder(summary, widget.locale),
        MapCameraSummaryValue() => summary.describe(
          widget.locale,
          parts: widget.semantics.value as MapCameraSummaryValue,
        ),
      };

  // Both are FINGER directions, and that is the whole reason they line up:
  // Flutter documents onScrollDown as "a user moving their finger across the
  // screen from top to bottom", and camera.panBy takes a finger delta ("does
  // what dragging 100 px to the right does"). So a finger moving down drags the
  // map down and reveals what is NORTH of it — latitude increases.
  Offset get _step {
    final size = _summary?.viewport ?? Size.zero;
    final w = size.width == 0 ? 200.0 : size.width;
    final h = size.height == 0 ? 200.0 : size.height;
    return Offset(
      w * widget.semantics.scrollStep,
      h * widget.semantics.scrollStep,
    );
  }

  void _pan(Offset fingerDelta) {
    _armFeedback();
    unawaited(widget.controller.camera.panBy(fingerDelta));
  }

  Future<void> _zoomBy(double levels) async {
    final camera = await widget.controller.camera.getCamera();
    final limits = await widget.controller.camera.getConstraints();
    final target = camera.zoom.roundToDouble() + levels;
    final refused =
        (limits?.maxZoom != null && target > limits!.maxZoom!) ||
        (limits?.minZoom != null && target < limits!.minZoom!);
    _armFeedback(refused: refused);
    if (refused) return;
    // Snap to an integer first, exactly as Apple does, so repeated swipes land
    // on clean levels rather than drifting by whatever fraction a pinch left.
    await widget.controller.camera.zoomTo(target);
  }

  Future<void> _rotateBy(double degrees) async {
    _armFeedback();
    final camera = await widget.controller.camera.getCamera();
    await widget.controller.camera.rotateTo(camera.bearing + degrees);
  }

  Future<void> _pitchBy(double degrees) async {
    _armFeedback();
    final camera = await widget.controller.camera.getCamera();
    await widget.controller.camera.easeTo(
      CameraOptions(pitch: (camera.pitch + degrees).clamp(0.0, 60.0)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.semantics;
    if (!s.enabled || !SemanticsBinding.instance.semanticsEnabled) {
      return widget.child;
    }

    final summary = _summary;
    final value = summary == null ? '' : _describe(summary);
    final locale = widget.locale;
    final label = s.label ?? locale.getUIString('Map.Title');

    // Flutter asserts that value and increasedValue are empty together, so a
    // map with no value yet must offer no adjustable strings either.
    final String increased;
    final String decreased;
    if (value.isEmpty || summary == null) {
      increased = '';
      decreased = '';
    } else {
      increased = _describe(
        summary.copyWith(
          camera: _withZoom(
            summary.camera,
            summary.camera.zoom.roundToDouble() + s.zoomStep,
          ),
        ),
      );
      decreased = _describe(
        summary.copyWith(
          camera: _withZoom(
            summary.camera,
            summary.camera.zoom.roundToDouble() - s.zoomStep,
          ),
        ),
      );
    }

    // THE ANDROID CONSTRAINT. AccessibilityBridge lowers SCROLL_LEFT, SCROLL_UP
    // and INCREASE all onto ACTION_SCROLL_FORWARD, and dispatches them through
    // a first-match chain with SCROLL_UP first — so a node carrying both scroll
    // and increase makes ZOOM UNREACHABLE on Android, silently, while a widget
    // test asserting both actions exist passes. Zoom is the more valuable
    // adjustable and it is the one Apple chose, so Android gets increase and
    // decrease only; panning is still reachable there through the custom
    // actions below, which TalkBack surfaces in its local context menu without
    // collision. This is a Flutter ENGINE fact, not a renderer fact — it would
    // be identical behind a platform view — so it does not belong behind the
    // platform interface.
    final bool scrollActions = defaultTargetPlatform != TargetPlatform.android;
    final step = _step;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      role: SemanticsRole.region,
      identifier: s.identifier,
      label: label,
      value: value,
      hint: s.hint ?? locale.getUIString('Map.Hint'),
      increasedValue: increased,
      decreasedValue: decreased,
      onIncrease: () => unawaited(_zoomBy(s.zoomStep)),
      onDecrease: () => unawaited(_zoomBy(-s.zoomStep)),
      onScrollDown: scrollActions ? () => _pan(Offset(0, step.dy)) : null,
      onScrollUp: scrollActions ? () => _pan(Offset(0, -step.dy)) : null,
      onScrollRight: scrollActions ? () => _pan(Offset(step.dx, 0)) : null,
      onScrollLeft: scrollActions ? () => _pan(Offset(-step.dx, 0)) : null,
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        // Dragging the map DOWN reveals what is north of it.
        CustomSemanticsAction(
          label: locale.getUIString('Action.PanNorth'),
        ): () =>
            _pan(Offset(0, step.dy)),
        CustomSemanticsAction(
          label: locale.getUIString('Action.PanSouth'),
        ): () =>
            _pan(Offset(0, -step.dy)),
        // Dragging the map LEFT reveals what is east of it.
        CustomSemanticsAction(
          label: locale.getUIString('Action.PanEast'),
        ): () =>
            _pan(Offset(-step.dx, 0)),
        CustomSemanticsAction(
          label: locale.getUIString('Action.PanWest'),
        ): () =>
            _pan(Offset(step.dx, 0)),
        CustomSemanticsAction(
          label: locale.getUIString('Action.RotateLeft'),
        ): () =>
            unawaited(_rotateBy(-s.bearingStep)),
        CustomSemanticsAction(
          label: locale.getUIString('Action.RotateRight'),
        ): () =>
            unawaited(_rotateBy(s.bearingStep)),
        CustomSemanticsAction(
          label: locale.getUIString('Action.ResetNorth'),
        ): () =>
            unawaited(widget.controller.camera.resetNorth()),
        CustomSemanticsAction(label: locale.getUIString('Action.TiltUp')): () =>
            unawaited(_pitchBy(s.pitchStep)),
        CustomSemanticsAction(
          label: locale.getUIString('Action.TiltDown'),
        ): () =>
            unawaited(_pitchBy(-s.pitchStep)),
        CustomSemanticsAction(
          label: locale.getUIString('Action.ResetTilt'),
        ): () =>
            unawaited(widget.controller.camera.resetPitch()),
      },
      child: widget.child,
    );
  }
}

MapCamera _withZoom(MapCamera camera, double zoom) => MapCamera(
  center: camera.center,
  zoom: zoom,
  bearing: camera.bearing,
  pitch: camera.pitch,
);
