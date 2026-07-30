// GENERATED CODE - DO NOT MODIFY BY HAND
//
// Generated from the MapLibre Style Spec (v8) vendored at
// ../maplibre_flutter_core/third_party/maplibre-native/scripts/style-spec-reference/v8.json
// by tool/generate_style_api.dart. Run that to regenerate.

import '../style_value.dart';

/// Builders for MapLibre Style Spec expressions, one per operator.
///
/// An [Expression] is assignable to every style property that accepts
/// one, so these compose directly:
///
/// ```dart
/// circleRadius: Expr.step(Expr.get('point_count'), 18, 100, 24),
/// ```
///
/// The spec carries no arity information for expressions, so every
/// builder takes up to 10 arguments and drops the ones you omit.
/// For a longer array — a `step` with many stops, say — use [Expr.raw],
/// which is also the escape hatch for anything here that is missing.
abstract final class Expr {
  /// A raw expression array: `Expr.raw(['get', 'name'])`.
  ///
  /// Nested expressions, colours and enums inside [parts] are encoded on
  /// the way out, so they can be mixed with plain literals.
  static Expression raw(List<Object?> parts) => Expression(parts);

  /// The `let` expression.
  ///
  /// Binds expressions to named variables, which can then be referenced in the
  /// result expression using `["var", "variable_name"]`.
  ///
  /// - [Visualize population
  /// density](https://maplibre.org/maplibre-gl-js/docs/examples/visualize-population-density/)
  static Expression let([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('let', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `var` expression.
  ///
  /// References variable bound using `let`.
  ///
  /// - [Visualize population
  /// density](https://maplibre.org/maplibre-gl-js/docs/examples/visualize-population-density/)
  static Expression variable([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('var', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `literal` expression.
  ///
  /// Provides a literal array or object value.
  ///
  /// - [Display and style rich text
  /// labels](https://maplibre.org/maplibre-gl-js/docs/examples/display-and-style-rich-text-labels/)
  static Expression literal([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('literal', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `array` expression.
  ///
  /// Asserts that the input is an array (optionally with a specific item type
  /// and length). If, when the input expression is evaluated, it is not of the
  /// asserted type or length, then this assertion will cause the whole
  /// expression to be aborted.
  static Expression array([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('array', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `at` expression.
  ///
  /// Retrieves an item from an array.
  static Expression at([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('at', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `in` expression.
  ///
  /// Determines whether an item exists in an array or a substring exists in a
  /// string.
  ///
  /// - [Measure
  /// distances](https://maplibre.org/maplibre-gl-js/docs/examples/measure-distances/)
  static Expression isIn([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('in', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `index-of` expression.
  ///
  /// Returns the first position at which an item can be found in an array or a
  /// substring can be found in a string, or `-1` if the input cannot be found.
  /// Accepts an optional index from where to begin the search. In a string, a
  /// UTF-16 surrogate pair counts as a single position.
  static Expression indexOf([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) =>
      Expression(_parts('index-of', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `slice` expression.
  ///
  /// Returns a subarray from an array or a substring from a string from a
  /// specified start index, or between a start index and an end index if set.
  /// The return value is inclusive of the start index but not of the end index.
  /// In a string, a UTF-16 surrogate pair counts as a single position.
  static Expression slice([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('slice', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `case` expression.
  ///
  /// Selects the first output whose corresponding test condition evaluates to
  /// true, or the fallback value otherwise.
  ///
  /// - [Create a hover
  /// effect](https://maplibre.org/maplibre-gl-js/docs/examples/create-a-hover-effect/)
  ///
  /// - [Display HTML clusters with custom
  /// properties](https://maplibre.org/maplibre-gl-js/docs/examples/display-html-clusters-with-custom-properties/)
  static Expression caseOf([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('case', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `match` expression.
  ///
  /// Selects the output whose label value matches the input value, or the
  /// fallback value if no match is found. The input can be any expression (e.g.
  /// `["get", "building_type"]`). Each label must be either:
  ///
  /// - a single literal value; or
  ///
  /// - an array of literal values, whose values must be all strings or all
  /// numbers (e.g. `[100, 101]` or `["c", "b"]`). The input matches if any of
  /// the values in the array matches, similar to the `"in"` operator.
  ///
  /// Each label must be unique. If the input type does not match the type of
  /// the labels, the result will be the fallback value.
  static Expression match([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('match', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `coalesce` expression.
  ///
  /// Evaluates each expression in turn until the first non-null value is
  /// obtained, and returns that value.
  ///
  /// - [Use a fallback
  /// image](https://maplibre.org/maplibre-gl-js/docs/examples/use-a-fallback-image/)
  static Expression coalesce([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) =>
      Expression(_parts('coalesce', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `step` expression.
  ///
  /// Produces discrete, stepped results by evaluating a piecewise-constant
  /// function defined by pairs of input and output values ("stops"). The
  /// `input` may be any numeric expression (e.g., `["get", "population"]`).
  /// Stop inputs must be numeric literals in strictly ascending order.
  ///
  /// Returns the output value of the stop just less than the input, or the
  /// first output if the input is less than the first stop.
  ///
  /// - [Create and style
  /// clusters](https://maplibre.org/maplibre-gl-js/docs/examples/create-and-style-clusters/)
  static Expression step([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('step', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `interpolate` expression.
  ///
  /// Produces continuous, smooth results by interpolating between pairs of
  /// input and output values ("stops"). The `input` may be any numeric
  /// expression (e.g., `["get", "population"]`). Stop inputs must be numeric
  /// literals in strictly ascending order. The output type must be `number`,
  /// `array<number>`, `color`, `array<color>`, or `projection`.
  ///
  /// Interpolation types:
  ///
  /// - `["linear"]`, or an expression returning one of those types:
  /// Interpolates linearly between the pair of stops just less than and just
  /// greater than the input.
  ///
  /// - `["exponential", base]`: Interpolates exponentially between the stops
  /// just less than and just greater than the input. `base` controls the rate
  /// at which the output increases: higher values make the output increase more
  /// towards the high end of the range. With values close to 1 the output
  /// increases linearly.
  ///
  /// - `["cubic-bezier", x1, y1, x2, y2]`: Interpolates using the cubic bezier
  /// curve defined by the given control points.
  ///
  /// - [Animate map camera around a
  /// point](https://maplibre.org/maplibre-gl-js/docs/examples/animate-camera-around-point/)
  ///
  /// - [Change building color based on zoom
  /// level](https://maplibre.org/maplibre-gl-js/docs/examples/change-building-color-based-on-zoom-level/)
  ///
  /// - [Create a heatmap
  /// layer](https://maplibre.org/maplibre-gl-js/docs/examples/heatmap-layer/)
  ///
  /// - [Visualize population
  /// density](https://maplibre.org/maplibre-gl-js/docs/examples/visualize-population-density/)
  static Expression interpolate([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(
    _parts('interpolate', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]),
  );

  /// The `interpolate-hcl` expression.
  ///
  /// Produces continuous, smooth results by interpolating between pairs of
  /// input and output values ("stops"). Works like `interpolate`, but the
  /// output type must be `color` or `array<color>`, and the interpolation is
  /// performed in the Hue-Chroma-Luminance color space.
  static Expression interpolateHcl([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(
    _parts('interpolate-hcl', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]),
  );

  /// The `interpolate-lab` expression.
  ///
  /// Produces continuous, smooth results by interpolating between pairs of
  /// input and output values ("stops"). Works like `interpolate`, but the
  /// output type must be `color` or `array<color>`, and the interpolation is
  /// performed in the CIELAB color space.
  static Expression interpolateLab([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(
    _parts('interpolate-lab', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]),
  );

  /// The `ln2` expression.
  ///
  /// Returns the mathematical constant ln(2).
  static Expression ln2([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('ln2', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `pi` expression.
  ///
  /// Returns the mathematical constant pi.
  static Expression pi([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('pi', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `e` expression.
  ///
  /// Returns the mathematical constant e.
  static Expression e([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('e', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `typeof` expression.
  ///
  /// Returns a string describing the type of the given value.
  static Expression typeof([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('typeof', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `string` expression.
  ///
  /// Asserts that the input value is a string. If multiple values are provided,
  /// each one is evaluated in order until a string is obtained. If none of the
  /// inputs are strings, the expression is an error.
  static Expression string([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('string', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `number` expression.
  ///
  /// Asserts that the input value is a number. If multiple values are provided,
  /// each one is evaluated in order until a number is obtained. If none of the
  /// inputs are numbers, the expression is an error.
  static Expression number([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('number', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `boolean` expression.
  ///
  /// Asserts that the input value is a boolean. If multiple values are
  /// provided, each one is evaluated in order until a boolean is obtained. If
  /// none of the inputs are booleans, the expression is an error.
  ///
  /// - [Create a hover
  /// effect](https://maplibre.org/maplibre-gl-js/docs/examples/create-a-hover-effect/)
  static Expression boolean([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('boolean', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `object` expression.
  ///
  /// Asserts that the input value is an object. If multiple values are
  /// provided, each one is evaluated in order until an object is obtained. If
  /// none of the inputs are objects, the expression is an error.
  static Expression object([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('object', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `collator` expression.
  ///
  /// Returns a `collator` for use in locale-dependent comparison operations.
  /// The `case-sensitive` and `diacritic-sensitive` options default to `false`.
  /// The `locale` argument specifies the IETF language tag of the locale to
  /// use. If none is provided, the default locale is used. If the requested
  /// locale is not available, the `collator` will use a system-defined fallback
  /// locale. Use `resolved-locale` to test the results of locale fallback
  /// behavior.
  static Expression collator([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) =>
      Expression(_parts('collator', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `format` expression.
  ///
  /// Returns a `formatted` string for displaying mixed-format text in the
  /// `text-field` property. The input may contain a string literal or
  /// expression, including an [`'image'`](#image) expression. Strings may be
  /// followed by a style override object that supports the following
  /// properties:
  ///
  /// - `"text-font"`: Overrides the font stack specified by the root layout
  /// property.
  ///
  /// - `"text-color"`: Overrides the color specified by the root paint
  /// property.
  ///
  /// - `"font-scale"`: Applies a scaling factor on `text-size` as specified by
  /// the root layout property.
  ///
  /// - `"vertical-align"`: Aligns vertically text section or image in relation
  /// to the row it belongs to. Possible values are:
  /// - `"bottom"` *default*: align the bottom of this section with the bottom
  /// of other sections.
  /// <img alt="Visual representation of bottom alignment"
  /// src="https://github.com/user-attachments/assets/0474a2fd-a4b2-417c-9187-7a13a28695bc"/>
  /// - `"center"`: align the center of this section with the center of other
  /// sections.
  /// <img alt="Visual representation of center alignment"
  /// src="https://github.com/user-attachments/assets/92237455-be6d-4c5d-b8f6-8127effc1950"/>
  /// - `"top"`: align the top of this section with the top of other sections.
  /// <img alt="Visual representation of top alignment"
  /// src="https://github.com/user-attachments/assets/45dccb28-d977-4abb-a006-4ea9792b7c53"/>
  /// - Refer to [the design
  /// proposal](https://github.com/maplibre/maplibre-style-spec/issues/832) for
  /// more details.
  ///
  /// - [Change the case of
  /// labels](https://maplibre.org/maplibre-gl-js/docs/examples/change-case-of-labels/)
  ///
  /// - [Display and style rich text
  /// labels](https://maplibre.org/maplibre-gl-js/docs/examples/display-and-style-rich-text-labels/)
  static Expression format([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('format', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `image` expression.
  ///
  /// Returns an `image` type for use in `icon-image`, `*-pattern` entries and
  /// as a section in the `format` expression. If set, the `image` argument will
  /// check that the requested image exists in the style and will return either
  /// the resolved image name or `null`, depending on whether or not the image
  /// is currently in the style. This validation process is synchronous and
  /// requires the image to have been added to the style before requesting it in
  /// the `image` argument.
  ///
  /// - [Use a fallback
  /// image](https://maplibre.org/maplibre-gl-js/docs/examples/use-a-fallback-image/)
  static Expression image([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('image', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `number-format` expression.
  ///
  /// Converts the input number into a string representation using the providing
  /// formatting rules. If set, the `locale` argument specifies the locale to
  /// use, as a BCP 47 language tag. If set, the `currency` argument specifies
  /// an ISO 4217 code to use for currency-style formatting. If set, the
  /// `min-fraction-digits` and `max-fraction-digits` arguments specify the
  /// minimum and maximum number of fractional digits to include.
  ///
  /// - [Display HTML clusters with custom
  /// properties](https://maplibre.org/maplibre-gl-js/docs/examples/display-html-clusters-with-custom-properties/)
  static Expression numberFormat([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(
    _parts('number-format', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]),
  );

  /// The `to-string` expression.
  ///
  /// Converts the input value to a string. If the input is `null`, the result
  /// is `""`. If the input is a boolean, the result is `"true"` or `"false"`.
  /// If the input is a number, it is converted to a string as specified by the
  /// ["NumberToString"
  /// algorithm](https://tc39.github.io/ecma262/#sec-tostring-applied-to-the-number-type)
  /// of the ECMAScript Language Specification. If the input is a color, it is
  /// converted to a string of the form `"rgba(r,g,b,a)"`, where `r`, `g`, and
  /// `b` are numerals ranging from 0 to 255, and `a` ranges from 0 to 1.
  /// Otherwise, the input is converted to a string in the format specified by
  /// the [`JSON.stringify`](https://tc39.github.io/ecma262/#sec-json.stringify)
  /// function of the ECMAScript Language Specification.
  ///
  /// - [Create a time
  /// slider](https://maplibre.org/maplibre-gl-js/docs/examples/create-a-time-slider/)
  static Expression toStringOp([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) =>
      Expression(_parts('to-string', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `to-number` expression.
  ///
  /// Converts the input value to a number, if possible. If the input is `null`
  /// or `false`, the result is 0. If the input is `true`, the result is 1. If
  /// the input is a string, it is converted to a number as specified by the
  /// ["ToNumber Applied to the String Type"
  /// algorithm](https://tc39.github.io/ecma262/#sec-tonumber-applied-to-the-string-type)
  /// of the ECMAScript Language Specification. If multiple values are provided,
  /// each one is evaluated in order until the first successful conversion is
  /// obtained. If none of the inputs can be converted, the expression is an
  /// error.
  static Expression toNumber([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) =>
      Expression(_parts('to-number', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `to-boolean` expression.
  ///
  /// Converts the input value to a boolean. The result is `false` when the
  /// input is an empty string, 0, `false`, `null`, or `NaN`; otherwise it is
  /// `true`.
  static Expression toBoolean([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(
    _parts('to-boolean', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]),
  );

  /// The `to-rgba` expression.
  ///
  /// Returns a four-element array containing the input color's red, green,
  /// blue, and alpha components, in that order.
  static Expression toRgba([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('to-rgba', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `to-color` expression.
  ///
  /// Converts the input value to a color. If multiple values are provided, each
  /// one is evaluated in order until the first successful conversion is
  /// obtained. If none of the inputs can be converted, the expression is an
  /// error.
  ///
  /// - [Visualize population
  /// density](https://maplibre.org/maplibre-gl-js/docs/examples/visualize-population-density/)
  static Expression toColor([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) =>
      Expression(_parts('to-color', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `rgb` expression.
  ///
  /// Creates a color value from red, green, and blue components, which must
  /// range between 0 and 255, and an alpha component of 1. If any component is
  /// out of range, the expression is an error.
  static Expression rgb([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('rgb', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `rgba` expression.
  ///
  /// Creates a color value from red, green, blue components, which must range
  /// between 0 and 255, and an alpha component which must range between 0 and
  /// 1. If any component is out of range, the expression is an error.
  static Expression rgba([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('rgba', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `get` expression.
  ///
  /// Retrieves a property value from the current feature's properties, or from
  /// another object if a second argument is provided. Returns null if the
  /// requested property is missing.
  ///
  /// - [Change the case of
  /// labels](https://maplibre.org/maplibre-gl-js/docs/examples/change-case-of-labels/)
  ///
  /// - [Display HTML clusters with custom
  /// properties](https://maplibre.org/maplibre-gl-js/docs/examples/display-html-clusters-with-custom-properties/)
  ///
  /// - [Extrude polygons for 3D indoor
  /// mapping](https://maplibre.org/maplibre-gl-js/docs/examples/extrude-polygons-for-3d-indoor-mapping/)
  static Expression get([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('get', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `has` expression.
  ///
  /// Tests for the presence of a property value in the current feature's
  /// properties, or from another object if a second argument is provided.
  ///
  /// - [Create and style
  /// clusters](https://maplibre.org/maplibre-gl-js/docs/examples/create-and-style-clusters/)
  static Expression has([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('has', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `length` expression.
  ///
  /// Gets the length of an array or string. In a string, a UTF-16 surrogate
  /// pair counts as a single position.
  static Expression length([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('length', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `properties` expression.
  ///
  /// Gets the feature properties object. Note that in some cases, it may be
  /// more efficient to use ["get", "property_name"] directly.
  static Expression properties([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(
    _parts('properties', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]),
  );

  /// The `feature-state` expression.
  ///
  /// Retrieves a property value from the current feature's state. Returns null
  /// if the requested property is not present on the feature's state. A
  /// feature's state is not part of the GeoJSON or vector tile data, and must
  /// be set programmatically on each feature. When `source.promoteId` is not
  /// provided, features are identified by their `id` attribute, which must be
  /// an integer or a string that can be cast to an integer. When
  /// `source.promoteId` is provided, features are identified by their
  /// `promoteId` property, which may be a number, string, or any primitive data
  /// type. Note that ["feature-state"] can only be used with paint properties
  /// that support data-driven styling.
  ///
  /// - [Create a hover
  /// effect](https://maplibre.org/maplibre-gl-js/docs/examples/create-a-hover-effect/)
  static Expression featureState([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(
    _parts('feature-state', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]),
  );

  /// The `geometry-type` expression.
  ///
  /// Returns the feature's simple geometry type: `Point`, `LineString`, or
  /// `Polygon`. `MultiPoint`, `MultiLineString`, and `MultiPolygon` are
  /// returned as `Point`, `LineString`, and `Polygon`, respectively.
  static Expression geometryType([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(
    _parts('geometry-type', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]),
  );

  /// The `id` expression.
  ///
  /// Gets the feature's id, if it has one.
  static Expression id([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('id', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `zoom` expression.
  ///
  /// Gets the current zoom level. Note that in style layout and paint
  /// properties, ["zoom"] may only appear as the input to a top-level "step" or
  /// "interpolate" expression.
  static Expression zoom([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('zoom', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `heatmap-density` expression.
  ///
  /// Gets the kernel density estimation of a pixel in a heatmap layer, which is
  /// a relative measure of how many data points are crowded around a particular
  /// pixel. Can only be used in the `heatmap-color` property.
  static Expression heatmapDensity([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(
    _parts('heatmap-density', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]),
  );

  /// The `elevation` expression.
  ///
  /// Gets the elevation of a pixel (in meters above the vertical datum
  /// reference of the `raster-dem` tiles) from a `raster-dem` source. Can only
  /// be used in the `color-relief-color` property of a `color-relief` layer.
  static Expression elevation([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) =>
      Expression(_parts('elevation', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `line-progress` expression.
  ///
  /// Gets the progress along a gradient line. Can only be used in the
  /// `line-gradient` property.
  static Expression lineProgress([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(
    _parts('line-progress', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]),
  );

  /// The `accumulated` expression.
  ///
  /// Gets the value of a cluster property accumulated so far. Can only be used
  /// in the `clusterProperties` option of a clustered GeoJSON source.
  static Expression accumulated([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(
    _parts('accumulated', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]),
  );

  /// The `+` expression.
  ///
  /// Returns the sum of the inputs.
  static Expression sum([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('+', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `*` expression.
  ///
  /// Returns the product of the inputs.
  static Expression product([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('*', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `-` expression.
  ///
  /// For two inputs, returns the result of subtracting the second input from
  /// the first. For a single input, returns the result of subtracting it from
  /// 0.
  static Expression subtract([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('-', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `/` expression.
  ///
  /// Returns the result of floating point division of the first input by the
  /// second.
  ///
  /// - [Visualize population
  /// density](https://maplibre.org/maplibre-gl-js/docs/examples/visualize-population-density/)
  static Expression divide([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('/', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `%` expression.
  ///
  /// Returns the remainder after integer division of the first input by the
  /// second.
  static Expression modulo([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('%', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `^` expression.
  ///
  /// Returns the result of raising the first input to the power specified by
  /// the second.
  static Expression power([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('^', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `sqrt` expression.
  ///
  /// Returns the square root of the input.
  static Expression sqrt([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('sqrt', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `log10` expression.
  ///
  /// Returns the base-ten logarithm of the input.
  static Expression log10([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('log10', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `ln` expression.
  ///
  /// Returns the natural logarithm of the input.
  static Expression ln([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('ln', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `log2` expression.
  ///
  /// Returns the base-two logarithm of the input.
  static Expression log2([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('log2', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `sin` expression.
  ///
  /// Returns the sine of the input.
  static Expression sin([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('sin', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `cos` expression.
  ///
  /// Returns the cosine of the input.
  static Expression cos([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('cos', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `tan` expression.
  ///
  /// Returns the tangent of the input.
  static Expression tan([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('tan', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `asin` expression.
  ///
  /// Returns the arcsine of the input.
  static Expression asin([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('asin', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `acos` expression.
  ///
  /// Returns the arccosine of the input.
  static Expression acos([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('acos', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `atan` expression.
  ///
  /// Returns the arctangent of the input.
  static Expression atan([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('atan', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `min` expression.
  ///
  /// Returns the minimum value of the inputs.
  static Expression min([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('min', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `max` expression.
  ///
  /// Returns the maximum value of the inputs.
  static Expression max([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('max', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `round` expression.
  ///
  /// Rounds the input to the nearest integer. Halfway values are rounded away
  /// from zero. For example, `["round", -1.5]` evaluates to -2.
  static Expression round([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('round', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `abs` expression.
  ///
  /// Returns the absolute value of the input.
  static Expression abs([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('abs', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `ceil` expression.
  ///
  /// Returns the smallest integer that is greater than or equal to the input.
  static Expression ceil([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('ceil', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `floor` expression.
  ///
  /// Returns the largest integer that is less than or equal to the input.
  static Expression floor([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('floor', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `distance` expression.
  ///
  /// Returns the shortest distance in meters between the evaluated feature and
  /// the input geometry. The input value can be a valid GeoJSON of type
  /// `Point`, `MultiPoint`, `LineString`, `MultiLineString`, `Polygon`,
  /// `MultiPolygon`, `Feature`, or `FeatureCollection`. Distance values
  /// returned may vary in precision due to loss in precision from encoding
  /// geometries, particularly below zoom level 13.
  static Expression distance([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) =>
      Expression(_parts('distance', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `==` expression.
  ///
  /// Returns `true` if the input values are equal, `false` otherwise. The
  /// comparison is strictly typed: values of different runtime types are always
  /// considered unequal. Cases where the types are known to be different at
  /// parse time are considered invalid and will produce a parse error. Accepts
  /// an optional `collator` argument to control locale-dependent string
  /// comparisons.
  ///
  /// - [Add multiple geometries from one GeoJSON
  /// source](https://maplibre.org/maplibre-gl-js/docs/examples/multiple-geometries/)
  ///
  /// - [Create a time
  /// slider](https://maplibre.org/maplibre-gl-js/docs/examples/timeline-animation/)
  ///
  /// - [Display buildings in
  /// 3D](https://maplibre.org/maplibre-gl-js/docs/examples/display-buildings-in-3d/)
  ///
  /// - [Filter symbols by toggling a
  /// list](https://maplibre.org/maplibre-gl-js/docs/examples/filter-symbols-by-toggling-a-list/)
  static Expression equals([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('==', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `!=` expression.
  ///
  /// Returns `true` if the input values are not equal, `false` otherwise. The
  /// comparison is strictly typed: values of different runtime types are always
  /// considered unequal. Cases where the types are known to be different at
  /// parse time are considered invalid and will produce a parse error. Accepts
  /// an optional `collator` argument to control locale-dependent string
  /// comparisons.
  ///
  /// - [Display HTML clusters with custom
  /// properties](https://maplibre.org/maplibre-gl-js/docs/examples/display-html-clusters-with-custom-properties/)
  static Expression notEquals([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('!=', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `>` expression.
  ///
  /// Returns `true` if the first input is strictly greater than the second,
  /// `false` otherwise. The arguments are required to be either both strings or
  /// both numbers; if during evaluation they are not, expression evaluation
  /// produces an error. Cases where this constraint is known not to hold at
  /// parse time are considered in valid and will produce a parse error. Accepts
  /// an optional `collator` argument to control locale-dependent string
  /// comparisons.
  static Expression greaterThan([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('>', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `<` expression.
  ///
  /// Returns `true` if the first input is strictly less than the second,
  /// `false` otherwise. The arguments are required to be either both strings or
  /// both numbers; if during evaluation they are not, expression evaluation
  /// produces an error. Cases where this constraint is known not to hold at
  /// parse time are considered in valid and will produce a parse error. Accepts
  /// an optional `collator` argument to control locale-dependent string
  /// comparisons.
  ///
  /// - [Display HTML clusters with custom
  /// properties](https://maplibre.org/maplibre-gl-js/docs/examples/display-html-clusters-with-custom-properties/)
  static Expression lessThan([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('<', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `>=` expression.
  ///
  /// Returns `true` if the first input is greater than or equal to the second,
  /// `false` otherwise. The arguments are required to be either both strings or
  /// both numbers; if during evaluation they are not, expression evaluation
  /// produces an error. Cases where this constraint is known not to hold at
  /// parse time are considered in valid and will produce a parse error. Accepts
  /// an optional `collator` argument to control locale-dependent string
  /// comparisons.
  ///
  /// - [Display HTML clusters with custom
  /// properties](https://maplibre.org/maplibre-gl-js/docs/examples/display-html-clusters-with-custom-properties/)
  static Expression greaterThanOrEqual([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('>=', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `<=` expression.
  ///
  /// Returns `true` if the first input is less than or equal to the second,
  /// `false` otherwise. The arguments are required to be either both strings or
  /// both numbers; if during evaluation they are not, expression evaluation
  /// produces an error. Cases where this constraint is known not to hold at
  /// parse time are considered in valid and will produce a parse error. Accepts
  /// an optional `collator` argument to control locale-dependent string
  /// comparisons.
  static Expression lessThanOrEqual([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('<=', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `all` expression.
  ///
  /// Returns `true` if all the inputs are `true`, `false` otherwise. The inputs
  /// are evaluated in order, and evaluation is short-circuiting: once an input
  /// expression evaluates to `false`, the result is `false` and no further
  /// input expressions are evaluated.
  ///
  /// - [Display HTML clusters with custom
  /// properties](https://maplibre.org/maplibre-gl-js/docs/examples/display-html-clusters-with-custom-properties/)
  static Expression all([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('all', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `any` expression.
  ///
  /// Returns `true` if any of the inputs are `true`, `false` otherwise. The
  /// inputs are evaluated in order, and evaluation is short-circuiting: once an
  /// input expression evaluates to `true`, the result is `true` and no further
  /// input expressions are evaluated.
  static Expression any([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('any', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `!` expression.
  ///
  /// Logical negation. Returns `true` if the input is `false`, and `false` if
  /// the input is `true`.
  ///
  /// - [Create and style
  /// clusters](https://maplibre.org/maplibre-gl-js/docs/examples/create-and-style-clusters/)
  static Expression not([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('!', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `within` expression.
  ///
  /// Returns `true` if the evaluated feature is fully contained inside a
  /// boundary of the input geometry, `false` otherwise. The input value can be
  /// a valid GeoJSON of type `Polygon`, `MultiPolygon`, `Feature`, or
  /// `FeatureCollection`. Supported features for evaluation:
  ///
  /// - `Point`: Returns `false` if a point is on the boundary or falls outside
  /// the boundary.
  ///
  /// - `LineString`: Returns `false` if any part of a line falls outside the
  /// boundary, the line intersects the boundary, or a line's endpoint is on the
  /// boundary.
  static Expression within([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('within', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `is-supported-script` expression.
  ///
  /// Returns `true` if the input string is expected to render legibly. Returns
  /// `false` if the input string contains sections that cannot be rendered
  /// without potential loss of meaning (e.g. Indic scripts that require complex
  /// text shaping, or right-to-left scripts if the `mapbox-gl-rtl-text` plugin
  /// is not in use in MapLibre GL JS).
  static Expression isSupportedScript([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(
    _parts('is-supported-script', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]),
  );

  /// The `upcase` expression.
  ///
  /// Returns the input string converted to uppercase. Follows the Unicode
  /// Default Case Conversion algorithm and the locale-insensitive case mappings
  /// in the Unicode Character Database.
  ///
  /// - [Change the case of
  /// labels](https://maplibre.org/maplibre-gl-js/docs/examples/change-case-of-labels/)
  static Expression upcase([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('upcase', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `downcase` expression.
  ///
  /// Returns the input string converted to lowercase. Follows the Unicode
  /// Default Case Conversion algorithm and the locale-insensitive case mappings
  /// in the Unicode Character Database.
  ///
  /// - [Change the case of
  /// labels](https://maplibre.org/maplibre-gl-js/docs/examples/change-case-of-labels/)
  static Expression downcase([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) =>
      Expression(_parts('downcase', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `concat` expression.
  ///
  /// Returns a `string` consisting of the concatenation of the inputs. Each
  /// input is converted to a string as if by `to-string`.
  ///
  /// - [Add a generated icon to the
  /// map](https://maplibre.org/maplibre-gl-js/docs/examples/add-a-generated-icon-to-the-map/)
  ///
  /// - [Create a time
  /// slider](https://maplibre.org/maplibre-gl-js/docs/examples/create-a-time-slider/)
  ///
  /// - [Use a fallback
  /// image](https://maplibre.org/maplibre-gl-js/docs/examples/fallback-image/)
  ///
  /// - [Variable label
  /// placement](https://maplibre.org/maplibre-gl-js/docs/examples/variable-label-placement/)
  static Expression concat([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(_parts('concat', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]));

  /// The `resolved-locale` expression.
  ///
  /// Returns the IETF language tag of the locale being used by the provided
  /// `collator`. This can be used to determine the default system locale, or to
  /// determine if a requested locale was successfully loaded.
  static Expression resolvedLocale([
    Object? a0 = _unset,
    Object? a1 = _unset,
    Object? a2 = _unset,
    Object? a3 = _unset,
    Object? a4 = _unset,
    Object? a5 = _unset,
    Object? a6 = _unset,
    Object? a7 = _unset,
    Object? a8 = _unset,
    Object? a9 = _unset,
  ]) => Expression(
    _parts('resolved-locale', [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]),
  );
}

/// Sentinel for an argument the caller did not pass —
/// distinct from an explicit `null`, which is meaningful in
/// expressions such as `["literal", null]`.
class _Unset {
  const _Unset();
}

const _unset = _Unset();

/// The operator followed by the arguments actually passed.
List<Object?> _parts(String op, List<Object?> args) {
  final parts = <Object?>[op];
  for (final arg in args) {
    if (identical(arg, _unset)) break;
    parts.add(arg);
  }
  return parts;
}
