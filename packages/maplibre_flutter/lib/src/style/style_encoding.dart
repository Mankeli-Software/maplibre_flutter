import 'dart:ui' show Color;

import 'style_value.dart';

/// Encodes [value] as MapLibre Style Spec JSON.
///
/// Deliberately not exported: it is the shared serialisation used by the
/// hand-written base types and by everything under `generated/`.
Object? encodeStyleJson(Object? value) {
  if (value == null) return null;
  if (value is StyleJson) return value.toJson();
  if (value is StyleEnum) return value.jsonValue;
  if (value is Color) return encodeStyleColor(value);
  if (value is num) return encodeStyleNumber(value);
  if (value is Iterable) return [for (final v in value) encodeStyleJson(v)];
  if (value is Map) {
    return {
      for (final entry in value.entries)
        '${entry.key}': encodeStyleJson(entry.value),
    };
  }
  // bool, String, and anything a caller passed through a `*`-typed property.
  return value;
}

/// The spec types every numeric property as `number`, so the Dart side is
/// uniformly `double`. Emitting `1` rather than `1.0` for whole numbers keeps
/// the generated documents identical to hand-written style JSON.
Object encodeStyleNumber(num value) {
  if (value is int) return value;
  if (value.isFinite && value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toInt();
  }
  return value;
}

/// The spec wants CSS colours, not ARGB ints.
///
/// Opaque colours become `#rrggbb` (what hand-written style JSON looks like);
/// anything translucent becomes `rgba(...)`, since hex-with-alpha is not
/// universally accepted by the spec's colour parser.
String encodeStyleColor(Color color) {
  final r = (color.r * 255).round();
  final g = (color.g * 255).round();
  final b = (color.b * 255).round();
  if (color.a >= 1.0) {
    final hex = ((r << 16) | (g << 8) | b).toRadixString(16).padLeft(6, '0');
    return '#$hex';
  }
  return 'rgba($r,$g,$b,${color.a})';
}
