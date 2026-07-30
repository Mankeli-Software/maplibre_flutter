import 'style_value.dart';

/// A typed style layer, added with `controller.layers.addLayer`.
///
/// Concrete layers are generated from the MapLibre Style Spec vendored in this
/// repo (see `tool/generate_style_api.dart`); [toJson] produces exactly the
/// document `addLayerJson` accepts, so the typed API adds no new transport.
///
/// Extend this for a layer type the generator does not cover yet, rather than
/// hand-rolling the JSON at the call site.
abstract class StyleLayer implements StyleJson {
  /// Const-constructible so generated layers can be `const`.
  const StyleLayer();

  /// The layer's unique id in the style.
  String get id;

  /// The spec layer type, e.g. `circle`.
  String get type;

  @override
  Map<String, Object?> toJson();
}

/// A typed style source, added with `controller.layers.addSource`.
///
/// Sources are keyed by id in the style, so the id is passed to `addSource`
/// rather than carried here — matching the spec, where `sources` is a map.
abstract class StyleSource implements StyleJson {
  /// Const-constructible so generated sources can be `const`.
  const StyleSource();

  /// The spec source type, e.g. `geojson`.
  String get type;

  @override
  Map<String, Object?> toJson();
}
