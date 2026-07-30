// GENERATED CODE - DO NOT MODIFY BY HAND
//
// Generated from the MapLibre Style Spec (v8) vendored at
// ../maplibre_flutter_core/third_party/maplibre-native/scripts/style-spec-reference/v8.json
// by tool/generate_style_api.dart. Run that to regenerate.

import '../style_value.dart';

/// The values of `circle-pitch-alignment`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum CirclePitchAlignment implements StyleEnum {
  /// The circle is aligned to the plane of the map.
  map('map'),

  /// The circle is aligned to the plane of the viewport.
  viewport('viewport');

  const CirclePitchAlignment(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `circle-pitch-scale`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum CirclePitchScale implements StyleEnum {
  /// Circles are scaled according to their apparent distance to the camera.
  map('map'),

  /// Circles are not scaled.
  viewport('viewport');

  const CirclePitchScale(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `circle-translate-anchor`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum CircleTranslateAnchor implements StyleEnum {
  /// The circle is translated relative to the map.
  map('map'),

  /// The circle is translated relative to the viewport.
  viewport('viewport');

  const CircleTranslateAnchor(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `fill-extrusion-translate-anchor`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum FillExtrusionTranslateAnchor implements StyleEnum {
  /// The fill extrusion is translated relative to the map.
  map('map'),

  /// The fill extrusion is translated relative to the viewport.
  viewport('viewport');

  const FillExtrusionTranslateAnchor(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `fill-translate-anchor`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum FillTranslateAnchor implements StyleEnum {
  /// The fill is translated relative to the map.
  map('map'),

  /// The fill is translated relative to the viewport.
  viewport('viewport');

  const FillTranslateAnchor(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `hillshade-illumination-anchor`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum HillshadeIlluminationAnchor implements StyleEnum {
  /// The hillshade illumination is relative to the north direction.
  map('map'),

  /// The hillshade illumination is relative to the top of the viewport.
  viewport('viewport');

  const HillshadeIlluminationAnchor(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `hillshade-method`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum HillshadeMethod implements StyleEnum {
  /// The legacy hillshade method.
  standard('standard'),

  /// Basic hillshade. Uses a simple physics model where the reflected light
  /// intensity is proportional to the cosine of the angle between the incident
  /// light and the surface normal. Similar to GDAL's `gdaldem` default
  /// algorithm.
  basic('basic'),

  /// Hillshade algorithm whose intensity scales with slope. Similar to GDAL's
  /// `gdaldem` with `-combined` option.
  combined('combined'),

  /// Hillshade algorithm which tries to minimize effects on other map features
  /// beneath. Similar to GDAL's `gdaldem` with `-igor` option.
  igor('igor'),

  /// Hillshade with multiple illumination directions. Uses the basic hillshade
  /// model with multiple independent light sources.
  multidirectional('multidirectional');

  const HillshadeMethod(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `icon-anchor`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum IconAnchor implements StyleEnum {
  /// The center of the icon is placed closest to the anchor.
  center('center'),

  /// The left side of the icon is placed closest to the anchor.
  left('left'),

  /// The right side of the icon is placed closest to the anchor.
  right('right'),

  /// The top of the icon is placed closest to the anchor.
  top('top'),

  /// The bottom of the icon is placed closest to the anchor.
  bottom('bottom'),

  /// The top left corner of the icon is placed closest to the anchor.
  topLeft('top-left'),

  /// The top right corner of the icon is placed closest to the anchor.
  topRight('top-right'),

  /// The bottom left corner of the icon is placed closest to the anchor.
  bottomLeft('bottom-left'),

  /// The bottom right corner of the icon is placed closest to the anchor.
  bottomRight('bottom-right');

  const IconAnchor(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `icon-overlap`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum IconOverlap implements StyleEnum {
  /// The icon will be hidden if it collides with any other previously drawn
  /// symbol.
  never('never'),

  /// The icon will be visible even if it collides with any other previously
  /// drawn symbol.
  always('always'),

  /// If the icon collides with another previously drawn symbol, the overlap
  /// mode for that symbol is checked. If the previous symbol was placed using
  /// `never` overlap mode, the new icon is hidden. If the previous symbol was
  /// placed using `always` or `cooperative` overlap mode, the new icon is
  /// visible.
  cooperative('cooperative');

  const IconOverlap(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `icon-pitch-alignment`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum IconPitchAlignment implements StyleEnum {
  /// The icon is aligned to the plane of the map.
  map('map'),

  /// The icon is aligned to the plane of the viewport.
  viewport('viewport'),

  /// Automatically matches the value of `icon-rotation-alignment`.
  auto('auto');

  const IconPitchAlignment(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `icon-rotation-alignment`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum IconRotationAlignment implements StyleEnum {
  /// When `symbol-placement` is set to `point`, aligns icons east-west. When
  /// `symbol-placement` is set to `line` or `line-center`, aligns icon x-axes
  /// with the line.
  map('map'),

  /// Produces icons whose x-axes are aligned with the x-axis of the viewport,
  /// regardless of the value of `symbol-placement`.
  viewport('viewport'),

  /// When `symbol-placement` is set to `point`, this is equivalent to
  /// `viewport`. When `symbol-placement` is set to `line` or `line-center`,
  /// this is equivalent to `map`.
  auto('auto');

  const IconRotationAlignment(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `icon-text-fit`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum IconTextFit implements StyleEnum {
  /// The icon is displayed at its intrinsic aspect ratio.
  none('none'),

  /// The icon is scaled in the x-dimension to fit the width of the text.
  width('width'),

  /// The icon is scaled in the y-dimension to fit the height of the text.
  height('height'),

  /// The icon is scaled in both x- and y-dimensions.
  both('both');

  const IconTextFit(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `icon-translate-anchor`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum IconTranslateAnchor implements StyleEnum {
  /// Icons are translated relative to the map.
  map('map'),

  /// Icons are translated relative to the viewport.
  viewport('viewport');

  const IconTranslateAnchor(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `line-cap`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum LineCap implements StyleEnum {
  /// A cap with a squared-off end which is drawn to the exact endpoint of the
  /// line.
  butt('butt'),

  /// A cap with a rounded end which is drawn beyond the endpoint of the line at
  /// a radius of one-half of the line's width and centered on the endpoint of
  /// the line.
  round('round'),

  /// A cap with a squared-off end which is drawn beyond the endpoint of the
  /// line at a distance of one-half of the line's width.
  square('square');

  const LineCap(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `line-join`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum LineJoin implements StyleEnum {
  /// A join with a squared-off end which is drawn beyond the endpoint of the
  /// line at a distance of one-half of the line's width.
  bevel('bevel'),

  /// A join with a rounded end which is drawn beyond the endpoint of the line
  /// at a radius of one-half of the line's width and centered on the endpoint
  /// of the line.
  round('round'),

  /// A join with a sharp, angled corner which is drawn with the outer sides
  /// beyond the endpoint of the path until they meet.
  miter('miter');

  const LineJoin(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `line-translate-anchor`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum LineTranslateAnchor implements StyleEnum {
  /// The line is translated relative to the map.
  map('map'),

  /// The line is translated relative to the viewport.
  viewport('viewport');

  const LineTranslateAnchor(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `encoding`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum RasterDemEncoding implements StyleEnum {
  /// Terrarium format PNG tiles. See
  /// https://aws.amazon.com/es/public-datasets/terrain/ for more info.
  terrarium('terrarium'),

  /// Mapbox Terrain RGB tiles. See
  /// https://www.mapbox.com/help/access-elevation-data/#mapbox-terrain-rgb for
  /// more info.
  mapbox('mapbox'),

  /// Decodes tiles using the redFactor, blueFactor, greenFactor, baseShift
  /// parameters.
  custom('custom');

  const RasterDemEncoding(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `raster-resampling`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum RasterResampling implements StyleEnum {
  /// (Bi)linear filtering interpolates pixel values using the weighted average
  /// of the four closest original source pixels creating a smooth but blurry
  /// look when overscaled
  linear('linear'),

  /// Nearest neighbor filtering interpolates pixel values using the nearest
  /// original source pixel creating a sharp but pixelated look when overscaled
  nearest('nearest');

  const RasterResampling(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `scheme`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum RasterScheme implements StyleEnum {
  /// Slippy map tilenames scheme.
  xyz('xyz'),

  /// OSGeo spec scheme.
  tms('tms');

  const RasterScheme(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `visibility`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum StyleVisibility implements StyleEnum {
  /// The layer is shown.
  visible('visible'),

  /// The layer is not shown.
  none('none');

  const StyleVisibility(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `symbol-placement`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum SymbolPlacement implements StyleEnum {
  /// The label is placed at the point where the geometry is located.
  point('point'),

  /// The label is placed along the line of the geometry. Can only be used on
  /// `LineString` and `Polygon` geometries.
  line('line'),

  /// The label is placed at the center of the line of the geometry. Can only be
  /// used on `LineString` and `Polygon` geometries. Note that a single feature
  /// in a vector tile may contain multiple line geometries.
  lineCenter('line-center');

  const SymbolPlacement(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `symbol-z-order`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum SymbolZOrder implements StyleEnum {
  /// Sorts symbols by `symbol-sort-key` if set. Otherwise, sorts symbols by
  /// their y-position relative to the viewport if `icon-allow-overlap` or
  /// `text-allow-overlap` is set to `true` or `icon-ignore-placement` or
  /// `text-ignore-placement` is `false`.
  auto('auto'),

  /// Sorts symbols by their y-position relative to the viewport if
  /// `icon-allow-overlap` or `text-allow-overlap` is set to `true` or
  /// `icon-ignore-placement` or `text-ignore-placement` is `false`.
  viewportY('viewport-y'),

  /// Sorts symbols by `symbol-sort-key` if set. Otherwise, no sorting is
  /// applied; symbols are rendered in the same order as the source data.
  source('source');

  const SymbolZOrder(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `text-anchor`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum TextAnchor implements StyleEnum {
  /// The center of the text is placed closest to the anchor.
  center('center'),

  /// The left side of the text is placed closest to the anchor.
  left('left'),

  /// The right side of the text is placed closest to the anchor.
  right('right'),

  /// The top of the text is placed closest to the anchor.
  top('top'),

  /// The bottom of the text is placed closest to the anchor.
  bottom('bottom'),

  /// The top left corner of the text is placed closest to the anchor.
  topLeft('top-left'),

  /// The top right corner of the text is placed closest to the anchor.
  topRight('top-right'),

  /// The bottom left corner of the text is placed closest to the anchor.
  bottomLeft('bottom-left'),

  /// The bottom right corner of the text is placed closest to the anchor.
  bottomRight('bottom-right');

  const TextAnchor(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `text-justify`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum TextJustify implements StyleEnum {
  /// The text is aligned towards the anchor position.
  auto('auto'),

  /// The text is aligned to the left.
  left('left'),

  /// The text is centered.
  center('center'),

  /// The text is aligned to the right.
  right('right');

  const TextJustify(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `text-overlap`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum TextOverlap implements StyleEnum {
  /// The text will be hidden if it collides with any other previously drawn
  /// symbol.
  never('never'),

  /// The text will be visible even if it collides with any other previously
  /// drawn symbol.
  always('always'),

  /// If the text collides with another previously drawn symbol, the overlap
  /// mode for that symbol is checked. If the previous symbol was placed using
  /// `never` overlap mode, the new text is hidden. If the previous symbol was
  /// placed using `always` or `cooperative` overlap mode, the new text is
  /// visible.
  cooperative('cooperative');

  const TextOverlap(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `text-pitch-alignment`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum TextPitchAlignment implements StyleEnum {
  /// The text is aligned to the plane of the map.
  map('map'),

  /// The text is aligned to the plane of the viewport.
  viewport('viewport'),

  /// Automatically matches the value of `text-rotation-alignment`.
  auto('auto');

  const TextPitchAlignment(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `text-rotation-alignment`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum TextRotationAlignment implements StyleEnum {
  /// When `symbol-placement` is set to `point`, aligns text east-west. When
  /// `symbol-placement` is set to `line` or `line-center`, aligns text x-axes
  /// with the line.
  map('map'),

  /// Produces glyphs whose x-axes are aligned with the x-axis of the viewport,
  /// regardless of the value of `symbol-placement`.
  viewport('viewport'),

  /// When `symbol-placement` is set to `point`, aligns text to the x-axis of
  /// the viewport. When `symbol-placement` is set to `line` or `line-center`,
  /// aligns glyphs to the x-axis of the viewport and places them along the
  /// line.
  viewportGlyph('viewport-glyph'),

  /// When `symbol-placement` is set to `point`, this is equivalent to
  /// `viewport`. When `symbol-placement` is set to `line` or `line-center`,
  /// this is equivalent to `map`.
  auto('auto');

  const TextRotationAlignment(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `text-transform`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum TextTransform implements StyleEnum {
  /// The text is not altered.
  none('none'),

  /// Forces all letters to be displayed in uppercase.
  uppercase('uppercase'),

  /// Forces all letters to be displayed in lowercase.
  lowercase('lowercase');

  const TextTransform(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `text-translate-anchor`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum TextTranslateAnchor implements StyleEnum {
  /// The text is translated relative to the map.
  map('map'),

  /// The text is translated relative to the viewport.
  viewport('viewport');

  const TextTranslateAnchor(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `text-variable-anchor`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum TextVariableAnchor implements StyleEnum {
  /// The center of the text is placed closest to the anchor.
  center('center'),

  /// The left side of the text is placed closest to the anchor.
  left('left'),

  /// The right side of the text is placed closest to the anchor.
  right('right'),

  /// The top of the text is placed closest to the anchor.
  top('top'),

  /// The bottom of the text is placed closest to the anchor.
  bottom('bottom'),

  /// The top left corner of the text is placed closest to the anchor.
  topLeft('top-left'),

  /// The top right corner of the text is placed closest to the anchor.
  topRight('top-right'),

  /// The bottom left corner of the text is placed closest to the anchor.
  bottomLeft('bottom-left'),

  /// The bottom right corner of the text is placed closest to the anchor.
  bottomRight('bottom-right');

  const TextVariableAnchor(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `text-writing-mode`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum TextWritingMode implements StyleEnum {
  /// If a text's language supports horizontal writing mode, symbols with point
  /// placement would be laid out horizontally.
  horizontal('horizontal'),

  /// If a text's language supports vertical writing mode, symbols with point
  /// placement would be laid out vertically.
  vertical('vertical');

  const TextWritingMode(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `encoding`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum VectorEncoding implements StyleEnum {
  /// Mapbox Vector Tiles. See http://github.com/mapbox/vector-tile-spec for
  /// more info.
  mvt('mvt'),

  /// MapLibre Vector Tiles. See https://github.com/maplibre/maplibre-tile-spec
  /// for more info.
  mlt('mlt');

  const VectorEncoding(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}

/// The values of `scheme`.
///
/// Generated from the spec; [jsonValue] is what it serialises to.
enum VectorScheme implements StyleEnum {
  /// Slippy map tilenames scheme.
  xyz('xyz'),

  /// OSGeo spec scheme.
  tms('tms');

  const VectorScheme(this.jsonValue);

  /// The spec string this value serialises to.
  @override
  final String jsonValue;
}
