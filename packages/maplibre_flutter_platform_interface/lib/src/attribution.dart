import 'package:flutter/foundation.dart';

/// One attribution a tile provider requires be shown.
///
/// **This is usually a legal obligation, not a courtesy.** OpenStreetMap-derived
/// tiles are ODbL, which requires visible credit; most commercial providers say
/// the same in their terms. Reading the string is not displaying it — see
/// `MapLibreMap.showAttribution`, which is on by default for exactly this
/// reason.
///
/// Sources declare it as a fragment of HTML (`<a href="...">OpenStreetMap</a>
/// contributors`), so this carries all three forms: the [html] as given, the
/// [text] with tags stripped for a plain label, and the [links] pulled out so
/// an app can make them tappable.
@immutable
class MapAttribution {
  const MapAttribution({
    required this.html,
    required this.text,
    required this.links,
  });

  /// Parses a source's `attribution` fragment.
  ///
  /// Deliberately a small hand-rolled scan rather than an HTML parser: the
  /// fragments in practice are anchors and plain text, and taking on an HTML
  /// dependency to render a credit line would be a poor trade. Anything it
  /// does not recognise survives in [html] and, tag-stripped, in [text].
  factory MapAttribution.parse(String html) {
    final links = <AttributionLink>[];
    final text = StringBuffer();
    var i = 0;
    while (i < html.length) {
      final open = html.indexOf('<', i);
      if (open < 0) {
        text.write(html.substring(i));
        break;
      }
      text.write(html.substring(i, open));
      final close = html.indexOf('>', open);
      if (close < 0) {
        // An unterminated tag: keep the rest as text rather than dropping it.
        text.write(html.substring(open));
        break;
      }
      final tag = html.substring(open + 1, close);
      if (tag.toLowerCase().startsWith('a ')) {
        final href = _href(tag);
        final end = html.indexOf('</a>', close);
        final label = end < 0
            ? html.substring(close + 1)
            : html.substring(close + 1, end);
        text.write(label);
        if (href != null) links.add(AttributionLink(text: label, url: href));
        i = end < 0 ? html.length : end + 4;
        continue;
      }
      i = close + 1;
    }
    return MapAttribution(
      html: html,
      text: text.toString().replaceAll(RegExp(r'\s+'), ' ').trim(),
      links: List.unmodifiable(links),
    );
  }

  static String? _href(String tag) {
    final match = RegExp(
      '''href\\s*=\\s*(?:"([^"]*)"|'([^']*)')''',
    ).firstMatch(tag);
    return match?.group(1) ?? match?.group(2);
  }

  /// The fragment exactly as the source declared it.
  final String html;

  /// The same credit with markup removed — what you show when you are not
  /// rendering links.
  final String text;

  /// The links the fragment contained, in order.
  final List<AttributionLink> links;

  @override
  bool operator ==(Object other) =>
      other is MapAttribution && other.html == html;

  @override
  int get hashCode => html.hashCode;

  @override
  String toString() => 'MapAttribution($text)';
}

/// A link inside an attribution.
@immutable
class AttributionLink {
  const AttributionLink({required this.text, required this.url});

  /// The visible label.
  final String text;

  /// Where it points.
  final String url;

  @override
  bool operator ==(Object other) =>
      other is AttributionLink && other.text == text && other.url == url;

  @override
  int get hashCode => Object.hash(text, url);
}
