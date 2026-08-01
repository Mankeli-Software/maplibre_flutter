import 'package:flutter/material.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// The credit line drawn over the bottom of the map.
///
/// **On by default, because for most tile providers this is a licence
/// condition rather than a nicety** — OpenStreetMap-derived tiles are ODbL and
/// require visible credit. `MapLibreMap.showAttribution: false` exists for the
/// cases where you are genuinely rendering it yourself, not as a convenience
/// for tidying the screen.
///
/// Links are NOT opened for you: doing so needs `url_launcher`, and a map
/// package should not force a dependency on every app to render a credit. Pass
/// [onLinkTap] and the labels become tappable; leave it null and they render as
/// plain text.
class MapLibreAttributionBar extends StatelessWidget {
  const MapLibreAttributionBar({
    required this.attributions,
    super.key,
    this.onLinkTap,
    this.alignment = Alignment.bottomRight,
  });

  /// What to credit — from `controller.style.getAttributions()`.
  final List<MapAttribution> attributions;

  /// Called with a link's URL when its label is tapped. Null renders the labels
  /// as plain text.
  final ValueChanged<String>? onLinkTap;

  /// Where the bar sits over the map.
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (attributions.isEmpty) return const SizedBox.shrink();
    final style = DefaultTextStyle.of(
      context,
    ).style.copyWith(fontSize: 10, color: const Color(0xDD000000));
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.all(4),
        // Opaque, so the credit behaves like the solid thing it looks like:
        // gestures over it do not reach the map. A DecoratedBox alone would not
        // do it — decoration is paint, and paint has no bearing on hit testing,
        // so without this the bar is a coloured hole the map sees straight
        // through.
        child: Listener(
          behavior: HitTestBehavior.opaque,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xCCFFFFFF),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              child: Text.rich(
                TextSpan(children: _spans(style)),
                style: style,
                // A long credit line must not push the map's layout around or
                // run off the edge; wrapping is the only sane failure here.
                softWrap: true,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<InlineSpan> _spans(TextStyle base) {
    final spans = <InlineSpan>[];
    for (var i = 0; i < attributions.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: ' · '));
      spans.addAll(_spansFor(attributions[i], base));
    }
    return spans;
  }

  /// Splits one attribution into plain runs and tappable link runs.
  ///
  /// Matches on the link LABEL inside the plain text rather than re-parsing the
  /// HTML: the parse already happened, and the label is what the reader sees.
  List<InlineSpan> _spansFor(MapAttribution attribution, TextStyle base) {
    final tap = onLinkTap;
    if (tap == null || attribution.links.isEmpty) {
      return [TextSpan(text: attribution.text)];
    }
    final spans = <InlineSpan>[];
    var rest = attribution.text;
    for (final link in attribution.links) {
      final at = rest.indexOf(link.text);
      if (at < 0) continue;
      if (at > 0) spans.add(TextSpan(text: rest.substring(0, at)));
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            onTap: () => tap(link.url),
            child: Text(
              link.text,
              style: base.copyWith(
                color: const Color(0xFF1565C0),
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      );
      rest = rest.substring(at + link.text.length);
    }
    if (rest.isNotEmpty) spans.add(TextSpan(text: rest));
    return spans;
  }
}
