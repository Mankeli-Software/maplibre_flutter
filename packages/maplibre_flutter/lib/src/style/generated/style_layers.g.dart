// GENERATED CODE - DO NOT MODIFY BY HAND
//
// Generated from the MapLibre Style Spec (v8) vendored at
// ../maplibre_flutter_core/third_party/maplibre-native/scripts/style-spec-reference/v8.json
// by tool/generate_style_api.dart. Run that to regenerate.

import 'dart:ui' show Color;
import 'package:flutter/foundation.dart' show immutable;

import '../style_encoding.dart';
import '../style_layer.dart';
import '../style_value.dart';
import 'style_enums.g.dart';
import 'style_transition.g.dart';

/// A `fill` style layer. A filled polygon with an optional stroked border.
///
/// Generated from the spec schemas `layer`, `layout_fill` and
/// `paint_fill`. [toJson] produces the document `addLayer` sends, so
/// anything expressible in style JSON is expressible here.
@immutable
final class FillLayer extends StyleLayer {
  /// Creates a `fill` layer.
  const FillLayer({
    required this.id,
    required this.source,
    this.metadata,
    this.sourceLayer,
    this.minZoom,
    this.maxZoom,
    this.filter,
    this.fillSortKey,
    this.visibility,
    this.fillAntialias,
    this.fillOpacity,
    this.fillOpacityTransition,
    this.fillColor,
    this.fillColorTransition,
    this.fillOutlineColor,
    this.fillOutlineColorTransition,
    this.fillTranslate,
    this.fillTranslateTransition,
    this.fillTranslateAnchor,
    this.fillPattern,
    this.fillPatternTransition,
  });

  @override
  final String id;

  @override
  String get type => 'fill';

  /// Name of a source description to be used for this layer. Required for all
  /// layer types except `background`.
  ///
  /// Spec: `source`.
  final String source;

  /// Arbitrary properties useful to track with the layer, but do not influence
  /// rendering. Properties should be prefixed to avoid collisions, like
  /// 'maplibre:'.
  ///
  /// Spec: `metadata`.
  final Object? metadata;

  /// Layer to use from a vector tile source. Required for vector tile sources;
  /// prohibited for all other source types, including GeoJSON sources.
  ///
  /// Spec: `source-layer`.
  final String? sourceLayer;

  /// The minimum zoom level for the layer. At zoom levels less than the
  /// minzoom, the layer will be hidden.
  ///
  /// Spec: `minzoom`.
  final double? minZoom;

  /// The maximum zoom level for the layer. At zoom levels equal to or greater
  /// than the maxzoom, the layer will be hidden.
  ///
  /// Spec: `maxzoom`.
  final double? maxZoom;

  /// A expression specifying conditions on source features. Only features that
  /// match the filter are displayed. Zoom expressions in filters are only
  /// evaluated at integer zoom levels. The `feature-state` expression is not
  /// supported in filter expressions.
  ///
  /// Spec: `filter`.
  final Expression? filter;

  /// Sorts features in ascending order based on this value. Features with a
  /// higher sort key will appear above features with a lower sort key.
  ///
  /// Spec: `fill-sort-key`.
  final StyleValue<double>? fillSortKey;

  /// Whether this layer is displayed.
  ///
  /// Spec: `visibility`. Defaults to `"visible"`.
  /// A constant only — the spec allows no expression here.
  final StyleVisibility? visibility;

  /// Whether or not the fill should be antialiased.
  ///
  /// Spec: `fill-antialias`. Defaults to `true`.
  final StyleValue<bool>? fillAntialias;

  /// The opacity of the entire fill layer. In contrast to the `fill-color`,
  /// this value will also affect the 1px stroke around the fill, if the stroke
  /// is used.
  ///
  /// Spec: `fill-opacity`. Defaults to `1`.
  final StyleValue<double>? fillOpacity;

  /// How `fill-opacity` animates when it changes
  /// (`fill-opacity-transition`).
  final StyleTransition? fillOpacityTransition;

  /// The color of the filled part of this layer. This color can be specified as
  /// `rgba` with an alpha component and the color's opacity will not affect the
  /// opacity of the 1px stroke, if it is used.
  ///
  /// Spec: `fill-color`. Defaults to `"#000000"`.
  /// Requires .
  final StyleValue<Color>? fillColor;

  /// How `fill-color` animates when it changes
  /// (`fill-color-transition`).
  final StyleTransition? fillColorTransition;

  /// The outline color of the fill. Matches the value of `fill-color` if
  /// unspecified.
  ///
  /// Spec: `fill-outline-color`.
  /// Requires .
  final StyleValue<Color>? fillOutlineColor;

  /// How `fill-outline-color` animates when it changes
  /// (`fill-outline-color-transition`).
  final StyleTransition? fillOutlineColorTransition;

  /// The geometry's offset. Values are [x, y] where negatives indicate left and
  /// up, respectively.
  ///
  /// Spec: `fill-translate`, in pixels. Defaults to `[0,0]`.
  final StyleValue<List<double>>? fillTranslate;

  /// How `fill-translate` animates when it changes
  /// (`fill-translate-transition`).
  final StyleTransition? fillTranslateTransition;

  /// Controls the frame of reference for `fill-translate`.
  ///
  /// Spec: `fill-translate-anchor`. Defaults to `"map"`.
  /// Requires `fill-translate`.
  final StyleValue<FillTranslateAnchor>? fillTranslateAnchor;

  /// Name of image in sprite to use for drawing image fills. For seamless
  /// patterns, image width and height must be a factor of two (2, 4, 8, ...,
  /// 512). Note that zoom-dependent expressions will be evaluated only at
  /// integer zoom levels.
  ///
  /// Spec: `fill-pattern`.
  final StyleValue<String>? fillPattern;

  /// How `fill-pattern` animates when it changes
  /// (`fill-pattern-transition`).
  final StyleTransition? fillPatternTransition;

  @override
  Map<String, Object?> toJson() {
    final layout = <String, Object?>{
      if (fillSortKey != null) 'fill-sort-key': fillSortKey!.toJson(),
      if (visibility != null) 'visibility': encodeStyleJson(visibility!),
    };
    final paint = <String, Object?>{
      if (fillAntialias != null) 'fill-antialias': fillAntialias!.toJson(),
      if (fillOpacity != null) 'fill-opacity': fillOpacity!.toJson(),
      if (fillOpacityTransition != null)
        'fill-opacity-transition': fillOpacityTransition!.toJson(),
      if (fillColor != null) 'fill-color': fillColor!.toJson(),
      if (fillColorTransition != null)
        'fill-color-transition': fillColorTransition!.toJson(),
      if (fillOutlineColor != null)
        'fill-outline-color': fillOutlineColor!.toJson(),
      if (fillOutlineColorTransition != null)
        'fill-outline-color-transition': fillOutlineColorTransition!.toJson(),
      if (fillTranslate != null) 'fill-translate': fillTranslate!.toJson(),
      if (fillTranslateTransition != null)
        'fill-translate-transition': fillTranslateTransition!.toJson(),
      if (fillTranslateAnchor != null)
        'fill-translate-anchor': fillTranslateAnchor!.toJson(),
      if (fillPattern != null) 'fill-pattern': fillPattern!.toJson(),
      if (fillPatternTransition != null)
        'fill-pattern-transition': fillPatternTransition!.toJson(),
    };
    return <String, Object?>{
      'id': id,
      'type': type,
      if (metadata != null) 'metadata': encodeStyleJson(metadata),
      'source': source,
      if (sourceLayer != null) 'source-layer': sourceLayer,
      if (minZoom != null) 'minzoom': encodeStyleNumber(minZoom!),
      if (maxZoom != null) 'maxzoom': encodeStyleNumber(maxZoom!),
      if (filter != null) 'filter': filter!.toJson(),
      if (layout.isNotEmpty) 'layout': layout,
      if (paint.isNotEmpty) 'paint': paint,
    };
  }
}

/// A `line` style layer. A stroked line.
///
/// Generated from the spec schemas `layer`, `layout_line` and
/// `paint_line`. [toJson] produces the document `addLayer` sends, so
/// anything expressible in style JSON is expressible here.
@immutable
final class LineLayer extends StyleLayer {
  /// Creates a `line` layer.
  const LineLayer({
    required this.id,
    required this.source,
    this.metadata,
    this.sourceLayer,
    this.minZoom,
    this.maxZoom,
    this.filter,
    this.lineCap,
    this.lineJoin,
    this.lineMiterLimit,
    this.lineRoundLimit,
    this.lineSortKey,
    this.visibility,
    this.lineOpacity,
    this.lineOpacityTransition,
    this.lineColor,
    this.lineColorTransition,
    this.lineTranslate,
    this.lineTranslateTransition,
    this.lineTranslateAnchor,
    this.lineWidth,
    this.lineWidthTransition,
    this.lineGapWidth,
    this.lineGapWidthTransition,
    this.lineOffset,
    this.lineOffsetTransition,
    this.lineBlur,
    this.lineBlurTransition,
    this.lineDasharray,
    this.lineDasharrayTransition,
    this.linePattern,
    this.linePatternTransition,
    this.lineGradient,
  });

  @override
  final String id;

  @override
  String get type => 'line';

  /// Name of a source description to be used for this layer. Required for all
  /// layer types except `background`.
  ///
  /// Spec: `source`.
  final String source;

  /// Arbitrary properties useful to track with the layer, but do not influence
  /// rendering. Properties should be prefixed to avoid collisions, like
  /// 'maplibre:'.
  ///
  /// Spec: `metadata`.
  final Object? metadata;

  /// Layer to use from a vector tile source. Required for vector tile sources;
  /// prohibited for all other source types, including GeoJSON sources.
  ///
  /// Spec: `source-layer`.
  final String? sourceLayer;

  /// The minimum zoom level for the layer. At zoom levels less than the
  /// minzoom, the layer will be hidden.
  ///
  /// Spec: `minzoom`.
  final double? minZoom;

  /// The maximum zoom level for the layer. At zoom levels equal to or greater
  /// than the maxzoom, the layer will be hidden.
  ///
  /// Spec: `maxzoom`.
  final double? maxZoom;

  /// A expression specifying conditions on source features. Only features that
  /// match the filter are displayed. Zoom expressions in filters are only
  /// evaluated at integer zoom levels. The `feature-state` expression is not
  /// supported in filter expressions.
  ///
  /// Spec: `filter`.
  final Expression? filter;

  /// The display of line endings.
  ///
  /// Spec: `line-cap`. Defaults to `"butt"`.
  final StyleValue<LineCap>? lineCap;

  /// The display of lines when joining.
  ///
  /// Spec: `line-join`. Defaults to `"miter"`.
  final StyleValue<LineJoin>? lineJoin;

  /// Used to automatically convert miter joins to bevel joins for sharp angles.
  ///
  /// Spec: `line-miter-limit`. Defaults to `2`.
  /// Requires .
  final StyleValue<double>? lineMiterLimit;

  /// Used to automatically convert round joins to miter joins for shallow
  /// angles.
  ///
  /// Spec: `line-round-limit`. Defaults to `1.05`.
  /// Requires .
  final StyleValue<double>? lineRoundLimit;

  /// Sorts features in ascending order based on this value. Features with a
  /// higher sort key will appear above features with a lower sort key.
  ///
  /// Spec: `line-sort-key`.
  final StyleValue<double>? lineSortKey;

  /// Whether this layer is displayed.
  ///
  /// Spec: `visibility`. Defaults to `"visible"`.
  /// A constant only — the spec allows no expression here.
  final StyleVisibility? visibility;

  /// The opacity at which the line will be drawn.
  ///
  /// Spec: `line-opacity`. Defaults to `1`.
  final StyleValue<double>? lineOpacity;

  /// How `line-opacity` animates when it changes
  /// (`line-opacity-transition`).
  final StyleTransition? lineOpacityTransition;

  /// The color with which the line will be drawn.
  ///
  /// Spec: `line-color`. Defaults to `"#000000"`.
  /// Requires .
  final StyleValue<Color>? lineColor;

  /// How `line-color` animates when it changes
  /// (`line-color-transition`).
  final StyleTransition? lineColorTransition;

  /// The geometry's offset. Values are [x, y] where negatives indicate left and
  /// up, respectively.
  ///
  /// Spec: `line-translate`, in pixels. Defaults to `[0,0]`.
  final StyleValue<List<double>>? lineTranslate;

  /// How `line-translate` animates when it changes
  /// (`line-translate-transition`).
  final StyleTransition? lineTranslateTransition;

  /// Controls the frame of reference for `line-translate`.
  ///
  /// Spec: `line-translate-anchor`. Defaults to `"map"`.
  /// Requires `line-translate`.
  final StyleValue<LineTranslateAnchor>? lineTranslateAnchor;

  /// Stroke thickness.
  ///
  /// Spec: `line-width`, in pixels. Defaults to `1`.
  final StyleValue<double>? lineWidth;

  /// How `line-width` animates when it changes
  /// (`line-width-transition`).
  final StyleTransition? lineWidthTransition;

  /// Draws a line casing outside of a line's actual path. Value indicates the
  /// width of the inner gap.
  ///
  /// Spec: `line-gap-width`, in pixels. Defaults to `0`.
  final StyleValue<double>? lineGapWidth;

  /// How `line-gap-width` animates when it changes
  /// (`line-gap-width-transition`).
  final StyleTransition? lineGapWidthTransition;

  /// The line's offset. For linear features, a positive value offsets the line
  /// to the right, relative to the direction of the line, and a negative value
  /// to the left. For polygon features, a positive value results in an inset,
  /// and a negative value results in an outset.
  ///
  /// Spec: `line-offset`, in pixels. Defaults to `0`.
  final StyleValue<double>? lineOffset;

  /// How `line-offset` animates when it changes
  /// (`line-offset-transition`).
  final StyleTransition? lineOffsetTransition;

  /// Blur applied to the line, in pixels.
  ///
  /// Spec: `line-blur`, in pixels. Defaults to `0`.
  final StyleValue<double>? lineBlur;

  /// How `line-blur` animates when it changes
  /// (`line-blur-transition`).
  final StyleTransition? lineBlurTransition;

  /// Specifies the lengths of the alternating dashes and gaps that form the
  /// dash pattern. The lengths are later scaled by the line width. To convert a
  /// dash length to pixels, multiply the length by the current line width. Note
  /// that GeoJSON sources with `lineMetrics: true` specified won't render
  /// dashed lines to the expected scale. Also note that zoom-dependent
  /// expressions will be evaluated only at integer zoom levels.
  ///
  /// Spec: `line-dasharray`, in line widths.
  /// Requires .
  final StyleValue<List<double>>? lineDasharray;

  /// How `line-dasharray` animates when it changes
  /// (`line-dasharray-transition`).
  final StyleTransition? lineDasharrayTransition;

  /// Name of image in sprite to use for drawing image lines. For seamless
  /// patterns, image width must be a factor of two (2, 4, 8, ..., 512). Note
  /// that zoom-dependent expressions will be evaluated only at integer zoom
  /// levels.
  ///
  /// Spec: `line-pattern`.
  final StyleValue<String>? linePattern;

  /// How `line-pattern` animates when it changes
  /// (`line-pattern-transition`).
  final StyleTransition? linePatternTransition;

  /// Defines a gradient with which to color a line feature. Can only be used
  /// with GeoJSON sources that specify `"lineMetrics": true`.
  ///
  /// Spec: `line-gradient`.
  /// Requires .
  final StyleValue<Color>? lineGradient;

  @override
  Map<String, Object?> toJson() {
    final layout = <String, Object?>{
      if (lineCap != null) 'line-cap': lineCap!.toJson(),
      if (lineJoin != null) 'line-join': lineJoin!.toJson(),
      if (lineMiterLimit != null) 'line-miter-limit': lineMiterLimit!.toJson(),
      if (lineRoundLimit != null) 'line-round-limit': lineRoundLimit!.toJson(),
      if (lineSortKey != null) 'line-sort-key': lineSortKey!.toJson(),
      if (visibility != null) 'visibility': encodeStyleJson(visibility!),
    };
    final paint = <String, Object?>{
      if (lineOpacity != null) 'line-opacity': lineOpacity!.toJson(),
      if (lineOpacityTransition != null)
        'line-opacity-transition': lineOpacityTransition!.toJson(),
      if (lineColor != null) 'line-color': lineColor!.toJson(),
      if (lineColorTransition != null)
        'line-color-transition': lineColorTransition!.toJson(),
      if (lineTranslate != null) 'line-translate': lineTranslate!.toJson(),
      if (lineTranslateTransition != null)
        'line-translate-transition': lineTranslateTransition!.toJson(),
      if (lineTranslateAnchor != null)
        'line-translate-anchor': lineTranslateAnchor!.toJson(),
      if (lineWidth != null) 'line-width': lineWidth!.toJson(),
      if (lineWidthTransition != null)
        'line-width-transition': lineWidthTransition!.toJson(),
      if (lineGapWidth != null) 'line-gap-width': lineGapWidth!.toJson(),
      if (lineGapWidthTransition != null)
        'line-gap-width-transition': lineGapWidthTransition!.toJson(),
      if (lineOffset != null) 'line-offset': lineOffset!.toJson(),
      if (lineOffsetTransition != null)
        'line-offset-transition': lineOffsetTransition!.toJson(),
      if (lineBlur != null) 'line-blur': lineBlur!.toJson(),
      if (lineBlurTransition != null)
        'line-blur-transition': lineBlurTransition!.toJson(),
      if (lineDasharray != null) 'line-dasharray': lineDasharray!.toJson(),
      if (lineDasharrayTransition != null)
        'line-dasharray-transition': lineDasharrayTransition!.toJson(),
      if (linePattern != null) 'line-pattern': linePattern!.toJson(),
      if (linePatternTransition != null)
        'line-pattern-transition': linePatternTransition!.toJson(),
      if (lineGradient != null) 'line-gradient': lineGradient!.toJson(),
    };
    return <String, Object?>{
      'id': id,
      'type': type,
      if (metadata != null) 'metadata': encodeStyleJson(metadata),
      'source': source,
      if (sourceLayer != null) 'source-layer': sourceLayer,
      if (minZoom != null) 'minzoom': encodeStyleNumber(minZoom!),
      if (maxZoom != null) 'maxzoom': encodeStyleNumber(maxZoom!),
      if (filter != null) 'filter': filter!.toJson(),
      if (layout.isNotEmpty) 'layout': layout,
      if (paint.isNotEmpty) 'paint': paint,
    };
  }
}

/// A `symbol` style layer. An icon or a text label.
///
/// Generated from the spec schemas `layer`, `layout_symbol` and
/// `paint_symbol`. [toJson] produces the document `addLayer` sends, so
/// anything expressible in style JSON is expressible here.
@immutable
final class SymbolLayer extends StyleLayer {
  /// Creates a `symbol` layer.
  const SymbolLayer({
    required this.id,
    required this.source,
    this.metadata,
    this.sourceLayer,
    this.minZoom,
    this.maxZoom,
    this.filter,
    this.symbolPlacement,
    this.symbolSpacing,
    this.symbolAvoidEdges,
    this.symbolSortKey,
    this.symbolZOrder,
    this.iconAllowOverlap,
    this.iconOverlap,
    this.iconIgnorePlacement,
    this.iconOptional,
    this.iconRotationAlignment,
    this.iconSize,
    this.iconTextFit,
    this.iconTextFitPadding,
    this.iconImage,
    this.iconRotate,
    this.iconPadding,
    this.iconKeepUpright,
    this.iconOffset,
    this.iconAnchor,
    this.iconPitchAlignment,
    this.textPitchAlignment,
    this.textRotationAlignment,
    this.textField,
    this.textFont,
    this.textSize,
    this.textMaxWidth,
    this.textLineHeight,
    this.textLetterSpacing,
    this.textJustify,
    this.textRadialOffset,
    this.textVariableAnchor,
    this.textVariableAnchorOffset,
    this.textAnchor,
    this.textMaxAngle,
    this.textWritingMode,
    this.textRotate,
    this.textPadding,
    this.textKeepUpright,
    this.textTransform,
    this.textOffset,
    this.textAllowOverlap,
    this.textOverlap,
    this.textIgnorePlacement,
    this.textOptional,
    this.visibility,
    this.iconOpacity,
    this.iconOpacityTransition,
    this.iconColor,
    this.iconColorTransition,
    this.iconHaloColor,
    this.iconHaloColorTransition,
    this.iconHaloWidth,
    this.iconHaloWidthTransition,
    this.iconHaloBlur,
    this.iconHaloBlurTransition,
    this.iconTranslate,
    this.iconTranslateTransition,
    this.iconTranslateAnchor,
    this.textOpacity,
    this.textOpacityTransition,
    this.textColor,
    this.textColorTransition,
    this.textHaloColor,
    this.textHaloColorTransition,
    this.textHaloWidth,
    this.textHaloWidthTransition,
    this.textHaloBlur,
    this.textHaloBlurTransition,
    this.textTranslate,
    this.textTranslateTransition,
    this.textTranslateAnchor,
  });

  @override
  final String id;

  @override
  String get type => 'symbol';

  /// Name of a source description to be used for this layer. Required for all
  /// layer types except `background`.
  ///
  /// Spec: `source`.
  final String source;

  /// Arbitrary properties useful to track with the layer, but do not influence
  /// rendering. Properties should be prefixed to avoid collisions, like
  /// 'maplibre:'.
  ///
  /// Spec: `metadata`.
  final Object? metadata;

  /// Layer to use from a vector tile source. Required for vector tile sources;
  /// prohibited for all other source types, including GeoJSON sources.
  ///
  /// Spec: `source-layer`.
  final String? sourceLayer;

  /// The minimum zoom level for the layer. At zoom levels less than the
  /// minzoom, the layer will be hidden.
  ///
  /// Spec: `minzoom`.
  final double? minZoom;

  /// The maximum zoom level for the layer. At zoom levels equal to or greater
  /// than the maxzoom, the layer will be hidden.
  ///
  /// Spec: `maxzoom`.
  final double? maxZoom;

  /// A expression specifying conditions on source features. Only features that
  /// match the filter are displayed. Zoom expressions in filters are only
  /// evaluated at integer zoom levels. The `feature-state` expression is not
  /// supported in filter expressions.
  ///
  /// Spec: `filter`.
  final Expression? filter;

  /// Label placement relative to its geometry.
  ///
  /// Spec: `symbol-placement`. Defaults to `"point"`.
  final StyleValue<SymbolPlacement>? symbolPlacement;

  /// Distance between two symbol anchors.
  ///
  /// Spec: `symbol-spacing`, in pixels. Defaults to `250`.
  /// Requires .
  final StyleValue<double>? symbolSpacing;

  /// If true, the symbols will not cross tile edges to avoid mutual collisions.
  /// Recommended in layers that don't have enough padding in the vector tile to
  /// prevent collisions, or if it is a point symbol layer placed after a line
  /// symbol layer. When using a client that supports global collision
  /// detection, like MapLibre GL JS version 0.42.0 or greater, enabling this
  /// property is not needed to prevent clipped labels at tile boundaries.
  ///
  /// Spec: `symbol-avoid-edges`. Defaults to `false`.
  final StyleValue<bool>? symbolAvoidEdges;

  /// Sorts features in ascending order based on this value. Features with lower
  /// sort keys are drawn and placed first. When `icon-allow-overlap` or
  /// `text-allow-overlap` is `false`, features with a lower sort key will have
  /// priority during placement. When `icon-allow-overlap` or
  /// `text-allow-overlap` is set to `true`, features with a higher sort key
  /// will overlap over features with a lower sort key.
  ///
  /// Spec: `symbol-sort-key`.
  final StyleValue<double>? symbolSortKey;

  /// Determines whether overlapping symbols in the same layer are rendered in
  /// the order that they appear in the data source or by their y-position
  /// relative to the viewport. To control the order and prioritization of
  /// symbols otherwise, use `symbol-sort-key`.
  ///
  /// Spec: `symbol-z-order`. Defaults to `"auto"`.
  final StyleValue<SymbolZOrder>? symbolZOrder;

  /// If true, the icon will be visible even if it collides with other
  /// previously drawn symbols.
  ///
  /// Spec: `icon-allow-overlap`. Defaults to `false`.
  /// Requires `icon-image`.
  final StyleValue<bool>? iconAllowOverlap;

  /// Allows for control over whether to show an icon when it overlaps other
  /// symbols on the map. If `icon-overlap` is not set, `icon-allow-overlap` is
  /// used instead.
  ///
  /// Spec: `icon-overlap`.
  /// Requires `icon-image`.
  final StyleValue<IconOverlap>? iconOverlap;

  /// If true, other symbols can be visible even if they collide with the icon.
  ///
  /// Spec: `icon-ignore-placement`. Defaults to `false`.
  /// Requires `icon-image`.
  final StyleValue<bool>? iconIgnorePlacement;

  /// If true, text will display without their corresponding icons when the icon
  /// collides with other symbols and the text does not.
  ///
  /// Spec: `icon-optional`. Defaults to `false`.
  /// Requires `icon-image`, `text-field`.
  final StyleValue<bool>? iconOptional;

  /// In combination with `symbol-placement`, determines the rotation behavior
  /// of icons.
  ///
  /// Spec: `icon-rotation-alignment`. Defaults to `"auto"`.
  /// Requires `icon-image`.
  final StyleValue<IconRotationAlignment>? iconRotationAlignment;

  /// Scales the original size of the icon by the provided factor. The new pixel
  /// size of the image will be the original pixel size multiplied by
  /// `icon-size`. 1 is the original size; 3 triples the size of the image.
  ///
  /// Spec: `icon-size`, in factor of the original icon size. Defaults to `1`.
  /// Requires `icon-image`.
  final StyleValue<double>? iconSize;

  /// Scales the icon to fit around the associated text.
  ///
  /// Spec: `icon-text-fit`. Defaults to `"none"`.
  /// Requires `icon-image`, `text-field`.
  final StyleValue<IconTextFit>? iconTextFit;

  /// Size of the additional area added to dimensions determined by
  /// `icon-text-fit`, in clockwise order: top, right, bottom, left.
  ///
  /// Spec: `icon-text-fit-padding`, in pixels. Defaults to `[0,0,0,0]`.
  /// Requires `icon-image`, `text-field`.
  final StyleValue<List<double>>? iconTextFitPadding;

  /// Name of image in sprite to use for drawing an image background.
  ///
  /// Spec: `icon-image`.
  final StyleValue<String>? iconImage;

  /// Rotates the icon clockwise.
  ///
  /// Spec: `icon-rotate`, in degrees. Defaults to `0`.
  /// Requires `icon-image`.
  final StyleValue<double>? iconRotate;

  /// Size of additional area round the icon bounding box used for detecting
  /// symbol collisions.
  ///
  /// Spec: `icon-padding`, in pixels. Defaults to `[2]`.
  /// Requires `icon-image`.
  final StyleValue<List<double>>? iconPadding;

  /// If true, the icon may be flipped to prevent it from being rendered
  /// upside-down.
  ///
  /// Spec: `icon-keep-upright`. Defaults to `false`.
  /// Requires `icon-image`.
  final StyleValue<bool>? iconKeepUpright;

  /// Offset distance of icon from its anchor. Positive values indicate right
  /// and down, while negative values indicate left and up. Each component is
  /// multiplied by the value of `icon-size` to obtain the final offset in
  /// pixels. When combined with `icon-rotate` the offset will be as if the
  /// rotated direction was up.
  ///
  /// Spec: `icon-offset`. Defaults to `[0,0]`.
  /// Requires `icon-image`.
  final StyleValue<List<double>>? iconOffset;

  /// Part of the icon placed closest to the anchor.
  ///
  /// Spec: `icon-anchor`. Defaults to `"center"`.
  /// Requires `icon-image`.
  final StyleValue<IconAnchor>? iconAnchor;

  /// Orientation of icon when map is pitched.
  ///
  /// Spec: `icon-pitch-alignment`. Defaults to `"auto"`.
  /// Requires `icon-image`.
  final StyleValue<IconPitchAlignment>? iconPitchAlignment;

  /// Orientation of text when map is pitched.
  ///
  /// Spec: `text-pitch-alignment`. Defaults to `"auto"`.
  /// Requires `text-field`.
  final StyleValue<TextPitchAlignment>? textPitchAlignment;

  /// In combination with `symbol-placement`, determines the rotation behavior
  /// of the individual glyphs forming the text.
  ///
  /// Spec: `text-rotation-alignment`. Defaults to `"auto"`.
  /// Requires `text-field`.
  final StyleValue<TextRotationAlignment>? textRotationAlignment;

  /// Value to use for a text label. If a plain `string` is provided, it will be
  /// treated as a `formatted` with default/inherited formatting options.
  ///
  /// Spec: `text-field`. Defaults to `""`.
  final StyleValue<String>? textField;

  /// Fonts to use for displaying text. If the `glyphs` root property is
  /// specified, this array is joined together and interpreted as a font stack
  /// name. Otherwise, it is interpreted as a cascading fallback list of local
  /// font names.
  ///
  /// Spec: `text-font`. Defaults to `["Open Sans Regular","Arial Unicode MS
  /// Regular"]`.
  /// Requires `text-field`.
  final StyleValue<List<String>>? textFont;

  /// Font size.
  ///
  /// Spec: `text-size`, in pixels. Defaults to `16`.
  /// Requires `text-field`.
  final StyleValue<double>? textSize;

  /// The maximum line width for text wrapping.
  ///
  /// Spec: `text-max-width`, in ems. Defaults to `10`.
  /// Requires `text-field`.
  final StyleValue<double>? textMaxWidth;

  /// Text leading value for multi-line text.
  ///
  /// Spec: `text-line-height`, in ems. Defaults to `1.2`.
  /// Requires `text-field`.
  final StyleValue<double>? textLineHeight;

  /// Text tracking amount.
  ///
  /// Spec: `text-letter-spacing`, in ems. Defaults to `0`.
  /// Requires `text-field`.
  final StyleValue<double>? textLetterSpacing;

  /// Text justification options.
  ///
  /// Spec: `text-justify`. Defaults to `"center"`.
  /// Requires `text-field`.
  final StyleValue<TextJustify>? textJustify;

  /// Radial offset of text, in the direction of the symbol's anchor. Useful in
  /// combination with `text-variable-anchor`, which defaults to using the
  /// two-dimensional `text-offset` if present.
  ///
  /// Spec: `text-radial-offset`, in ems. Defaults to `0`.
  /// Requires `text-field`.
  final StyleValue<double>? textRadialOffset;

  /// To increase the chance of placing high-priority labels on the map, you can
  /// provide an array of `text-anchor` locations: the renderer will attempt to
  /// place the label at each location, in order, before moving onto the next
  /// label. Use `text-justify: auto` to choose justification based on anchor
  /// position. To apply an offset, use the `text-radial-offset` or the
  /// two-dimensional `text-offset`.
  ///
  /// Spec: `text-variable-anchor`.
  /// Requires `text-field`.
  final StyleValue<List<TextVariableAnchor>>? textVariableAnchor;

  /// To increase the chance of placing high-priority labels on the map, you can
  /// provide an array of `text-anchor` locations, each paired with an offset
  /// value. The renderer will attempt to place the label at each location, in
  /// order, before moving on to the next location+offset. Use `text-justify:
  /// auto` to choose justification based on anchor position.
  ///
  /// The length of the array must be even, and must alternate between enum and
  /// point entries. i.e., each anchor location must be accompanied by a point,
  /// and that point defines the offset when the corresponding anchor location
  /// is used. Positive offset values indicate right and down, while negative
  /// values indicate left and up. Anchor locations may repeat, allowing the
  /// renderer to try multiple offsets to try and place a label using the same
  /// anchor.
  ///
  /// When present, this property takes precedence over `text-anchor`,
  /// `text-variable-anchor`, `text-offset`, and `text-radial-offset`.
  ///
  /// ```json
  ///
  /// { "text-variable-anchor-offset": ["top", [0, 4], "left", [3,0], "bottom",
  /// [1, 1]] }
  ///
  /// ```
  ///
  /// When the renderer chooses the `top` anchor, `[0, 4]` will be used for
  /// `text-offset`; the text will be shifted down by 4 ems.
  ///
  /// When the renderer chooses the `left` anchor, `[3, 0]` will be used for
  /// `text-offset`; the text will be shifted right by 3 ems.
  ///
  /// Spec: `text-variable-anchor-offset`.
  /// Requires `text-field`.
  final StyleValue<List<Object>>? textVariableAnchorOffset;

  /// Part of the text placed closest to the anchor.
  ///
  /// Spec: `text-anchor`. Defaults to `"center"`.
  /// Requires `text-field`.
  final StyleValue<TextAnchor>? textAnchor;

  /// Maximum angle change between adjacent characters.
  ///
  /// Spec: `text-max-angle`, in degrees. Defaults to `45`.
  /// Requires `text-field`.
  final StyleValue<double>? textMaxAngle;

  /// The property allows control over a symbol's orientation. Note that the
  /// property values act as a hint, so that a symbol whose language doesn’t
  /// support the provided orientation will be laid out in its natural
  /// orientation. Example: English point symbol will be rendered horizontally
  /// even if array value contains single 'vertical' enum value. The order of
  /// elements in an array define priority order for the placement of an
  /// orientation variant.
  ///
  /// Spec: `text-writing-mode`.
  /// Requires `text-field`.
  final StyleValue<List<TextWritingMode>>? textWritingMode;

  /// Rotates the text clockwise.
  ///
  /// Spec: `text-rotate`, in degrees. Defaults to `0`.
  /// Requires `text-field`.
  final StyleValue<double>? textRotate;

  /// Size of the additional area around the text bounding box used for
  /// detecting symbol collisions.
  ///
  /// Spec: `text-padding`, in pixels. Defaults to `2`.
  /// Requires `text-field`.
  final StyleValue<double>? textPadding;

  /// If true, the text may be flipped vertically to prevent it from being
  /// rendered upside-down.
  ///
  /// Spec: `text-keep-upright`. Defaults to `true`.
  /// Requires `text-field`.
  final StyleValue<bool>? textKeepUpright;

  /// Specifies how to capitalize text, similar to the CSS `text-transform`
  /// property.
  ///
  /// Spec: `text-transform`. Defaults to `"none"`.
  /// Requires `text-field`.
  final StyleValue<TextTransform>? textTransform;

  /// Offset distance of text from its anchor. Positive values indicate right
  /// and down, while negative values indicate left and up. If used with
  /// text-variable-anchor, input values will be taken as absolute values.
  /// Offsets along the x- and y-axis will be applied automatically based on the
  /// anchor position.
  ///
  /// Spec: `text-offset`, in ems. Defaults to `[0,0]`.
  /// Requires `text-field`.
  final StyleValue<List<double>>? textOffset;

  /// If true, the text will be visible even if it collides with other
  /// previously drawn symbols.
  ///
  /// Spec: `text-allow-overlap`. Defaults to `false`.
  /// Requires `text-field`.
  final StyleValue<bool>? textAllowOverlap;

  /// Allows for control over whether to show symbol text when it overlaps other
  /// symbols on the map. If `text-overlap` is not set, `text-allow-overlap` is
  /// used instead
  ///
  /// Spec: `text-overlap`.
  /// Requires `text-field`.
  final StyleValue<TextOverlap>? textOverlap;

  /// If true, other symbols can be visible even if they collide with the text.
  ///
  /// Spec: `text-ignore-placement`. Defaults to `false`.
  /// Requires `text-field`.
  final StyleValue<bool>? textIgnorePlacement;

  /// If true, icons will display without their corresponding text when the text
  /// collides with other symbols and the icon does not.
  ///
  /// Spec: `text-optional`. Defaults to `false`.
  /// Requires `text-field`, `icon-image`.
  final StyleValue<bool>? textOptional;

  /// Whether this layer is displayed.
  ///
  /// Spec: `visibility`. Defaults to `"visible"`.
  /// A constant only — the spec allows no expression here.
  final StyleVisibility? visibility;

  /// The opacity at which the icon will be drawn.
  ///
  /// Spec: `icon-opacity`. Defaults to `1`.
  /// Requires `icon-image`.
  final StyleValue<double>? iconOpacity;

  /// How `icon-opacity` animates when it changes
  /// (`icon-opacity-transition`).
  final StyleTransition? iconOpacityTransition;

  /// The color of the icon. This can only be used with SDF icons.
  ///
  /// Spec: `icon-color`. Defaults to `"#000000"`.
  /// Requires `icon-image`.
  final StyleValue<Color>? iconColor;

  /// How `icon-color` animates when it changes
  /// (`icon-color-transition`).
  final StyleTransition? iconColorTransition;

  /// The color of the icon's halo. Icon halos can only be used with SDF icons.
  ///
  /// Spec: `icon-halo-color`. Defaults to `"rgba(0, 0, 0, 0)"`.
  /// Requires `icon-image`.
  final StyleValue<Color>? iconHaloColor;

  /// How `icon-halo-color` animates when it changes
  /// (`icon-halo-color-transition`).
  final StyleTransition? iconHaloColorTransition;

  /// Distance of halo to the icon outline.
  ///
  /// The unit is in pixels only for SDF sprites that were created with a blur
  /// radius of 8, multiplied by the display density. I.e., the radius needs to
  /// be 16 for `@2x` sprites, etc.
  ///
  /// Spec: `icon-halo-width`, in pixels. Defaults to `0`.
  /// Requires `icon-image`.
  final StyleValue<double>? iconHaloWidth;

  /// How `icon-halo-width` animates when it changes
  /// (`icon-halo-width-transition`).
  final StyleTransition? iconHaloWidthTransition;

  /// Fade out the halo towards the outside.
  ///
  /// Spec: `icon-halo-blur`, in pixels. Defaults to `0`.
  /// Requires `icon-image`.
  final StyleValue<double>? iconHaloBlur;

  /// How `icon-halo-blur` animates when it changes
  /// (`icon-halo-blur-transition`).
  final StyleTransition? iconHaloBlurTransition;

  /// Distance that the icon's anchor is moved from its original placement.
  /// Positive values indicate right and down, while negative values indicate
  /// left and up.
  ///
  /// Spec: `icon-translate`, in pixels. Defaults to `[0,0]`.
  /// Requires `icon-image`.
  final StyleValue<List<double>>? iconTranslate;

  /// How `icon-translate` animates when it changes
  /// (`icon-translate-transition`).
  final StyleTransition? iconTranslateTransition;

  /// Controls the frame of reference for `icon-translate`.
  ///
  /// Spec: `icon-translate-anchor`. Defaults to `"map"`.
  /// Requires `icon-image`, `icon-translate`.
  final StyleValue<IconTranslateAnchor>? iconTranslateAnchor;

  /// The opacity at which the text will be drawn.
  ///
  /// Spec: `text-opacity`. Defaults to `1`.
  /// Requires `text-field`.
  final StyleValue<double>? textOpacity;

  /// How `text-opacity` animates when it changes
  /// (`text-opacity-transition`).
  final StyleTransition? textOpacityTransition;

  /// The color with which the text will be drawn.
  ///
  /// Spec: `text-color`. Defaults to `"#000000"`.
  /// Requires `text-field`.
  final StyleValue<Color>? textColor;

  /// How `text-color` animates when it changes
  /// (`text-color-transition`).
  final StyleTransition? textColorTransition;

  /// The color of the text's halo, which helps it stand out from backgrounds.
  ///
  /// Spec: `text-halo-color`. Defaults to `"rgba(0, 0, 0, 0)"`.
  /// Requires `text-field`.
  final StyleValue<Color>? textHaloColor;

  /// How `text-halo-color` animates when it changes
  /// (`text-halo-color-transition`).
  final StyleTransition? textHaloColorTransition;

  /// Distance of halo to the font outline. Max text halo width is 1/4 of the
  /// font-size.
  ///
  /// Spec: `text-halo-width`, in pixels. Defaults to `0`.
  /// Requires `text-field`.
  final StyleValue<double>? textHaloWidth;

  /// How `text-halo-width` animates when it changes
  /// (`text-halo-width-transition`).
  final StyleTransition? textHaloWidthTransition;

  /// The halo's fadeout distance towards the outside.
  ///
  /// Spec: `text-halo-blur`, in pixels. Defaults to `0`.
  /// Requires `text-field`.
  final StyleValue<double>? textHaloBlur;

  /// How `text-halo-blur` animates when it changes
  /// (`text-halo-blur-transition`).
  final StyleTransition? textHaloBlurTransition;

  /// Distance that the text's anchor is moved from its original placement.
  /// Positive values indicate right and down, while negative values indicate
  /// left and up.
  ///
  /// Spec: `text-translate`, in pixels. Defaults to `[0,0]`.
  /// Requires `text-field`.
  final StyleValue<List<double>>? textTranslate;

  /// How `text-translate` animates when it changes
  /// (`text-translate-transition`).
  final StyleTransition? textTranslateTransition;

  /// Controls the frame of reference for `text-translate`.
  ///
  /// Spec: `text-translate-anchor`. Defaults to `"map"`.
  /// Requires `text-field`, `text-translate`.
  final StyleValue<TextTranslateAnchor>? textTranslateAnchor;

  @override
  Map<String, Object?> toJson() {
    final layout = <String, Object?>{
      if (symbolPlacement != null)
        'symbol-placement': symbolPlacement!.toJson(),
      if (symbolSpacing != null) 'symbol-spacing': symbolSpacing!.toJson(),
      if (symbolAvoidEdges != null)
        'symbol-avoid-edges': symbolAvoidEdges!.toJson(),
      if (symbolSortKey != null) 'symbol-sort-key': symbolSortKey!.toJson(),
      if (symbolZOrder != null) 'symbol-z-order': symbolZOrder!.toJson(),
      if (iconAllowOverlap != null)
        'icon-allow-overlap': iconAllowOverlap!.toJson(),
      if (iconOverlap != null) 'icon-overlap': iconOverlap!.toJson(),
      if (iconIgnorePlacement != null)
        'icon-ignore-placement': iconIgnorePlacement!.toJson(),
      if (iconOptional != null) 'icon-optional': iconOptional!.toJson(),
      if (iconRotationAlignment != null)
        'icon-rotation-alignment': iconRotationAlignment!.toJson(),
      if (iconSize != null) 'icon-size': iconSize!.toJson(),
      if (iconTextFit != null) 'icon-text-fit': iconTextFit!.toJson(),
      if (iconTextFitPadding != null)
        'icon-text-fit-padding': iconTextFitPadding!.toJson(),
      if (iconImage != null) 'icon-image': iconImage!.toJson(),
      if (iconRotate != null) 'icon-rotate': iconRotate!.toJson(),
      if (iconPadding != null) 'icon-padding': iconPadding!.toJson(),
      if (iconKeepUpright != null)
        'icon-keep-upright': iconKeepUpright!.toJson(),
      if (iconOffset != null) 'icon-offset': iconOffset!.toJson(),
      if (iconAnchor != null) 'icon-anchor': iconAnchor!.toJson(),
      if (iconPitchAlignment != null)
        'icon-pitch-alignment': iconPitchAlignment!.toJson(),
      if (textPitchAlignment != null)
        'text-pitch-alignment': textPitchAlignment!.toJson(),
      if (textRotationAlignment != null)
        'text-rotation-alignment': textRotationAlignment!.toJson(),
      if (textField != null) 'text-field': textField!.toJson(),
      if (textFont != null) 'text-font': textFont!.toJson(),
      if (textSize != null) 'text-size': textSize!.toJson(),
      if (textMaxWidth != null) 'text-max-width': textMaxWidth!.toJson(),
      if (textLineHeight != null) 'text-line-height': textLineHeight!.toJson(),
      if (textLetterSpacing != null)
        'text-letter-spacing': textLetterSpacing!.toJson(),
      if (textJustify != null) 'text-justify': textJustify!.toJson(),
      if (textRadialOffset != null)
        'text-radial-offset': textRadialOffset!.toJson(),
      if (textVariableAnchor != null)
        'text-variable-anchor': textVariableAnchor!.toJson(),
      if (textVariableAnchorOffset != null)
        'text-variable-anchor-offset': textVariableAnchorOffset!.toJson(),
      if (textAnchor != null) 'text-anchor': textAnchor!.toJson(),
      if (textMaxAngle != null) 'text-max-angle': textMaxAngle!.toJson(),
      if (textWritingMode != null)
        'text-writing-mode': textWritingMode!.toJson(),
      if (textRotate != null) 'text-rotate': textRotate!.toJson(),
      if (textPadding != null) 'text-padding': textPadding!.toJson(),
      if (textKeepUpright != null)
        'text-keep-upright': textKeepUpright!.toJson(),
      if (textTransform != null) 'text-transform': textTransform!.toJson(),
      if (textOffset != null) 'text-offset': textOffset!.toJson(),
      if (textAllowOverlap != null)
        'text-allow-overlap': textAllowOverlap!.toJson(),
      if (textOverlap != null) 'text-overlap': textOverlap!.toJson(),
      if (textIgnorePlacement != null)
        'text-ignore-placement': textIgnorePlacement!.toJson(),
      if (textOptional != null) 'text-optional': textOptional!.toJson(),
      if (visibility != null) 'visibility': encodeStyleJson(visibility!),
    };
    final paint = <String, Object?>{
      if (iconOpacity != null) 'icon-opacity': iconOpacity!.toJson(),
      if (iconOpacityTransition != null)
        'icon-opacity-transition': iconOpacityTransition!.toJson(),
      if (iconColor != null) 'icon-color': iconColor!.toJson(),
      if (iconColorTransition != null)
        'icon-color-transition': iconColorTransition!.toJson(),
      if (iconHaloColor != null) 'icon-halo-color': iconHaloColor!.toJson(),
      if (iconHaloColorTransition != null)
        'icon-halo-color-transition': iconHaloColorTransition!.toJson(),
      if (iconHaloWidth != null) 'icon-halo-width': iconHaloWidth!.toJson(),
      if (iconHaloWidthTransition != null)
        'icon-halo-width-transition': iconHaloWidthTransition!.toJson(),
      if (iconHaloBlur != null) 'icon-halo-blur': iconHaloBlur!.toJson(),
      if (iconHaloBlurTransition != null)
        'icon-halo-blur-transition': iconHaloBlurTransition!.toJson(),
      if (iconTranslate != null) 'icon-translate': iconTranslate!.toJson(),
      if (iconTranslateTransition != null)
        'icon-translate-transition': iconTranslateTransition!.toJson(),
      if (iconTranslateAnchor != null)
        'icon-translate-anchor': iconTranslateAnchor!.toJson(),
      if (textOpacity != null) 'text-opacity': textOpacity!.toJson(),
      if (textOpacityTransition != null)
        'text-opacity-transition': textOpacityTransition!.toJson(),
      if (textColor != null) 'text-color': textColor!.toJson(),
      if (textColorTransition != null)
        'text-color-transition': textColorTransition!.toJson(),
      if (textHaloColor != null) 'text-halo-color': textHaloColor!.toJson(),
      if (textHaloColorTransition != null)
        'text-halo-color-transition': textHaloColorTransition!.toJson(),
      if (textHaloWidth != null) 'text-halo-width': textHaloWidth!.toJson(),
      if (textHaloWidthTransition != null)
        'text-halo-width-transition': textHaloWidthTransition!.toJson(),
      if (textHaloBlur != null) 'text-halo-blur': textHaloBlur!.toJson(),
      if (textHaloBlurTransition != null)
        'text-halo-blur-transition': textHaloBlurTransition!.toJson(),
      if (textTranslate != null) 'text-translate': textTranslate!.toJson(),
      if (textTranslateTransition != null)
        'text-translate-transition': textTranslateTransition!.toJson(),
      if (textTranslateAnchor != null)
        'text-translate-anchor': textTranslateAnchor!.toJson(),
    };
    return <String, Object?>{
      'id': id,
      'type': type,
      if (metadata != null) 'metadata': encodeStyleJson(metadata),
      'source': source,
      if (sourceLayer != null) 'source-layer': sourceLayer,
      if (minZoom != null) 'minzoom': encodeStyleNumber(minZoom!),
      if (maxZoom != null) 'maxzoom': encodeStyleNumber(maxZoom!),
      if (filter != null) 'filter': filter!.toJson(),
      if (layout.isNotEmpty) 'layout': layout,
      if (paint.isNotEmpty) 'paint': paint,
    };
  }
}

/// A `circle` style layer. A filled circle.
///
/// Generated from the spec schemas `layer`, `layout_circle` and
/// `paint_circle`. [toJson] produces the document `addLayer` sends, so
/// anything expressible in style JSON is expressible here.
@immutable
final class CircleLayer extends StyleLayer {
  /// Creates a `circle` layer.
  const CircleLayer({
    required this.id,
    required this.source,
    this.metadata,
    this.sourceLayer,
    this.minZoom,
    this.maxZoom,
    this.filter,
    this.circleSortKey,
    this.visibility,
    this.circleRadius,
    this.circleRadiusTransition,
    this.circleColor,
    this.circleColorTransition,
    this.circleBlur,
    this.circleBlurTransition,
    this.circleOpacity,
    this.circleOpacityTransition,
    this.circleTranslate,
    this.circleTranslateTransition,
    this.circleTranslateAnchor,
    this.circlePitchScale,
    this.circlePitchAlignment,
    this.circleStrokeWidth,
    this.circleStrokeWidthTransition,
    this.circleStrokeColor,
    this.circleStrokeColorTransition,
    this.circleStrokeOpacity,
    this.circleStrokeOpacityTransition,
  });

  @override
  final String id;

  @override
  String get type => 'circle';

  /// Name of a source description to be used for this layer. Required for all
  /// layer types except `background`.
  ///
  /// Spec: `source`.
  final String source;

  /// Arbitrary properties useful to track with the layer, but do not influence
  /// rendering. Properties should be prefixed to avoid collisions, like
  /// 'maplibre:'.
  ///
  /// Spec: `metadata`.
  final Object? metadata;

  /// Layer to use from a vector tile source. Required for vector tile sources;
  /// prohibited for all other source types, including GeoJSON sources.
  ///
  /// Spec: `source-layer`.
  final String? sourceLayer;

  /// The minimum zoom level for the layer. At zoom levels less than the
  /// minzoom, the layer will be hidden.
  ///
  /// Spec: `minzoom`.
  final double? minZoom;

  /// The maximum zoom level for the layer. At zoom levels equal to or greater
  /// than the maxzoom, the layer will be hidden.
  ///
  /// Spec: `maxzoom`.
  final double? maxZoom;

  /// A expression specifying conditions on source features. Only features that
  /// match the filter are displayed. Zoom expressions in filters are only
  /// evaluated at integer zoom levels. The `feature-state` expression is not
  /// supported in filter expressions.
  ///
  /// Spec: `filter`.
  final Expression? filter;

  /// Sorts features in ascending order based on this value. Features with a
  /// higher sort key will appear above features with a lower sort key.
  ///
  /// Spec: `circle-sort-key`.
  final StyleValue<double>? circleSortKey;

  /// Whether this layer is displayed.
  ///
  /// Spec: `visibility`. Defaults to `"visible"`.
  /// A constant only — the spec allows no expression here.
  final StyleVisibility? visibility;

  /// Circle radius.
  ///
  /// Spec: `circle-radius`, in pixels. Defaults to `5`.
  final StyleValue<double>? circleRadius;

  /// How `circle-radius` animates when it changes
  /// (`circle-radius-transition`).
  final StyleTransition? circleRadiusTransition;

  /// The fill color of the circle.
  ///
  /// Spec: `circle-color`. Defaults to `"#000000"`.
  final StyleValue<Color>? circleColor;

  /// How `circle-color` animates when it changes
  /// (`circle-color-transition`).
  final StyleTransition? circleColorTransition;

  /// Amount to blur the circle. 1 blurs the circle such that only the
  /// centerpoint is full opacity.
  ///
  /// Spec: `circle-blur`. Defaults to `0`.
  final StyleValue<double>? circleBlur;

  /// How `circle-blur` animates when it changes
  /// (`circle-blur-transition`).
  final StyleTransition? circleBlurTransition;

  /// The opacity at which the circle will be drawn.
  ///
  /// Spec: `circle-opacity`. Defaults to `1`.
  final StyleValue<double>? circleOpacity;

  /// How `circle-opacity` animates when it changes
  /// (`circle-opacity-transition`).
  final StyleTransition? circleOpacityTransition;

  /// The geometry's offset. Values are [x, y] where negatives indicate left and
  /// up, respectively.
  ///
  /// Spec: `circle-translate`, in pixels. Defaults to `[0,0]`.
  final StyleValue<List<double>>? circleTranslate;

  /// How `circle-translate` animates when it changes
  /// (`circle-translate-transition`).
  final StyleTransition? circleTranslateTransition;

  /// Controls the frame of reference for `circle-translate`.
  ///
  /// Spec: `circle-translate-anchor`. Defaults to `"map"`.
  /// Requires `circle-translate`.
  final StyleValue<CircleTranslateAnchor>? circleTranslateAnchor;

  /// Controls the scaling behavior of the circle when the map is pitched.
  ///
  /// Spec: `circle-pitch-scale`. Defaults to `"map"`.
  final StyleValue<CirclePitchScale>? circlePitchScale;

  /// Orientation of circle when map is pitched.
  ///
  /// Spec: `circle-pitch-alignment`. Defaults to `"viewport"`.
  final StyleValue<CirclePitchAlignment>? circlePitchAlignment;

  /// The width of the circle's stroke. Strokes are placed outside of the
  /// `circle-radius`.
  ///
  /// Spec: `circle-stroke-width`, in pixels. Defaults to `0`.
  final StyleValue<double>? circleStrokeWidth;

  /// How `circle-stroke-width` animates when it changes
  /// (`circle-stroke-width-transition`).
  final StyleTransition? circleStrokeWidthTransition;

  /// The stroke color of the circle.
  ///
  /// Spec: `circle-stroke-color`. Defaults to `"#000000"`.
  final StyleValue<Color>? circleStrokeColor;

  /// How `circle-stroke-color` animates when it changes
  /// (`circle-stroke-color-transition`).
  final StyleTransition? circleStrokeColorTransition;

  /// The opacity of the circle's stroke.
  ///
  /// Spec: `circle-stroke-opacity`. Defaults to `1`.
  final StyleValue<double>? circleStrokeOpacity;

  /// How `circle-stroke-opacity` animates when it changes
  /// (`circle-stroke-opacity-transition`).
  final StyleTransition? circleStrokeOpacityTransition;

  @override
  Map<String, Object?> toJson() {
    final layout = <String, Object?>{
      if (circleSortKey != null) 'circle-sort-key': circleSortKey!.toJson(),
      if (visibility != null) 'visibility': encodeStyleJson(visibility!),
    };
    final paint = <String, Object?>{
      if (circleRadius != null) 'circle-radius': circleRadius!.toJson(),
      if (circleRadiusTransition != null)
        'circle-radius-transition': circleRadiusTransition!.toJson(),
      if (circleColor != null) 'circle-color': circleColor!.toJson(),
      if (circleColorTransition != null)
        'circle-color-transition': circleColorTransition!.toJson(),
      if (circleBlur != null) 'circle-blur': circleBlur!.toJson(),
      if (circleBlurTransition != null)
        'circle-blur-transition': circleBlurTransition!.toJson(),
      if (circleOpacity != null) 'circle-opacity': circleOpacity!.toJson(),
      if (circleOpacityTransition != null)
        'circle-opacity-transition': circleOpacityTransition!.toJson(),
      if (circleTranslate != null)
        'circle-translate': circleTranslate!.toJson(),
      if (circleTranslateTransition != null)
        'circle-translate-transition': circleTranslateTransition!.toJson(),
      if (circleTranslateAnchor != null)
        'circle-translate-anchor': circleTranslateAnchor!.toJson(),
      if (circlePitchScale != null)
        'circle-pitch-scale': circlePitchScale!.toJson(),
      if (circlePitchAlignment != null)
        'circle-pitch-alignment': circlePitchAlignment!.toJson(),
      if (circleStrokeWidth != null)
        'circle-stroke-width': circleStrokeWidth!.toJson(),
      if (circleStrokeWidthTransition != null)
        'circle-stroke-width-transition': circleStrokeWidthTransition!.toJson(),
      if (circleStrokeColor != null)
        'circle-stroke-color': circleStrokeColor!.toJson(),
      if (circleStrokeColorTransition != null)
        'circle-stroke-color-transition': circleStrokeColorTransition!.toJson(),
      if (circleStrokeOpacity != null)
        'circle-stroke-opacity': circleStrokeOpacity!.toJson(),
      if (circleStrokeOpacityTransition != null)
        'circle-stroke-opacity-transition': circleStrokeOpacityTransition!
            .toJson(),
    };
    return <String, Object?>{
      'id': id,
      'type': type,
      if (metadata != null) 'metadata': encodeStyleJson(metadata),
      'source': source,
      if (sourceLayer != null) 'source-layer': sourceLayer,
      if (minZoom != null) 'minzoom': encodeStyleNumber(minZoom!),
      if (maxZoom != null) 'maxzoom': encodeStyleNumber(maxZoom!),
      if (filter != null) 'filter': filter!.toJson(),
      if (layout.isNotEmpty) 'layout': layout,
      if (paint.isNotEmpty) 'paint': paint,
    };
  }
}

/// A `heatmap` style layer. A heatmap.
///
/// Generated from the spec schemas `layer`, `layout_heatmap` and
/// `paint_heatmap`. [toJson] produces the document `addLayer` sends, so
/// anything expressible in style JSON is expressible here.
@immutable
final class HeatmapLayer extends StyleLayer {
  /// Creates a `heatmap` layer.
  const HeatmapLayer({
    required this.id,
    required this.source,
    this.metadata,
    this.sourceLayer,
    this.minZoom,
    this.maxZoom,
    this.filter,
    this.visibility,
    this.heatmapRadius,
    this.heatmapRadiusTransition,
    this.heatmapWeight,
    this.heatmapIntensity,
    this.heatmapIntensityTransition,
    this.heatmapColor,
    this.heatmapOpacity,
    this.heatmapOpacityTransition,
  });

  @override
  final String id;

  @override
  String get type => 'heatmap';

  /// Name of a source description to be used for this layer. Required for all
  /// layer types except `background`.
  ///
  /// Spec: `source`.
  final String source;

  /// Arbitrary properties useful to track with the layer, but do not influence
  /// rendering. Properties should be prefixed to avoid collisions, like
  /// 'maplibre:'.
  ///
  /// Spec: `metadata`.
  final Object? metadata;

  /// Layer to use from a vector tile source. Required for vector tile sources;
  /// prohibited for all other source types, including GeoJSON sources.
  ///
  /// Spec: `source-layer`.
  final String? sourceLayer;

  /// The minimum zoom level for the layer. At zoom levels less than the
  /// minzoom, the layer will be hidden.
  ///
  /// Spec: `minzoom`.
  final double? minZoom;

  /// The maximum zoom level for the layer. At zoom levels equal to or greater
  /// than the maxzoom, the layer will be hidden.
  ///
  /// Spec: `maxzoom`.
  final double? maxZoom;

  /// A expression specifying conditions on source features. Only features that
  /// match the filter are displayed. Zoom expressions in filters are only
  /// evaluated at integer zoom levels. The `feature-state` expression is not
  /// supported in filter expressions.
  ///
  /// Spec: `filter`.
  final Expression? filter;

  /// Whether this layer is displayed.
  ///
  /// Spec: `visibility`. Defaults to `"visible"`.
  /// A constant only — the spec allows no expression here.
  final StyleVisibility? visibility;

  /// Radius of influence of one heatmap point in pixels. Increasing the value
  /// makes the heatmap smoother, but less detailed.
  ///
  /// Spec: `heatmap-radius`, in pixels. Defaults to `30`.
  final StyleValue<double>? heatmapRadius;

  /// How `heatmap-radius` animates when it changes
  /// (`heatmap-radius-transition`).
  final StyleTransition? heatmapRadiusTransition;

  /// A measure of how much an individual point contributes to the heatmap. A
  /// value of 10 would be equivalent to having 10 points of weight 1 in the
  /// same spot. Especially useful when combined with clustering.
  ///
  /// Spec: `heatmap-weight`. Defaults to `1`.
  final StyleValue<double>? heatmapWeight;

  /// Similar to `heatmap-weight` but controls the intensity of the heatmap
  /// globally. Primarily used for adjusting the heatmap based on zoom level.
  ///
  /// Spec: `heatmap-intensity`. Defaults to `1`.
  final StyleValue<double>? heatmapIntensity;

  /// How `heatmap-intensity` animates when it changes
  /// (`heatmap-intensity-transition`).
  final StyleTransition? heatmapIntensityTransition;

  /// Defines the color of each pixel based on its density value in a heatmap.
  /// Should be an expression that uses `["heatmap-density"]` as input.
  ///
  /// Spec: `heatmap-color`. Defaults to
  /// `["interpolate",["linear"],["heatmap-density"],0,"rgba(0, 0, 255,
  /// 0)",0.1,"royalblue",0.3,"cyan",0.5,"lime",0.7,"yellow",1,"red"]`.
  final StyleValue<Color>? heatmapColor;

  /// The global opacity at which the heatmap layer will be drawn.
  ///
  /// Spec: `heatmap-opacity`. Defaults to `1`.
  final StyleValue<double>? heatmapOpacity;

  /// How `heatmap-opacity` animates when it changes
  /// (`heatmap-opacity-transition`).
  final StyleTransition? heatmapOpacityTransition;

  @override
  Map<String, Object?> toJson() {
    final layout = <String, Object?>{
      if (visibility != null) 'visibility': encodeStyleJson(visibility!),
    };
    final paint = <String, Object?>{
      if (heatmapRadius != null) 'heatmap-radius': heatmapRadius!.toJson(),
      if (heatmapRadiusTransition != null)
        'heatmap-radius-transition': heatmapRadiusTransition!.toJson(),
      if (heatmapWeight != null) 'heatmap-weight': heatmapWeight!.toJson(),
      if (heatmapIntensity != null)
        'heatmap-intensity': heatmapIntensity!.toJson(),
      if (heatmapIntensityTransition != null)
        'heatmap-intensity-transition': heatmapIntensityTransition!.toJson(),
      if (heatmapColor != null) 'heatmap-color': heatmapColor!.toJson(),
      if (heatmapOpacity != null) 'heatmap-opacity': heatmapOpacity!.toJson(),
      if (heatmapOpacityTransition != null)
        'heatmap-opacity-transition': heatmapOpacityTransition!.toJson(),
    };
    return <String, Object?>{
      'id': id,
      'type': type,
      if (metadata != null) 'metadata': encodeStyleJson(metadata),
      'source': source,
      if (sourceLayer != null) 'source-layer': sourceLayer,
      if (minZoom != null) 'minzoom': encodeStyleNumber(minZoom!),
      if (maxZoom != null) 'maxzoom': encodeStyleNumber(maxZoom!),
      if (filter != null) 'filter': filter!.toJson(),
      if (layout.isNotEmpty) 'layout': layout,
      if (paint.isNotEmpty) 'paint': paint,
    };
  }
}

/// A `fill-extrusion` style layer. An extruded (3D) polygon.
///
/// Generated from the spec schemas `layer`, `layout_fill-extrusion` and
/// `paint_fill-extrusion`. [toJson] produces the document `addLayer` sends, so
/// anything expressible in style JSON is expressible here.
@immutable
final class FillExtrusionLayer extends StyleLayer {
  /// Creates a `fill-extrusion` layer.
  const FillExtrusionLayer({
    required this.id,
    required this.source,
    this.metadata,
    this.sourceLayer,
    this.minZoom,
    this.maxZoom,
    this.filter,
    this.visibility,
    this.fillExtrusionOpacity,
    this.fillExtrusionOpacityTransition,
    this.fillExtrusionColor,
    this.fillExtrusionColorTransition,
    this.fillExtrusionTranslate,
    this.fillExtrusionTranslateTransition,
    this.fillExtrusionTranslateAnchor,
    this.fillExtrusionPattern,
    this.fillExtrusionPatternTransition,
    this.fillExtrusionHeight,
    this.fillExtrusionHeightTransition,
    this.fillExtrusionBase,
    this.fillExtrusionBaseTransition,
    this.fillExtrusionVerticalGradient,
  });

  @override
  final String id;

  @override
  String get type => 'fill-extrusion';

  /// Name of a source description to be used for this layer. Required for all
  /// layer types except `background`.
  ///
  /// Spec: `source`.
  final String source;

  /// Arbitrary properties useful to track with the layer, but do not influence
  /// rendering. Properties should be prefixed to avoid collisions, like
  /// 'maplibre:'.
  ///
  /// Spec: `metadata`.
  final Object? metadata;

  /// Layer to use from a vector tile source. Required for vector tile sources;
  /// prohibited for all other source types, including GeoJSON sources.
  ///
  /// Spec: `source-layer`.
  final String? sourceLayer;

  /// The minimum zoom level for the layer. At zoom levels less than the
  /// minzoom, the layer will be hidden.
  ///
  /// Spec: `minzoom`.
  final double? minZoom;

  /// The maximum zoom level for the layer. At zoom levels equal to or greater
  /// than the maxzoom, the layer will be hidden.
  ///
  /// Spec: `maxzoom`.
  final double? maxZoom;

  /// A expression specifying conditions on source features. Only features that
  /// match the filter are displayed. Zoom expressions in filters are only
  /// evaluated at integer zoom levels. The `feature-state` expression is not
  /// supported in filter expressions.
  ///
  /// Spec: `filter`.
  final Expression? filter;

  /// Whether this layer is displayed.
  ///
  /// Spec: `visibility`. Defaults to `"visible"`.
  /// A constant only — the spec allows no expression here.
  final StyleVisibility? visibility;

  /// The opacity of the entire fill extrusion layer. This is rendered on a
  /// per-layer, not per-feature, basis, and data-driven styling is not
  /// available.
  ///
  /// Spec: `fill-extrusion-opacity`. Defaults to `1`.
  final StyleValue<double>? fillExtrusionOpacity;

  /// How `fill-extrusion-opacity` animates when it changes
  /// (`fill-extrusion-opacity-transition`).
  final StyleTransition? fillExtrusionOpacityTransition;

  /// The base color of the extruded fill. The extrusion's surfaces will be
  /// shaded differently based on this color in combination with the root
  /// `light` settings. If this color is specified as `rgba` with an alpha
  /// component, the alpha component will be ignored; use
  /// `fill-extrusion-opacity` to set layer opacity.
  ///
  /// Spec: `fill-extrusion-color`. Defaults to `"#000000"`.
  /// Requires .
  final StyleValue<Color>? fillExtrusionColor;

  /// How `fill-extrusion-color` animates when it changes
  /// (`fill-extrusion-color-transition`).
  final StyleTransition? fillExtrusionColorTransition;

  /// The geometry's offset. Values are [x, y] where negatives indicate left and
  /// up (on the flat plane), respectively.
  ///
  /// Spec: `fill-extrusion-translate`, in pixels. Defaults to `[0,0]`.
  final StyleValue<List<double>>? fillExtrusionTranslate;

  /// How `fill-extrusion-translate` animates when it changes
  /// (`fill-extrusion-translate-transition`).
  final StyleTransition? fillExtrusionTranslateTransition;

  /// Controls the frame of reference for `fill-extrusion-translate`.
  ///
  /// Spec: `fill-extrusion-translate-anchor`. Defaults to `"map"`.
  /// Requires `fill-extrusion-translate`.
  final StyleValue<FillExtrusionTranslateAnchor>? fillExtrusionTranslateAnchor;

  /// Name of image in sprite to use for drawing images on extruded fills. For
  /// seamless patterns, image width and height must be a factor of two (2, 4,
  /// 8, ..., 512). Note that zoom-dependent expressions will be evaluated only
  /// at integer zoom levels.
  ///
  /// Spec: `fill-extrusion-pattern`.
  final StyleValue<String>? fillExtrusionPattern;

  /// How `fill-extrusion-pattern` animates when it changes
  /// (`fill-extrusion-pattern-transition`).
  final StyleTransition? fillExtrusionPatternTransition;

  /// The height with which to extrude this layer.
  ///
  /// Spec: `fill-extrusion-height`, in meters. Defaults to `0`.
  final StyleValue<double>? fillExtrusionHeight;

  /// How `fill-extrusion-height` animates when it changes
  /// (`fill-extrusion-height-transition`).
  final StyleTransition? fillExtrusionHeightTransition;

  /// The height with which to extrude the base of this layer. Must be less than
  /// or equal to `fill-extrusion-height`.
  ///
  /// Spec: `fill-extrusion-base`, in meters. Defaults to `0`.
  /// Requires `fill-extrusion-height`.
  final StyleValue<double>? fillExtrusionBase;

  /// How `fill-extrusion-base` animates when it changes
  /// (`fill-extrusion-base-transition`).
  final StyleTransition? fillExtrusionBaseTransition;

  /// Whether to apply a vertical gradient to the sides of a fill-extrusion
  /// layer. If true, sides will be shaded slightly darker farther down.
  ///
  /// Spec: `fill-extrusion-vertical-gradient`. Defaults to `true`.
  final StyleValue<bool>? fillExtrusionVerticalGradient;

  @override
  Map<String, Object?> toJson() {
    final layout = <String, Object?>{
      if (visibility != null) 'visibility': encodeStyleJson(visibility!),
    };
    final paint = <String, Object?>{
      if (fillExtrusionOpacity != null)
        'fill-extrusion-opacity': fillExtrusionOpacity!.toJson(),
      if (fillExtrusionOpacityTransition != null)
        'fill-extrusion-opacity-transition': fillExtrusionOpacityTransition!
            .toJson(),
      if (fillExtrusionColor != null)
        'fill-extrusion-color': fillExtrusionColor!.toJson(),
      if (fillExtrusionColorTransition != null)
        'fill-extrusion-color-transition': fillExtrusionColorTransition!
            .toJson(),
      if (fillExtrusionTranslate != null)
        'fill-extrusion-translate': fillExtrusionTranslate!.toJson(),
      if (fillExtrusionTranslateTransition != null)
        'fill-extrusion-translate-transition': fillExtrusionTranslateTransition!
            .toJson(),
      if (fillExtrusionTranslateAnchor != null)
        'fill-extrusion-translate-anchor': fillExtrusionTranslateAnchor!
            .toJson(),
      if (fillExtrusionPattern != null)
        'fill-extrusion-pattern': fillExtrusionPattern!.toJson(),
      if (fillExtrusionPatternTransition != null)
        'fill-extrusion-pattern-transition': fillExtrusionPatternTransition!
            .toJson(),
      if (fillExtrusionHeight != null)
        'fill-extrusion-height': fillExtrusionHeight!.toJson(),
      if (fillExtrusionHeightTransition != null)
        'fill-extrusion-height-transition': fillExtrusionHeightTransition!
            .toJson(),
      if (fillExtrusionBase != null)
        'fill-extrusion-base': fillExtrusionBase!.toJson(),
      if (fillExtrusionBaseTransition != null)
        'fill-extrusion-base-transition': fillExtrusionBaseTransition!.toJson(),
      if (fillExtrusionVerticalGradient != null)
        'fill-extrusion-vertical-gradient': fillExtrusionVerticalGradient!
            .toJson(),
    };
    return <String, Object?>{
      'id': id,
      'type': type,
      if (metadata != null) 'metadata': encodeStyleJson(metadata),
      'source': source,
      if (sourceLayer != null) 'source-layer': sourceLayer,
      if (minZoom != null) 'minzoom': encodeStyleNumber(minZoom!),
      if (maxZoom != null) 'maxzoom': encodeStyleNumber(maxZoom!),
      if (filter != null) 'filter': filter!.toJson(),
      if (layout.isNotEmpty) 'layout': layout,
      if (paint.isNotEmpty) 'paint': paint,
    };
  }
}

/// A `raster` style layer. Raster map textures such as satellite imagery.
///
/// Generated from the spec schemas `layer`, `layout_raster` and
/// `paint_raster`. [toJson] produces the document `addLayer` sends, so
/// anything expressible in style JSON is expressible here.
@immutable
final class RasterLayer extends StyleLayer {
  /// Creates a `raster` layer.
  const RasterLayer({
    required this.id,
    required this.source,
    this.metadata,
    this.sourceLayer,
    this.minZoom,
    this.maxZoom,
    this.filter,
    this.visibility,
    this.rasterOpacity,
    this.rasterOpacityTransition,
    this.rasterHueRotate,
    this.rasterHueRotateTransition,
    this.rasterBrightnessMin,
    this.rasterBrightnessMinTransition,
    this.rasterBrightnessMax,
    this.rasterBrightnessMaxTransition,
    this.rasterSaturation,
    this.rasterSaturationTransition,
    this.rasterContrast,
    this.rasterContrastTransition,
    this.rasterResampling,
    this.rasterFadeDuration,
  });

  @override
  final String id;

  @override
  String get type => 'raster';

  /// Name of a source description to be used for this layer. Required for all
  /// layer types except `background`.
  ///
  /// Spec: `source`.
  final String source;

  /// Arbitrary properties useful to track with the layer, but do not influence
  /// rendering. Properties should be prefixed to avoid collisions, like
  /// 'maplibre:'.
  ///
  /// Spec: `metadata`.
  final Object? metadata;

  /// Layer to use from a vector tile source. Required for vector tile sources;
  /// prohibited for all other source types, including GeoJSON sources.
  ///
  /// Spec: `source-layer`.
  final String? sourceLayer;

  /// The minimum zoom level for the layer. At zoom levels less than the
  /// minzoom, the layer will be hidden.
  ///
  /// Spec: `minzoom`.
  final double? minZoom;

  /// The maximum zoom level for the layer. At zoom levels equal to or greater
  /// than the maxzoom, the layer will be hidden.
  ///
  /// Spec: `maxzoom`.
  final double? maxZoom;

  /// A expression specifying conditions on source features. Only features that
  /// match the filter are displayed. Zoom expressions in filters are only
  /// evaluated at integer zoom levels. The `feature-state` expression is not
  /// supported in filter expressions.
  ///
  /// Spec: `filter`.
  final Expression? filter;

  /// Whether this layer is displayed.
  ///
  /// Spec: `visibility`. Defaults to `"visible"`.
  /// A constant only — the spec allows no expression here.
  final StyleVisibility? visibility;

  /// The opacity at which the image will be drawn.
  ///
  /// Spec: `raster-opacity`. Defaults to `1`.
  final StyleValue<double>? rasterOpacity;

  /// How `raster-opacity` animates when it changes
  /// (`raster-opacity-transition`).
  final StyleTransition? rasterOpacityTransition;

  /// Rotates hues around the color wheel.
  ///
  /// Spec: `raster-hue-rotate`, in degrees. Defaults to `0`.
  final StyleValue<double>? rasterHueRotate;

  /// How `raster-hue-rotate` animates when it changes
  /// (`raster-hue-rotate-transition`).
  final StyleTransition? rasterHueRotateTransition;

  /// Increase or reduce the brightness of the image. The value is the minimum
  /// brightness.
  ///
  /// Spec: `raster-brightness-min`. Defaults to `0`.
  final StyleValue<double>? rasterBrightnessMin;

  /// How `raster-brightness-min` animates when it changes
  /// (`raster-brightness-min-transition`).
  final StyleTransition? rasterBrightnessMinTransition;

  /// Increase or reduce the brightness of the image. The value is the maximum
  /// brightness.
  ///
  /// Spec: `raster-brightness-max`. Defaults to `1`.
  final StyleValue<double>? rasterBrightnessMax;

  /// How `raster-brightness-max` animates when it changes
  /// (`raster-brightness-max-transition`).
  final StyleTransition? rasterBrightnessMaxTransition;

  /// Increase or reduce the saturation of the image.
  ///
  /// Spec: `raster-saturation`. Defaults to `0`.
  final StyleValue<double>? rasterSaturation;

  /// How `raster-saturation` animates when it changes
  /// (`raster-saturation-transition`).
  final StyleTransition? rasterSaturationTransition;

  /// Increase or reduce the contrast of the image.
  ///
  /// Spec: `raster-contrast`. Defaults to `0`.
  final StyleValue<double>? rasterContrast;

  /// How `raster-contrast` animates when it changes
  /// (`raster-contrast-transition`).
  final StyleTransition? rasterContrastTransition;

  /// The resampling/interpolation method to use for overscaling, also known as
  /// texture magnification filter
  ///
  /// Spec: `raster-resampling`. Defaults to `"linear"`.
  final StyleValue<RasterResampling>? rasterResampling;

  /// Fade duration when a new tile is added, or when a video is started or its
  /// coordinates are updated.
  ///
  /// Spec: `raster-fade-duration`, in milliseconds. Defaults to `300`.
  final StyleValue<double>? rasterFadeDuration;

  @override
  Map<String, Object?> toJson() {
    final layout = <String, Object?>{
      if (visibility != null) 'visibility': encodeStyleJson(visibility!),
    };
    final paint = <String, Object?>{
      if (rasterOpacity != null) 'raster-opacity': rasterOpacity!.toJson(),
      if (rasterOpacityTransition != null)
        'raster-opacity-transition': rasterOpacityTransition!.toJson(),
      if (rasterHueRotate != null)
        'raster-hue-rotate': rasterHueRotate!.toJson(),
      if (rasterHueRotateTransition != null)
        'raster-hue-rotate-transition': rasterHueRotateTransition!.toJson(),
      if (rasterBrightnessMin != null)
        'raster-brightness-min': rasterBrightnessMin!.toJson(),
      if (rasterBrightnessMinTransition != null)
        'raster-brightness-min-transition': rasterBrightnessMinTransition!
            .toJson(),
      if (rasterBrightnessMax != null)
        'raster-brightness-max': rasterBrightnessMax!.toJson(),
      if (rasterBrightnessMaxTransition != null)
        'raster-brightness-max-transition': rasterBrightnessMaxTransition!
            .toJson(),
      if (rasterSaturation != null)
        'raster-saturation': rasterSaturation!.toJson(),
      if (rasterSaturationTransition != null)
        'raster-saturation-transition': rasterSaturationTransition!.toJson(),
      if (rasterContrast != null) 'raster-contrast': rasterContrast!.toJson(),
      if (rasterContrastTransition != null)
        'raster-contrast-transition': rasterContrastTransition!.toJson(),
      if (rasterResampling != null)
        'raster-resampling': rasterResampling!.toJson(),
      if (rasterFadeDuration != null)
        'raster-fade-duration': rasterFadeDuration!.toJson(),
    };
    return <String, Object?>{
      'id': id,
      'type': type,
      if (metadata != null) 'metadata': encodeStyleJson(metadata),
      'source': source,
      if (sourceLayer != null) 'source-layer': sourceLayer,
      if (minZoom != null) 'minzoom': encodeStyleNumber(minZoom!),
      if (maxZoom != null) 'maxzoom': encodeStyleNumber(maxZoom!),
      if (filter != null) 'filter': filter!.toJson(),
      if (layout.isNotEmpty) 'layout': layout,
      if (paint.isNotEmpty) 'paint': paint,
    };
  }
}

/// A `hillshade` style layer. Client-side hillshading visualization based on
/// DEM data. The implementation supports Mapbox Terrain RGB, Mapzen Terrarium
/// tiles and custom encodings.
///
/// Generated from the spec schemas `layer`, `layout_hillshade` and
/// `paint_hillshade`. [toJson] produces the document `addLayer` sends, so
/// anything expressible in style JSON is expressible here.
@immutable
final class HillshadeLayer extends StyleLayer {
  /// Creates a `hillshade` layer.
  const HillshadeLayer({
    required this.id,
    required this.source,
    this.metadata,
    this.sourceLayer,
    this.minZoom,
    this.maxZoom,
    this.filter,
    this.visibility,
    this.hillshadeIlluminationDirection,
    this.hillshadeIlluminationAltitude,
    this.hillshadeIlluminationAnchor,
    this.hillshadeExaggeration,
    this.hillshadeExaggerationTransition,
    this.hillshadeShadowColor,
    this.hillshadeShadowColorTransition,
    this.hillshadeHighlightColor,
    this.hillshadeHighlightColorTransition,
    this.hillshadeAccentColor,
    this.hillshadeAccentColorTransition,
    this.hillshadeMethod,
  });

  @override
  final String id;

  @override
  String get type => 'hillshade';

  /// Name of a source description to be used for this layer. Required for all
  /// layer types except `background`.
  ///
  /// Spec: `source`.
  final String source;

  /// Arbitrary properties useful to track with the layer, but do not influence
  /// rendering. Properties should be prefixed to avoid collisions, like
  /// 'maplibre:'.
  ///
  /// Spec: `metadata`.
  final Object? metadata;

  /// Layer to use from a vector tile source. Required for vector tile sources;
  /// prohibited for all other source types, including GeoJSON sources.
  ///
  /// Spec: `source-layer`.
  final String? sourceLayer;

  /// The minimum zoom level for the layer. At zoom levels less than the
  /// minzoom, the layer will be hidden.
  ///
  /// Spec: `minzoom`.
  final double? minZoom;

  /// The maximum zoom level for the layer. At zoom levels equal to or greater
  /// than the maxzoom, the layer will be hidden.
  ///
  /// Spec: `maxzoom`.
  final double? maxZoom;

  /// A expression specifying conditions on source features. Only features that
  /// match the filter are displayed. Zoom expressions in filters are only
  /// evaluated at integer zoom levels. The `feature-state` expression is not
  /// supported in filter expressions.
  ///
  /// Spec: `filter`.
  final Expression? filter;

  /// Whether this layer is displayed.
  ///
  /// Spec: `visibility`. Defaults to `"visible"`.
  /// A constant only — the spec allows no expression here.
  final StyleVisibility? visibility;

  /// The direction of the light source(s) used to generate the hillshading with
  /// 0 as the top of the viewport if `hillshade-illumination-anchor` is set to
  /// `viewport` and due north if `hillshade-illumination-anchor` is set to
  /// `map`. Only when `hillshade-method` is set to `multidirectional` can you
  /// specify multiple light sources.
  ///
  /// Spec: `hillshade-illumination-direction`. Defaults to `335`.
  final StyleValue<List<double>>? hillshadeIlluminationDirection;

  /// The altitude of the light source(s) used to generate the hillshading with
  /// 0 as sunset and 90 as noon. Only when `hillshade-method` is set to
  /// `multidirectional` can you specify multiple light sources.
  ///
  /// Spec: `hillshade-illumination-altitude`. Defaults to `45`.
  final StyleValue<List<double>>? hillshadeIlluminationAltitude;

  /// Direction of light source when map is rotated.
  ///
  /// Spec: `hillshade-illumination-anchor`. Defaults to `"viewport"`.
  final StyleValue<HillshadeIlluminationAnchor>? hillshadeIlluminationAnchor;

  /// Intensity of the hillshade
  ///
  /// Spec: `hillshade-exaggeration`. Defaults to `0.5`.
  final StyleValue<double>? hillshadeExaggeration;

  /// How `hillshade-exaggeration` animates when it changes
  /// (`hillshade-exaggeration-transition`).
  final StyleTransition? hillshadeExaggerationTransition;

  /// The shading color of areas that face away from the light source(s). Only
  /// when `hillshade-method` is set to `multidirectional` can you specify
  /// multiple light sources.
  ///
  /// Spec: `hillshade-shadow-color`. Defaults to `"#000000"`.
  final StyleValue<List<Color>>? hillshadeShadowColor;

  /// How `hillshade-shadow-color` animates when it changes
  /// (`hillshade-shadow-color-transition`).
  final StyleTransition? hillshadeShadowColorTransition;

  /// The shading color of areas that faces towards the light source(s). Only
  /// when `hillshade-method` is set to `multidirectional` can you specify
  /// multiple light sources.
  ///
  /// Spec: `hillshade-highlight-color`. Defaults to `"#FFFFFF"`.
  final StyleValue<List<Color>>? hillshadeHighlightColor;

  /// How `hillshade-highlight-color` animates when it changes
  /// (`hillshade-highlight-color-transition`).
  final StyleTransition? hillshadeHighlightColorTransition;

  /// The shading color used to accentuate rugged terrain like sharp cliffs and
  /// gorges.
  ///
  /// Spec: `hillshade-accent-color`. Defaults to `"#000000"`.
  final StyleValue<Color>? hillshadeAccentColor;

  /// How `hillshade-accent-color` animates when it changes
  /// (`hillshade-accent-color-transition`).
  final StyleTransition? hillshadeAccentColorTransition;

  /// The hillshade algorithm to use, one of `standard`, `basic`, `combined`,
  /// `igor`, or `multidirectional`. ![image](assets/hillshade_methods.png)
  ///
  /// Spec: `hillshade-method`. Defaults to `"standard"`.
  final StyleValue<HillshadeMethod>? hillshadeMethod;

  @override
  Map<String, Object?> toJson() {
    final layout = <String, Object?>{
      if (visibility != null) 'visibility': encodeStyleJson(visibility!),
    };
    final paint = <String, Object?>{
      if (hillshadeIlluminationDirection != null)
        'hillshade-illumination-direction': hillshadeIlluminationDirection!
            .toJson(),
      if (hillshadeIlluminationAltitude != null)
        'hillshade-illumination-altitude': hillshadeIlluminationAltitude!
            .toJson(),
      if (hillshadeIlluminationAnchor != null)
        'hillshade-illumination-anchor': hillshadeIlluminationAnchor!.toJson(),
      if (hillshadeExaggeration != null)
        'hillshade-exaggeration': hillshadeExaggeration!.toJson(),
      if (hillshadeExaggerationTransition != null)
        'hillshade-exaggeration-transition': hillshadeExaggerationTransition!
            .toJson(),
      if (hillshadeShadowColor != null)
        'hillshade-shadow-color': hillshadeShadowColor!.toJson(),
      if (hillshadeShadowColorTransition != null)
        'hillshade-shadow-color-transition': hillshadeShadowColorTransition!
            .toJson(),
      if (hillshadeHighlightColor != null)
        'hillshade-highlight-color': hillshadeHighlightColor!.toJson(),
      if (hillshadeHighlightColorTransition != null)
        'hillshade-highlight-color-transition':
            hillshadeHighlightColorTransition!.toJson(),
      if (hillshadeAccentColor != null)
        'hillshade-accent-color': hillshadeAccentColor!.toJson(),
      if (hillshadeAccentColorTransition != null)
        'hillshade-accent-color-transition': hillshadeAccentColorTransition!
            .toJson(),
      if (hillshadeMethod != null)
        'hillshade-method': hillshadeMethod!.toJson(),
    };
    return <String, Object?>{
      'id': id,
      'type': type,
      if (metadata != null) 'metadata': encodeStyleJson(metadata),
      'source': source,
      if (sourceLayer != null) 'source-layer': sourceLayer,
      if (minZoom != null) 'minzoom': encodeStyleNumber(minZoom!),
      if (maxZoom != null) 'maxzoom': encodeStyleNumber(maxZoom!),
      if (filter != null) 'filter': filter!.toJson(),
      if (layout.isNotEmpty) 'layout': layout,
      if (paint.isNotEmpty) 'paint': paint,
    };
  }
}

/// A `color-relief` style layer. Client-side elevation coloring based on DEM
/// data. The implementation supports Mapbox Terrain RGB, Mapzen Terrarium tiles
/// and custom encodings.
///
/// Generated from the spec schemas `layer`, `layout_color-relief` and
/// `paint_color-relief`. [toJson] produces the document `addLayer` sends, so
/// anything expressible in style JSON is expressible here.
@immutable
final class ColorReliefLayer extends StyleLayer {
  /// Creates a `color-relief` layer.
  const ColorReliefLayer({
    required this.id,
    required this.source,
    this.metadata,
    this.sourceLayer,
    this.minZoom,
    this.maxZoom,
    this.filter,
    this.visibility,
    this.colorReliefOpacity,
    this.colorReliefOpacityTransition,
    this.colorReliefColor,
  });

  @override
  final String id;

  @override
  String get type => 'color-relief';

  /// Name of a source description to be used for this layer. Required for all
  /// layer types except `background`.
  ///
  /// Spec: `source`.
  final String source;

  /// Arbitrary properties useful to track with the layer, but do not influence
  /// rendering. Properties should be prefixed to avoid collisions, like
  /// 'maplibre:'.
  ///
  /// Spec: `metadata`.
  final Object? metadata;

  /// Layer to use from a vector tile source. Required for vector tile sources;
  /// prohibited for all other source types, including GeoJSON sources.
  ///
  /// Spec: `source-layer`.
  final String? sourceLayer;

  /// The minimum zoom level for the layer. At zoom levels less than the
  /// minzoom, the layer will be hidden.
  ///
  /// Spec: `minzoom`.
  final double? minZoom;

  /// The maximum zoom level for the layer. At zoom levels equal to or greater
  /// than the maxzoom, the layer will be hidden.
  ///
  /// Spec: `maxzoom`.
  final double? maxZoom;

  /// A expression specifying conditions on source features. Only features that
  /// match the filter are displayed. Zoom expressions in filters are only
  /// evaluated at integer zoom levels. The `feature-state` expression is not
  /// supported in filter expressions.
  ///
  /// Spec: `filter`.
  final Expression? filter;

  /// Whether this layer is displayed.
  ///
  /// Spec: `visibility`. Defaults to `"visible"`.
  /// A constant only — the spec allows no expression here.
  final StyleVisibility? visibility;

  /// The opacity at which the color-relief will be drawn.
  ///
  /// Spec: `color-relief-opacity`. Defaults to `1`.
  final StyleValue<double>? colorReliefOpacity;

  /// How `color-relief-opacity` animates when it changes
  /// (`color-relief-opacity-transition`).
  final StyleTransition? colorReliefOpacityTransition;

  /// Defines the color of each pixel based on its elevation. Should be an
  /// expression that uses `["elevation"]` as input.
  ///
  /// Spec: `color-relief-color`.
  final StyleValue<Color>? colorReliefColor;

  @override
  Map<String, Object?> toJson() {
    final layout = <String, Object?>{
      if (visibility != null) 'visibility': encodeStyleJson(visibility!),
    };
    final paint = <String, Object?>{
      if (colorReliefOpacity != null)
        'color-relief-opacity': colorReliefOpacity!.toJson(),
      if (colorReliefOpacityTransition != null)
        'color-relief-opacity-transition': colorReliefOpacityTransition!
            .toJson(),
      if (colorReliefColor != null)
        'color-relief-color': colorReliefColor!.toJson(),
    };
    return <String, Object?>{
      'id': id,
      'type': type,
      if (metadata != null) 'metadata': encodeStyleJson(metadata),
      'source': source,
      if (sourceLayer != null) 'source-layer': sourceLayer,
      if (minZoom != null) 'minzoom': encodeStyleNumber(minZoom!),
      if (maxZoom != null) 'maxzoom': encodeStyleNumber(maxZoom!),
      if (filter != null) 'filter': filter!.toJson(),
      if (layout.isNotEmpty) 'layout': layout,
      if (paint.isNotEmpty) 'paint': paint,
    };
  }
}

/// A `background` style layer. The background color or pattern of the map.
///
/// Generated from the spec schemas `layer`, `layout_background` and
/// `paint_background`. [toJson] produces the document `addLayer` sends, so
/// anything expressible in style JSON is expressible here.
@immutable
final class BackgroundLayer extends StyleLayer {
  /// Creates a `background` layer.
  const BackgroundLayer({
    required this.id,
    this.metadata,
    this.minZoom,
    this.maxZoom,
    this.visibility,
    this.backgroundColor,
    this.backgroundColorTransition,
    this.backgroundPattern,
    this.backgroundPatternTransition,
    this.backgroundOpacity,
    this.backgroundOpacityTransition,
  });

  @override
  final String id;

  @override
  String get type => 'background';

  /// Arbitrary properties useful to track with the layer, but do not influence
  /// rendering. Properties should be prefixed to avoid collisions, like
  /// 'maplibre:'.
  ///
  /// Spec: `metadata`.
  final Object? metadata;

  /// The minimum zoom level for the layer. At zoom levels less than the
  /// minzoom, the layer will be hidden.
  ///
  /// Spec: `minzoom`.
  final double? minZoom;

  /// The maximum zoom level for the layer. At zoom levels equal to or greater
  /// than the maxzoom, the layer will be hidden.
  ///
  /// Spec: `maxzoom`.
  final double? maxZoom;

  /// Whether this layer is displayed.
  ///
  /// Spec: `visibility`. Defaults to `"visible"`.
  /// A constant only — the spec allows no expression here.
  final StyleVisibility? visibility;

  /// The color with which the background will be drawn.
  ///
  /// Spec: `background-color`. Defaults to `"#000000"`.
  /// Requires .
  final StyleValue<Color>? backgroundColor;

  /// How `background-color` animates when it changes
  /// (`background-color-transition`).
  final StyleTransition? backgroundColorTransition;

  /// Name of image in sprite to use for drawing an image background. For
  /// seamless patterns, image width and height must be a factor of two (2, 4,
  /// 8, ..., 512). Note that zoom-dependent expressions will be evaluated only
  /// at integer zoom levels.
  ///
  /// Spec: `background-pattern`.
  final StyleValue<String>? backgroundPattern;

  /// How `background-pattern` animates when it changes
  /// (`background-pattern-transition`).
  final StyleTransition? backgroundPatternTransition;

  /// The opacity at which the background will be drawn.
  ///
  /// Spec: `background-opacity`. Defaults to `1`.
  final StyleValue<double>? backgroundOpacity;

  /// How `background-opacity` animates when it changes
  /// (`background-opacity-transition`).
  final StyleTransition? backgroundOpacityTransition;

  @override
  Map<String, Object?> toJson() {
    final layout = <String, Object?>{
      if (visibility != null) 'visibility': encodeStyleJson(visibility!),
    };
    final paint = <String, Object?>{
      if (backgroundColor != null)
        'background-color': backgroundColor!.toJson(),
      if (backgroundColorTransition != null)
        'background-color-transition': backgroundColorTransition!.toJson(),
      if (backgroundPattern != null)
        'background-pattern': backgroundPattern!.toJson(),
      if (backgroundPatternTransition != null)
        'background-pattern-transition': backgroundPatternTransition!.toJson(),
      if (backgroundOpacity != null)
        'background-opacity': backgroundOpacity!.toJson(),
      if (backgroundOpacityTransition != null)
        'background-opacity-transition': backgroundOpacityTransition!.toJson(),
    };
    return <String, Object?>{
      'id': id,
      'type': type,
      if (metadata != null) 'metadata': encodeStyleJson(metadata),
      if (minZoom != null) 'minzoom': encodeStyleNumber(minZoom!),
      if (maxZoom != null) 'maxzoom': encodeStyleNumber(maxZoom!),
      if (layout.isNotEmpty) 'layout': layout,
      if (paint.isNotEmpty) 'paint': paint,
    };
  }
}
