import 'dart:io' show Directory, File;
import 'dart:typed_data';

/// Copies a bundled `.glb` out to a real filesystem path.
///
/// The engine opens a native path and knows nothing about Flutter's asset
/// bundle, so a bundled model has to be materialised first. Under the iOS and
/// Android sandboxes the temp directory lives inside the app container, which
/// is readable without any entitlement.
Future<String?> writeModelToTemp(String assetKey, Uint8List bytes) async {
  final file = File('${Directory.systemTemp.path}/${assetKey.split('/').last}');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// Whether [path] still exists, so a previously-written copy can be reused.
bool modelFileExists(String path) => File(path).existsSync();
