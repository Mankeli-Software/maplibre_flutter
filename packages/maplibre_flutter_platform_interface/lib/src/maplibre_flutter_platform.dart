import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'maplibre_map_controller.dart';
import 'map_options.dart';
import 'offline_store.dart';
import 'tile_server.dart';
import 'snapshot.dart';

/// The interface every platform implementation of `maplibre_flutter` extends.
///
/// Implementations register themselves by setting [instance] from their
/// `registerWith` entrypoint. App code never touches this class directly — it
/// uses the `maplibre_flutter` package, which talks to [instance].
///
/// We extend [PlatformInterface] (not just `implements`) so a private token
/// guards against implementations that forget to call `super`, per Flutter's
/// federated-plugin guidance (CLAUDE.md §7 layer 1).
abstract class MapLibreFlutterPlatform extends PlatformInterface {
  MapLibreFlutterPlatform() : super(token: _token);

  static final Object _token = Object();

  static MapLibreFlutterPlatform? _instance;

  /// The registered implementation.
  ///
  /// Throws [UnimplementedError] until a platform package registers one; there
  /// is deliberately no default `MethodChannel` implementation (CLAUDE.md §10:
  /// no method channels on the data path).
  static MapLibreFlutterPlatform get instance {
    final i = _instance;
    if (i == null) {
      throw UnimplementedError(
        'No MapLibreFlutterPlatform registered. Did the platform package run '
        'its registerWith()?',
      );
    }
    return i;
  }

  static set instance(MapLibreFlutterPlatform value) {
    PlatformInterface.verify(value, _token);
    _instance = value;
  }

  /// Create a map and return a platform controller bound to its render handle.
  ///
  /// [style] is the initial MapLibre style document (URL, asset path, or inline
  /// JSON); it is passed separately from [options] because style is a mutable,
  /// declarative property of the widget (CLAUDE.md §3), not init-only config.
  Future<MapLibreMapPlatformController> createMap({
    required String style,
    required MapOptions options,
  }) {
    throw UnimplementedError('createMap() has not been implemented.');
  }

  /// Configures process-wide resources, before the first map exists.
  ///
  /// Returns false when the tier cannot do it, or when it is too late — see
  /// `MapLibreSettings.configure`, which is the app-facing form and carries the
  /// full explanation.
  ///
  /// Default: false. A tier that has no configurable cache must say so rather
  /// than silently accepting the call, or an app cannot tell "configured" from
  /// "ignored".
  bool configureResources({
    String? cachePath,
    int? maximumCacheBytes,
    String? apiKey,
    MapLibreTileServer? tileServer,
  }) => false;

  /// Extra HTTP request headers, scoped by URL prefix. Replace-all.
  ///
  /// Returns false when the tier cannot do it, or when a header name or value
  /// is not sendable — and then NOTHING changed. See
  /// `MapLibreSettings.setHttpHeaders` for the full contract.
  bool setHttpHeaders(Map<String, Map<String, String>> rulesByUrlPrefix) =>
      false;

  /// The cache path in force, or null on a tier that has no cache. `:memory:`
  /// means there IS no persistent cache.
  String? get cachePath => null;

  /// Downloading and managing offline regions, or null on a tier that cannot.
  ///
  /// A capability object rather than a dozen methods on this class (CLAUDE.md
  /// §3): offline is a large, self-contained surface, and a tier that has no
  /// persistent database — the web tiers today — should say so once instead of
  /// stubbing every call.
  MapLibreOfflineStore? get offlineStore => null;

  /// Renders a style to an image WITHOUT a map on screen — Apple
  /// `MLNMapSnapshotter`.
  ///
  /// Null on a renderer that cannot do it. Throws nothing: a snapshot is a
  /// best-effort product, and a caller that wanted an image is better served by
  /// "no image" than by an exception from a background render.
  Future<MapSnapshot?> takeSnapshot(MapSnapshotOptions options) async => null;
}
