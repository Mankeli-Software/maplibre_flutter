import 'package:flutter/foundation.dart' show immutable, listEquals;

import 'style_encoding.dart';

/// An object that knows how to become MapLibre Style Spec JSON.
///
/// Implemented by everything in the typed style API — layers, sources,
/// property values, expressions — so nesting one inside another Just Works.
abstract interface class StyleJson {
  /// This object as JSON-encodable data (maps, lists, numbers, strings, bools).
  Object? toJson();
}

/// A style-spec string enum, such as `circle-pitch-alignment`.
///
/// The generated enums implement this so the encoder can serialise them
/// wherever they appear, including nested inside an expression.
abstract interface class StyleEnum {
  /// The spec string this value serialises to (e.g. `viewport`).
  String get jsonValue;
}

/// The value of a style property: either a constant or an [Expression].
///
/// ```dart
/// CircleLayer(
///   id: 'pts',
///   source: 'pts',
///   circleRadius: const StyleValue(6),                 // constant
///   circleColor: Expr.get('color'),                    // expression
/// );
/// ```
///
/// Properties the spec marks as constant-only (`property-type: constant`, e.g.
/// `visibility`) are generated as their plain Dart type instead, so it is not
/// possible to hand them an expression the engine would reject.
sealed class StyleValue<T extends Object> implements StyleJson {
  const StyleValue._();

  /// A constant value — `const StyleValue(6)`, `StyleValue(Colors.red)`.
  const factory StyleValue(T value) = StyleConstant<T>;

  @override
  Object? toJson();
}

/// A constant [StyleValue]. Written as `StyleValue(x)` at call sites.
@immutable
final class StyleConstant<T extends Object> extends StyleValue<T> {
  /// Wraps [value] as a constant property value.
  const StyleConstant(this.value) : super._();

  /// The constant itself.
  final T value;

  @override
  Object? toJson() => encodeStyleJson(value);

  @override
  bool operator ==(Object other) =>
      other is StyleConstant<T> && other.value == value;

  @override
  int get hashCode => Object.hash(T, value);

  @override
  String toString() => 'StyleValue($value)';
}

/// A style-spec expression — the JSON array form, e.g. `["get", "point_count"]`.
///
/// Build one with the generated [Expr] builders (`Expr.get('point_count')`) or
/// with [Expression.new] directly for anything they do not cover.
///
/// It extends `StyleValue<Never>`, which by covariance makes it assignable to
/// *every* `StyleValue<T>` property — so an expression can be passed straight
/// to any property that accepts one, with no wrapping:
///
/// ```dart
/// circleRadius: Expr.step(Expr.get('point_count'), 18, 100, 24),
/// ```
@immutable
final class Expression extends StyleValue<Never> {
  /// Wraps a raw expression array, e.g. `Expression(['get', 'name'])`.
  ///
  /// Nested [Expression]s, [StyleValue]s, `Color`s and style enums inside
  /// [parts] are encoded on the way out, so they can be mixed with plain
  /// literals.
  const Expression(this.parts) : super._();

  /// The expression array: the operator followed by its arguments.
  final List<Object?> parts;

  @override
  List<Object?> toJson() => [for (final part in parts) encodeStyleJson(part)];

  @override
  bool operator ==(Object other) =>
      other is Expression && listEquals(other.parts, parts);

  @override
  int get hashCode => Object.hashAll(parts);

  @override
  String toString() => 'Expression($parts)';
}
