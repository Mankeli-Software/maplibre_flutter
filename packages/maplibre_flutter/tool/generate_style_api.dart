// Regenerate the typed style API with: `dart run tool/generate_style_api.dart`
//
// Per CLAUDE.md §5/§10 the generator is a Dart script in `tool/` and its output
// is committed and never hand-edited. Design notes: docs/typed-style-api.md.
//
// The source of truth is the machine-readable MapLibre Style Spec vendored in
// our own submodule, so the generated API tracks the pinned MBGL_CORE_VERSION
// automatically and a core bump that changes the spec shows up as a diff (CI
// checks that, the same way it checks ffigen). mbgl generates its own C++ layer
// classes from this very file (`scripts/generate-style-code.mjs`), so this
// follows the engine's own practice.
//
// Coverage is the WHOLE spec, discovered from it rather than allowlisted: every
// layer type in `layer.type.values`, every `source_*` schema, every
// `expression_name` operator. A layer type added by a future spec therefore
// generates itself, and CI's regen diff makes that visible. The raw
// `addLayerJson` / `addSourceJson` methods stay public anyway, as the hatch for
// anything the spec does not describe.
import 'dart:convert';
import 'dart:io';

/// The spec, vendored as part of the mbgl-core submodule.
const _specPath =
    '../maplibre_flutter_core/third_party/maplibre-native/'
    'scripts/style-spec-reference/v8.json';

const _outDir = 'lib/src/style/generated';

/// Spec keys whose mechanical camelCase reads badly in Dart.
const _identOverrides = <String, String>{
  'minzoom': 'minZoom',
  'maxzoom': 'maxZoom',
};

/// Spec type names whose mechanical PascalCase reads badly as a Dart class.
const _typeNameOverrides = <String, String>{'geojson': 'GeoJson'};

/// Layer types that draw no source features, so `source`, `source-layer` and
/// `filter` are meaningless on them.
const _sourcelessLayerTypes = <String>{'background'};

/// `visibility` would generate `Visibility`, which collides with the Flutter
/// widget of that name in any file that imports both.
const _enumNameOverrides = <String, String>{'visibility': 'StyleVisibility'};

/// Expression operators whose spec name cannot be a Dart method name — the
/// symbolic ones, Dart reserved words, and `to-string` (which would clash with
/// `Object.toString`). Everything else is the mechanical camelCase of the spec
/// name, so the JSON operator stays recognisable at the call site.
const _exprNameOverrides = <String, String>{
  '!': 'not',
  '!=': 'notEquals',
  '==': 'equals',
  '<': 'lessThan',
  '<=': 'lessThanOrEqual',
  '>': 'greaterThan',
  '>=': 'greaterThanOrEqual',
  '+': 'sum',
  '-': 'subtract',
  '*': 'product',
  '/': 'divide',
  '%': 'modulo',
  '^': 'power',
  'case': 'caseOf',
  'in': 'isIn',
  'var': 'variable',
  'to-string': 'toStringOp',
};

/// How many positional arguments the generated expression builders take. The
/// spec carries no arity information for expressions, so every builder is
/// uniformly variadic up to this many arguments; longer arrays (a `step` with
/// many stops, say) go through `Expr.raw`. Passing more is a compile error, not
/// a silent truncation.
const _exprArity = 10;

/// Reserved words that cannot be used as Dart identifiers.
const _reservedWords = <String>{
  'assert',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
};

void main(List<String> args) {
  final specFile = File(_specPath);
  if (!specFile.existsSync()) {
    stderr.writeln(
      'Style spec not found at $_specPath.\n'
      'It is vendored in the mbgl-core submodule — run\n'
      '  git submodule update --init --recursive\n'
      'and re-run this from packages/maplibre_flutter.',
    );
    exitCode = 1;
    return;
  }

  final spec = jsonDecode(specFile.readAsStringSync()) as Map<String, Object?>;
  final generator = _Generator(spec);
  final files = generator.generate();

  Directory(_outDir).createSync(recursive: true);
  for (final entry in files.entries) {
    File('$_outDir/${entry.key}').writeAsStringSync(entry.value);
    stdout.writeln('wrote $_outDir/${entry.key}');
  }

  // Format the output so the committed files are byte-stable and the repo's
  // `melos run format` gate passes without a manual step.
  final fmt = Process.runSync('dart', ['format', _outDir]);
  if (fmt.exitCode != 0) {
    stderr.writeln(fmt.stderr);
    exitCode = fmt.exitCode;
  }
}

// ---------------------------------------------------------------------------

/// One layout or paint property from the spec.
class _Prop {
  _Prop(this.specKey, this.def, {required this.isPaint});

  /// The spec key, e.g. `circle-stroke-width`.
  final String specKey;
  final Map<String, Object?> def;

  /// Paint properties can carry a `*-transition`; layout ones cannot.
  final bool isPaint;

  String get specType => def['type'] as String;

  /// `property-type: constant` means the engine takes no expression here, so
  /// the generated field is the plain Dart type instead of a [StyleValue].
  bool get isConstantOnly => def['property-type'] == 'constant';

  bool get hasTransition => def['transition'] == true;

  String get dartName => _ident(specKey);
}

class _Generator {
  _Generator(this.spec);

  final Map<String, Object?> spec;

  /// Enum type name -> spec values, collected while walking properties so only
  /// enums the generated layers actually reference are emitted.
  final Map<String, Map<String, Object?>> _enums = {};

  /// Enum type name -> the spec property it came from, for doc comments.
  final Map<String, String> _enumOrigin = {};

  Map<String, String> generate() {
    final version = spec[r'$version'];
    final header =
        '// GENERATED CODE - DO NOT MODIFY BY HAND\n'
        '//\n'
        '// Generated from the MapLibre Style Spec (v$version) vendored at\n'
        '// $_specPath\n'
        '// by tool/generate_style_api.dart. Run that to regenerate.\n'
        '\n';

    // Layers first: it populates the enum registry.
    final layers = _layersFile();
    final sources = _sourcesFile();
    final enums = _enumsFile();
    final transition = _transitionFile();
    final expressions = _expressionsFile();

    return {
      'style_enums.g.dart': header + enums,
      'style_transition.g.dart': header + transition,
      'style_expressions.g.dart': header + expressions,
      'style_layers.g.dart': header + layers,
      'style_sources.g.dart': header + sources,
    };
  }

  // --- layers ---------------------------------------------------------------

  String _layersFile() {
    final body = StringBuffer();
    final layerType = _map(spec['layer']!);
    final typeValues = _map(_map(layerType['type']!)['values']!);

    // Spec order, which jsonDecode preserves — so the committed output mirrors
    // the spec's own ordering instead of an arbitrary one.
    for (final type in typeValues.keys) {
      body.write(
        _layerClass(
          type,
          doc: _map(typeValues[type]!)['doc'] as String?,
          layerSchema: layerType,
        ),
      );
    }

    return _imports(body.toString(), self: 'style_layers.g.dart') +
        body.toString();
  }

  String _layerClass(
    String type, {
    required String? doc,
    required Map<String, Object?> layerSchema,
  }) {
    final className = '${_typeName(type)}Layer';
    final layout = _props('layout_$type', isPaint: false);
    final paint = _props('paint_$type', isPaint: true);

    final needsSource = !_sourcelessLayerTypes.contains(type);

    final out = StringBuffer();
    out.writeln(
      _doc([
        'A `$type` style layer.${doc == null ? '' : ' $doc'}',
        '',
        'Generated from the spec schemas `layer`, `layout_$type` and',
        '`paint_$type`. [toJson] produces the document `addLayer` sends, so',
        'anything expressible in style JSON is expressible here.',
      ]),
    );
    out.writeln('@immutable');
    out.writeln('final class $className extends StyleLayer {');

    // Constructor.
    out.writeln('  /// Creates a `$type` layer.');
    out.writeln('  const $className({');
    out.writeln('    required this.id,');
    if (needsSource) out.writeln('    required this.source,');
    out.writeln('    this.metadata,');
    if (needsSource) out.writeln('    this.sourceLayer,');
    out.writeln('    this.minZoom,');
    out.writeln('    this.maxZoom,');
    if (needsSource) out.writeln('    this.filter,');
    for (final prop in [...layout, ...paint]) {
      out.writeln('    this.${prop.dartName},');
      if (prop.hasTransition) {
        out.writeln('    this.${prop.dartName}Transition,');
      }
    }
    out.writeln('  });');
    out.writeln();

    // Common layer fields, in spec order.
    out.writeln('  @override');
    out.writeln('  final String id;');
    out.writeln();
    out.writeln('  @override');
    out.writeln("  String get type => '$type';");
    out.writeln();
    if (needsSource) {
      out.writeln(_docField(layerSchema['source'], 'source', indent: '  '));
      out.writeln('  final String source;');
      out.writeln();
    }
    out.writeln(_docField(layerSchema['metadata'], 'metadata', indent: '  '));
    out.writeln('  final Object? metadata;');
    out.writeln();
    if (needsSource) {
      out.writeln(
        _docField(layerSchema['source-layer'], 'source-layer', indent: '  '),
      );
      out.writeln('  final String? sourceLayer;');
      out.writeln();
    }
    out.writeln(_docField(layerSchema['minzoom'], 'minzoom', indent: '  '));
    out.writeln('  final double? minZoom;');
    out.writeln();
    out.writeln(_docField(layerSchema['maxzoom'], 'maxzoom', indent: '  '));
    out.writeln('  final double? maxZoom;');
    out.writeln();
    if (needsSource) {
      out.writeln(_docField(layerSchema['filter'], 'filter', indent: '  '));
      out.writeln('  final Expression? filter;');
      out.writeln();
    }

    for (final prop in [...layout, ...paint]) {
      out.writeln(_propField(prop));
    }

    // toJson.
    out.writeln('  @override');
    out.writeln('  Map<String, Object?> toJson() {');
    out.writeln('    final layout = <String, Object?>{');
    for (final prop in layout) {
      out.write(_propEntry(prop, indent: '      '));
    }
    out.writeln('    };');
    out.writeln('    final paint = <String, Object?>{');
    for (final prop in paint) {
      out.write(_propEntry(prop, indent: '      '));
    }
    out.writeln('    };');
    out.writeln('    return <String, Object?>{');
    out.writeln("      'id': id,");
    out.writeln("      'type': type,");
    out.writeln(
      "      if (metadata != null) 'metadata': encodeStyleJson(metadata),",
    );
    if (needsSource) out.writeln("      'source': source,");
    if (needsSource) {
      out.writeln(
        "      if (sourceLayer != null) 'source-layer': sourceLayer,",
      );
    }
    out.writeln(
      "      if (minZoom != null) 'minzoom': encodeStyleNumber(minZoom!),",
    );
    out.writeln(
      "      if (maxZoom != null) 'maxzoom': encodeStyleNumber(maxZoom!),",
    );
    if (needsSource) {
      out.writeln("      if (filter != null) 'filter': filter!.toJson(),");
    }
    out.writeln("      if (layout.isNotEmpty) 'layout': layout,");
    out.writeln("      if (paint.isNotEmpty) 'paint': paint,");
    out.writeln('    };');
    out.writeln('  }');
    out.writeln('}');
    out.writeln();
    return out.toString();
  }

  List<_Prop> _props(String schemaKey, {required bool isPaint}) {
    final schema = spec[schemaKey];
    if (schema == null) return const [];
    return [
      for (final entry in _map(schema).entries)
        _Prop(entry.key, _map(entry.value!), isPaint: isPaint),
    ];
  }

  String _propField(_Prop prop) {
    final out = StringBuffer();
    out.writeln(_docProp(prop));
    out.writeln('  final ${_fieldType(prop)} ${prop.dartName};');
    out.writeln();
    if (prop.hasTransition) {
      out.writeln(
        _doc([
          'How `${prop.specKey}` animates when it changes',
          '(`${prop.specKey}-transition`).',
        ], indent: '  '),
      );
      out.writeln('  final StyleTransition? ${prop.dartName}Transition;');
      out.writeln();
    }
    return out.toString();
  }

  String _propEntry(_Prop prop, {required String indent}) {
    final name = prop.dartName;
    final value = prop.isConstantOnly
        ? 'encodeStyleJson($name!)'
        : '$name!.toJson()';
    final out = StringBuffer()
      ..writeln("${indent}if ($name != null) '${prop.specKey}': $value,");
    if (prop.hasTransition) {
      out.writeln(
        "${indent}if (${name}Transition != null) "
        "'${prop.specKey}-transition': ${name}Transition!.toJson(),",
      );
    }
    return out.toString();
  }

  /// The Dart type of a property field, including nullability.
  ///
  /// Constant-only properties (`property-type: constant`) get their plain type;
  /// everything the spec allows a zoom or data expression on is wrapped in
  /// [StyleValue], which an [Expression] also satisfies.
  String _fieldType(_Prop prop) {
    final inner = _valueType(prop.specKey, prop.def);
    return prop.isConstantOnly ? '$inner?' : 'StyleValue<$inner>?';
  }

  String _valueType(
    String specKey,
    Map<String, Object?> def, {
    String? enumPrefix,
  }) {
    switch (def['type']) {
      case 'number':
        return 'double';
      case 'boolean':
        return 'bool';
      case 'string':
        return 'String';
      case 'color':
        return 'Color';
      case 'enum':
        return _registerEnum(specKey, def, prefix: enumPrefix);
      // A colour ramp / multi-value numeric (hillshade's per-illumination
      // arrays, color-relief's ramp): a list of the scalar type.
      case 'colorArray':
        return 'List<Color>';
      case 'numberArray':
        return 'List<double>';
      // CSS-style padding: 1 to 4 numbers.
      case 'padding':
        return 'List<double>';
      // `text-variable-anchor-offset`: alternating anchor name and [x, y]
      // offset, so the element type genuinely varies. Pass an expression, or a
      // literal list like ['top', [0, 1], 'left', [1, 0]].
      case 'variableAnchorOffsetCollection':
        return 'List<Object>';
      case 'array':
        final value = def['value'];
        if (value is String) {
          // An array OF enums carries the enum's `values` on the property
          // itself, so hand the whole def down rather than a synthetic one.
          final element = value == 'enum'
              ? _registerEnum(specKey, def, prefix: enumPrefix)
              : _valueType(specKey, {'type': value}, enumPrefix: enumPrefix);
          return 'List<$element>';
        }
        if (value is Map) {
          // A nested array schema (a source's `coordinates`: pairs of numbers).
          return 'List<${_valueType(specKey, _map(value), enumPrefix: enumPrefix)}>';
        }
        throw UnsupportedError('array of $value ($specKey) not supported');
      // A text label (which can also be a `format` expression) and an image
      // name resolved against the style's sprite: both are strings to us.
      case 'formatted':
      case 'resolvedImage':
        return 'String';
      // A source's `promoteId` is either a property name or a per-source-layer
      // map of them (spec schema `promoteId`: `{"*": {"type": "string"}}`), so
      // there is no single Dart type narrower than this.
      case 'promoteId':
      case '*':
        return 'Object';
      default:
        throw UnsupportedError(
          'spec type "${def['type']}" ($specKey) not supported by the '
          'generator — add a mapping in _valueType',
        );
    }
  }

  /// Registers the enum a property's values describe and returns its Dart name.
  ///
  /// Layer property names already carry the layer in them (`circle-pitch-scale`),
  /// so they need no prefix; source properties do not (`scheme` exists on both
  /// `raster` and `vector`, and `encoding` means different things on `vector` and
  /// `raster-dem`), so sources pass their own type as [prefix].
  String _registerEnum(
    String specKey,
    Map<String, Object?> def, {
    String? prefix,
  }) {
    final name =
        _enumNameOverrides[specKey] ??
        '${prefix == null ? '' : _typeName(prefix)}${_pascal(specKey)}';
    final values = _map(def['values']!);
    final existing = _enums[name];
    // The same property on several layer types (every layer has `visibility`)
    // shares one enum; genuinely different values under one name is a bug.
    if (existing != null && !_sameKeys(existing, values)) {
      throw StateError(
        'enum name collision on $name (from $specKey) — values differ',
      );
    }
    _enums[name] = values;
    _enumOrigin[name] = specKey;
    return name;
  }

  // --- sources --------------------------------------------------------------

  String _sourcesFile() {
    final body = StringBuffer();
    for (final entry in spec.entries) {
      if (!entry.key.startsWith('source_')) continue;
      body.write(_sourceClass(entry.key, _map(entry.value!)));
    }
    return _imports(body.toString(), self: 'style_sources.g.dart') +
        body.toString();
  }

  String _sourceClass(String schemaKey, Map<String, Object?> schema) {
    // The `type` string in a style document is NOT the schema key: the schema
    // `source_raster_dem` describes `"type": "raster-dem"`. Take it from the
    // schema's own single-valued `type` enum.
    final type = _map(_map(schema['type']!)['values']!).keys.single;
    final className = '${_typeName(type)}Source';
    // `type` is the discriminator, emitted from the getter rather than a field.
    // `*` is the spec's wildcard for "any other key" (raster/vector sources
    // allow extra TileJSON fields); it cannot be a Dart field, and the raw
    // `addSourceJson` hatch covers anyone who needs it.
    final props = schema.entries
        .where((e) => e.key != 'type' && e.key != '*')
        .toList();

    final out = StringBuffer();
    out.writeln(
      _doc([
        'A `$type` style source.',
        '',
        'Generated from the spec schema `$schemaKey`. Add one with',
        '`controller.layers.addSource(id, source)`.',
      ]),
    );
    out.writeln('@immutable');
    out.writeln('final class $className extends StyleSource {');
    out.writeln('  /// Creates a `$type` source.');
    out.writeln('  const $className({');
    for (final entry in props) {
      final def = _map(entry.value!);
      final required = def['required'] == true;
      out.writeln(
        '    ${required ? 'required ' : ''}this.${_ident(entry.key)},',
      );
    }
    out.writeln('  });');
    out.writeln();
    out.writeln('  @override');
    out.writeln("  String get type => '$type';");
    out.writeln();
    for (final entry in props) {
      final def = _map(entry.value!);
      final required = def['required'] == true;
      final inner = _valueType(entry.key, def, enumPrefix: type);
      out.writeln(_docField(entry.value, entry.key, indent: '  '));
      out.writeln('  final $inner${required ? '' : '?'} ${_ident(entry.key)};');
      out.writeln();
    }
    out.writeln('  @override');
    out.writeln('  Map<String, Object?> toJson() => <String, Object?>{');
    out.writeln("        'type': type,");
    for (final entry in props) {
      final def = _map(entry.value!);
      final required = def['required'] == true;
      final name = _ident(entry.key);
      if (required) {
        out.writeln("        '${entry.key}': encodeStyleJson($name),");
      } else {
        out.writeln(
          "        if ($name != null) '${entry.key}': encodeStyleJson($name),",
        );
      }
    }
    out.writeln('      };');
    out.writeln('}');
    out.writeln();
    return out.toString();
  }

  // --- enums ----------------------------------------------------------------

  String _enumsFile() {
    if (_enums.isEmpty) {
      throw StateError('no enums collected — generate layers first');
    }
    final body = StringBuffer();
    final names = _enums.keys.toList()..sort();
    for (final name in names) {
      final specKey = _enumOrigin[name]!;
      body.writeln(
        _doc([
          'The values of `$specKey`.',
          '',
          'Generated from the spec; [jsonValue] is what it serialises to.',
        ]),
      );
      body.writeln('enum $name implements StyleEnum {');
      final values = _enums[name]!;
      var index = 0;
      for (final entry in values.entries) {
        final def = _map(entry.value ?? const <String, Object?>{});
        final doc = def['doc'] as String?;
        if (doc != null) body.writeln(_doc([doc], indent: '  '));
        final terminator = ++index == values.length ? ';' : ',';
        body.writeln("  ${_ident(entry.key)}('${entry.key}')$terminator");
      }
      body.writeln();
      body.writeln('  const $name(this.jsonValue);');
      body.writeln();
      body.writeln('  /// The spec string this value serialises to.');
      body.writeln('  @override');
      body.writeln('  final String jsonValue;');
      body.writeln('}');
      body.writeln();
    }
    return _imports(body.toString(), self: 'style_enums.g.dart') +
        body.toString();
  }

  // --- transition -----------------------------------------------------------

  String _transitionFile() {
    final schema = _map(spec['transition']!);
    final body = StringBuffer();
    body.writeln(
      _doc([
        'How a paint property animates when it changes (`*-transition`).',
        '',
        'Generated from the spec schema `transition`.',
      ]),
    );
    body.writeln('@immutable');
    body.writeln('final class StyleTransition implements StyleJson {');
    body.writeln('  /// Creates a transition; omitted fields keep the');
    body.writeln('  /// engine default.');
    body.writeln('  const StyleTransition({');
    for (final key in schema.keys) {
      body.writeln('    this.${_ident(key)},');
    }
    body.writeln('  });');
    body.writeln();
    for (final entry in schema.entries) {
      body.writeln(_docField(entry.value, entry.key, indent: '  '));
      body.writeln('  final double? ${_ident(entry.key)};');
      body.writeln();
    }
    body.writeln('  @override');
    body.writeln('  Map<String, Object?> toJson() => <String, Object?>{');
    for (final key in schema.keys) {
      final name = _ident(key);
      body.writeln(
        "        if ($name != null) '$key': encodeStyleNumber($name!),",
      );
    }
    body.writeln('      };');
    body.writeln('}');
    body.writeln();
    return _imports(body.toString(), self: 'style_transition.g.dart') +
        body.toString();
  }

  // --- expressions ----------------------------------------------------------

  String _expressionsFile() {
    final names = _map(_map(spec['expression_name']!)['values']!);
    final body = StringBuffer();

    body.writeln(
      _doc([
        'Builders for MapLibre Style Spec expressions, one per operator.',
        '',
        'An [Expression] is assignable to every style property that accepts',
        'one, so these compose directly:',
        '',
        '```dart',
        "circleRadius: Expr.step(Expr.get('point_count'), 18, 100, 24),",
        '```',
        '',
        'The spec carries no arity information for expressions, so every',
        'builder takes up to $_exprArity arguments and drops the ones you omit.',
        'For a longer array — a `step` with many stops, say — use [Expr.raw],',
        'which is also the escape hatch for anything here that is missing.',
      ]),
    );
    body.writeln('abstract final class Expr {');
    body.writeln(
      _doc([
        'A raw expression array: `Expr.raw([\'get\', \'name\'])`.',
        '',
        'Nested expressions, colours and enums inside [parts] are encoded on',
        'the way out, so they can be mixed with plain literals.',
      ], indent: '  '),
    );
    body.writeln(
      '  static Expression raw(List<Object?> parts) => Expression(parts);',
    );
    body.writeln();

    final used = <String, String>{};
    for (final entry in names.entries) {
      final op = entry.key;
      final def = _map(entry.value ?? const <String, Object?>{});
      final name = _exprNameOverrides[op] ?? _ident(op);
      if (_reservedWords.contains(name)) {
        throw StateError(
          'expression "$op" maps to reserved word "$name" — add an override',
        );
      }
      final clash = used[name];
      if (clash != null) {
        throw StateError('expressions "$clash" and "$op" both map to "$name"');
      }
      used[name] = op;

      final doc = <String>[
        'The `$op` expression.',
        if (def['doc'] != null) '',
        if (def['doc'] != null) def['doc']! as String,
      ];
      body.writeln(_doc(doc, indent: '  '));
      body.writeln('  static Expression $name([');
      for (var i = 0; i < _exprArity; i++) {
        body.writeln('    Object? a$i = _unset,');
      }
      body.writeln('  ]) => Expression(');
      body.writeln("        _parts('$op', [");
      for (var i = 0; i < _exprArity; i++) {
        body.writeln('          a$i,');
      }
      body.writeln('        ]),');
      body.writeln('      );');
      body.writeln();
    }
    body.writeln('}');
    body.writeln();
    body.writeln('/// Sentinel for an argument the caller did not pass —');
    body.writeln(
      '/// distinct from an explicit `null`, which is meaningful in',
    );
    body.writeln('/// expressions such as `["literal", null]`.');
    body.writeln('class _Unset {');
    body.writeln('  const _Unset();');
    body.writeln('}');
    body.writeln();
    body.writeln('const _unset = _Unset();');
    body.writeln();
    body.writeln('/// The operator followed by the arguments actually passed.');
    body.writeln('List<Object?> _parts(String op, List<Object?> args) {');
    body.writeln('  final parts = <Object?>[op];');
    body.writeln('  for (final arg in args) {');
    body.writeln('    if (identical(arg, _unset)) break;');
    body.writeln('    parts.add(arg);');
    body.writeln('  }');
    body.writeln('  return parts;');
    body.writeln('}');

    return _imports(body.toString(), self: 'style_expressions.g.dart') +
        body.toString();
  }

  // --- shared ---------------------------------------------------------------

  /// Only the imports a file actually needs — an unused import is an analyzer
  /// warning, and `melos run analyze` treats those as failures.
  String _imports(String body, {required String self}) {
    bool uses(String token) =>
        RegExp('(?<![A-Za-z0-9_])$token(?![A-Za-z0-9_])').hasMatch(body);

    final imports = <String>[];
    if (uses('Color')) imports.add("import 'dart:ui' show Color;");
    if (uses('immutable')) {
      imports.add("import 'package:flutter/foundation.dart' show immutable;");
    }
    final relative = <String>[];
    if (uses('encodeStyleJson') || uses('encodeStyleNumber')) {
      relative.add("import '../style_encoding.dart';");
    }
    if (uses('StyleLayer') || uses('StyleSource')) {
      relative.add("import '../style_layer.dart';");
    }
    if (uses('StyleValue') ||
        uses('Expression') ||
        uses('StyleEnum') ||
        uses('StyleJson')) {
      relative.add("import '../style_value.dart';");
    }
    // Name-driven, not file-driven: layers AND sources both reference generated
    // enums, and only layers have transitions.
    if (_enums.keys.any(uses)) relative.add("import 'style_enums.g.dart';");
    if (uses('StyleTransition')) {
      relative.add("import 'style_transition.g.dart';");
    }
    // A file declaring these must not import itself.
    relative.remove("import '$self';");
    relative.sort();
    return [
      if (imports.isNotEmpty) ...imports,
      if (imports.isNotEmpty && relative.isNotEmpty) '',
      ...relative,
      '',
    ].join('\n');
  }

  /// A dartdoc block from the spec's own prose, plus the facts a caller needs
  /// (spec key, default, units, whether an expression is allowed).
  String _docProp(_Prop prop) {
    final def = prop.def;
    final lines = <String>[
      if (def['doc'] != null) def['doc']! as String,
      if (def['doc'] != null) '',
      'Spec: `${prop.specKey}`'
          '${def['units'] != null ? ', in ${def['units']}' : ''}'
          '${def['default'] != null ? '. Defaults to `${jsonEncode(def['default'])}`' : ''}.',
      if (prop.isConstantOnly)
        'A constant only — the spec allows no expression here.',
      if (def['requires'] != null)
        'Requires ${(def['requires']! as List).whereType<String>().map((r) => '`$r`').join(', ')}.',
    ];
    return _doc(lines, indent: '  ');
  }

  String _docField(Object? def, String specKey, {required String indent}) {
    final map = def is Map<String, Object?> ? def : const <String, Object?>{};
    return _doc([
      if (map['doc'] != null) map['doc']! as String,
      if (map['doc'] != null) '',
      'Spec: `$specKey`'
          '${map['units'] != null ? ', in ${map['units']}' : ''}'
          '${map['default'] != null ? '. Defaults to `${jsonEncode(map['default'])}`' : ''}.',
    ], indent: indent);
  }

  String _doc(List<String> lines, {String indent = ''}) {
    final out = <String>[];
    for (final line in lines) {
      for (final part in line.split('\n')) {
        // Hard-wrap so the committed output stays inside the line limit; blank
        // lines are preserved as dartdoc paragraph breaks.
        if (part.trim().isEmpty) {
          out.add('$indent///');
          continue;
        }
        out.addAll(
          _wrap(
            part.trim(),
            80 - indent.length - 4,
          ).map((w) => '$indent/// $w'),
        );
      }
    }
    return out.join('\n');
  }

  List<String> _wrap(String text, int width) {
    final words = text.split(RegExp(r'\s+'));
    final lines = <String>[];
    var current = '';
    for (final word in words) {
      if (current.isEmpty) {
        current = word;
      } else if (current.length + 1 + word.length <= width) {
        current = '$current $word';
      } else {
        lines.add(current);
        current = word;
      }
    }
    if (current.isNotEmpty) lines.add(current);
    return lines;
  }

  static Map<String, Object?> _map(Object value) =>
      (value as Map).cast<String, Object?>();

  static bool _sameKeys(Map<String, Object?> a, Map<String, Object?> b) =>
      a.length == b.length && a.keys.every(b.containsKey);
}

/// A spec key as a Dart identifier: `circle-stroke-width` -> `circleStrokeWidth`.
String _ident(String specKey) {
  final override = _identOverrides[specKey];
  if (override != null) return override;
  final camel = _camel(specKey);
  return _reservedWords.contains(camel) ? '${camel}Value' : camel;
}

String _camel(String specKey) {
  final parts = specKey.split(RegExp(r'[-_ ]'));
  return [
    parts.first,
    ...parts
        .skip(1)
        .map((p) => p.isEmpty ? p : p[0].toUpperCase() + p.substring(1)),
  ].join();
}

/// A spec layer/source type as a Dart class-name prefix.
String _typeName(String specType) =>
    _typeNameOverrides[specType] ?? _pascal(specType);

String _pascal(String specKey) {
  final camel = _camel(specKey);
  return camel.isEmpty ? camel : camel[0].toUpperCase() + camel.substring(1);
}
