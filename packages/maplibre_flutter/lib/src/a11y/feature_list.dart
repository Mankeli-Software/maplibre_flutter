import 'dart:async';

import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter/widgets.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import '../maplibre_map_controller.dart';
import '../marker.dart';
import 'formatters.dart';
import 'locale.dart';

/// A navigable, re-readable list of what is on the map.
///
/// **This is the accessible alternative the standards actually ask for.** WCAG
/// technique G92 wants a long description for complex non-text content, and the
/// Web Accessibility Directive's much-cited "maps exemption" is narrower than
/// it is usually quoted: it exempts the map surface only where *"essential
/// information is provided in an accessible digital manner"*. It requires this
/// pattern; it does not excuse its absence.
///
/// It is also **the braille surface**. A refreshable display shows about 40
/// cells at a time and cannot review a transient announcement at all, so a map
/// whose only non-visual output is speech is unusable on one — where a list is
/// re-readable, serial and navigable. Everything the map announces must also be
/// readable here.
///
/// Unlike the map surface this needs no custom semantics work to be operable:
/// it is ordinary Flutter widgets, so it reaches every tier including the two
/// where we defer to a native accessibility tree entirely.
class MapLibreFeatureList extends StatelessWidget {
  const MapLibreFeatureList({
    required this.controller,
    required this.markers,
    super.key,
    this.locale = const MapLibreLocale(),
    this.itemBuilder,
    this.emptyBuilder,
    this.onSelected,
    this.flyToOnSelect = true,
  });

  final MapLibreMapController controller;

  /// The same list handed to `MapLibreMap.markers`, so the list and the map can
  /// never disagree about what exists.
  final List<MapLibreMarker> markers;

  final MapLibreLocale locale;

  /// Renders one row. The default is a labelled, activatable line.
  final Widget Function(BuildContext, MapLibreMarker)? itemBuilder;

  /// Rendered when there is nothing to list — **including when the map failed
  /// to load**, which is the case an empty list would otherwise present as
  /// "there is nothing here".
  final WidgetBuilder? emptyBuilder;

  final ValueChanged<MapLibreMarker>? onSelected;

  /// Whether selecting a row moves the camera to it. Honours reduce motion,
  /// because it goes through the controller like every other camera move.
  final bool flyToOnSelect;

  String _label(MapLibreMarker marker) =>
      marker.semanticLabel ?? formatCoordinate(marker.point, locale: locale);

  void _select(MapLibreMarker marker) {
    onSelected?.call(marker);
    if (flyToOnSelect) {
      unawaited(controller.camera.flyTo(CameraOptions(center: marker.point)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (markers.isEmpty) {
      return emptyBuilder?.call(context) ?? const SizedBox.shrink();
    }
    return Semantics(
      container: true,
      explicitChildNodes: true,
      role: SemanticsRole.list,
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: markers.length,
        itemBuilder: (context, i) {
          final marker = markers[i];
          final custom = itemBuilder;
          if (custom != null) return custom(context, marker);
          return Semantics(
            container: true,
            button: true,
            label: _label(marker),
            value: marker.semanticValue,
            onTap: () => _select(marker),
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _select(marker),
              child: ConstrainedBox(
                // 48 logical pixels, so a row is a conformant target for a
                // motor-impaired user as well as a readable one for everybody.
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(_label(marker)),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
