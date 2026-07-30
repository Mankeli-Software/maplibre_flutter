// GENERATED CODE - DO NOT MODIFY BY HAND
//
// Generated from the MapLibre Style Spec (v8) vendored at
// ../maplibre_flutter_core/third_party/maplibre-native/scripts/style-spec-reference/v8.json
// by tool/generate_style_api.dart. Run that to regenerate.

import 'package:flutter/foundation.dart' show immutable;

import '../style_encoding.dart';
import '../style_value.dart';

/// How a paint property animates when it changes (`*-transition`).
///
/// Generated from the spec schema `transition`.
@immutable
final class StyleTransition implements StyleJson {
  /// Creates a transition; omitted fields keep the
  /// engine default.
  const StyleTransition({this.duration, this.delay});

  /// Time allotted for transitions to complete.
  ///
  /// Spec: `duration`, in milliseconds. Defaults to `300`.
  final double? duration;

  /// Length of time before a transition begins.
  ///
  /// Spec: `delay`, in milliseconds. Defaults to `0`.
  final double? delay;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    if (duration != null) 'duration': encodeStyleNumber(duration!),
    if (delay != null) 'delay': encodeStyleNumber(delay!),
  };
}
