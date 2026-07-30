/// The typed MapLibre Style Spec API.
///
/// Most of this is generated from the spec vendored in the mbgl-core submodule
/// — see `tool/generate_style_api.dart` and docs/typed-style-api.md. The
/// hand-written part is the small runtime the generated code sits on:
/// [StyleValue], [Expression], the layer/source base classes and [GeoJsonData].
///
/// Coverage today is the `circle` layer and the `geojson` source; the raw
/// `addLayerJson` / `addSourceJson` methods remain the escape hatch for
/// everything else.
library;

export 'generated/style_enums.g.dart';
export 'generated/style_expressions.g.dart';
export 'generated/style_layers.g.dart';
export 'generated/style_sources.g.dart';
export 'generated/style_transition.g.dart';
export 'geojson_data.dart';
export 'style_layer.dart';
export 'style_value.dart';
