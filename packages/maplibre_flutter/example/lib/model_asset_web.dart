import 'dart:typed_data';

/// Web has no filesystem, so a bundled `.glb` cannot be materialised as a path.
///
/// [MapLibreModel.assetPath] is documented as a real file path — the engine
/// reads it natively — and the WASM web tier does not compile the glTF reader
/// or the model layer at all. Returning null lets the caller skip the 3D
/// scenario and say why, rather than failing with a path that could never work.
///
/// Giving web models a route needs a bytes-based model API plus the model
/// sources in the Emscripten build; both are recorded as deferred in
/// docs/decision-log.md.
Future<String?> writeModelToTemp(String assetKey, Uint8List bytes) async =>
    null;

bool modelFileExists(String path) => false;
