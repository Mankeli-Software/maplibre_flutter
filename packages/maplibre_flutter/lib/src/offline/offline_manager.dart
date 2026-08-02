import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

import 'offline_region.dart';

/// Downloads maps for use without a network, and manages what has been
/// downloaded.
///
/// Named after Android's `OfflineManager` rather than Apple's
/// `MLNOfflineStorage`: "storage" reads as the ambient cache, which is a
/// sibling concern that happens to live in the same class on Apple — and that
/// is exactly what makes `MLNOfflineStorage` confusing.
///
/// **Process-wide, not per-map**, and there is no map here on purpose: a region
/// is rows in the cache database, so it exists independently of any map, and
/// downloading one benefits every map afterwards.
///
/// ```dart
/// final region = await MapLibreOfflineManager.instance.createRegion(
///   MapLibreTilePyramidRegionDefinition(
///     styleUrl: 'https://demotiles.maplibre.org/style.json',
///     bounds: LatLngBounds(
///       southwest: const LatLng(51.0, -0.6),
///       northeast: const LatLng(51.8, 0.4),
///     ),
///     minZoom: 0,
///     maxZoom: 12,
///     pixelRatio: MediaQuery.devicePixelRatioOf(context),
///   ),
///   metadata: utf8.encode('London'),
///   startDownload: true,
/// );
/// region.statusChanges.listen((s) => setState(() => _progress = s.progress));
/// ```
///
/// **Call [MapLibreSettings.configure] with a real cache path first.** Regions
/// go into that database, and mbgl's default is `:memory:` — a region written
/// there dies with the process, which looks exactly like a download that did
/// nothing.
///
/// Two behaviours worth knowing before building a UI on this, both upstream's
/// and neither ours to change:
///
///  * **A region downloads nothing until it is resumed.** [createRegion]
///    returns an inactive region unless `startDownload: true`.
///  * **A byte-accurate progress bar is impossible.** See
///    [MapLibreOfflineRegionStatus.progress].
class MapLibreOfflineManager {
  MapLibreOfflineManager._();

  /// The manager. There is one, for the reason in the class doc.
  static final MapLibreOfflineManager instance = MapLibreOfflineManager._();

  /// Whether this platform can store offline regions at all.
  ///
  /// False on the web tiers: the engine compiles its offline database there,
  /// but nothing persists it across page loads yet, and a download that
  /// silently evaporates is worse than a feature that says it is missing.
  static bool get isSupported =>
      MapLibreFlutterPlatform.instance.offlineStore != null;

  /// One handle per region id, so two [listRegions] calls do not hand out two
  /// objects fighting over the single native observer that region has.
  final Map<int, MapLibreOfflineRegion> _regions = {};

  MapLibreOfflineStore get _store {
    final store = MapLibreFlutterPlatform.instance.offlineStore;
    if (store == null) {
      throw const MapLibreOfflineException(
        'this platform cannot store offline regions',
      );
    }
    return store;
  }

  /// Defines a region and, with [startDownload], begins downloading it.
  ///
  /// **Without [startDownload] the region downloads nothing** — it is created
  /// inactive and waits for [MapLibreOfflineRegion.resume]. That is mbgl's
  /// behaviour and every SDK over it inherits the surprise; the flag exists so
  /// the common case does not have to know.
  ///
  /// [metadata] is an opaque blob the engine stores and hands back untouched —
  /// this is how an app names its regions. It is deliberately `Uint8List` and
  /// not a typed structure: mbgl asks bindings not to impose a format on it so
  /// the database stays portable between SDKs. `utf8.encode(jsonEncode(...))`
  /// is the usual answer.
  ///
  /// Throws [MapLibreOfflineException] if the definition is not valid, or if
  /// it is not one this binding can download (see
  /// [MapLibreOtherRegionDefinition]).
  Future<MapLibreOfflineRegion> createRegion(
    MapLibreOfflineRegionDefinition definition, {
    Uint8List? metadata,
    bool startDownload = false,
  }) async {
    final store = _store;
    final id = await store.createRegion(definition, metadata: metadata);
    final region = MapLibreOfflineRegion.internal(
      store: store,
      id: id,
      definition: definition,
      metadata: metadata ?? Uint8List(0),
      status: const MapLibreOfflineRegionStatus(
        downloadState: MapLibreOfflineDownloadState.inactive,
        completedResourceCount: 0,
        completedResourceSize: 0,
        completedTileCount: 0,
        completedTileSize: 0,
        requiredResourceCount: 0,
        requiredTileCount: 0,
        requiredResourceCountIsPrecise: false,
      ),
      onDeleted: _regions.remove,
    );
    _regions[id] = region;
    if (startDownload) await region.resume();
    return region;
  }

  /// Every region in the database, each with the progress it has now.
  ///
  /// **Call this once on startup before touching a region created by a previous
  /// run.** The engine's mutators take a region object whose constructor is
  /// private to it, so an id alone cannot be turned back into one — until a
  /// region has been listed in this process, nothing can resume, delete or
  /// observe it.
  ///
  /// Handles are stable: listing twice returns the same objects, with their
  /// streams and listeners intact.
  Future<List<MapLibreOfflineRegion>> listRegions() async {
    final store = _store;
    final data = await store.listRegions();
    final seen = <int>{};
    final result = <MapLibreOfflineRegion>[];
    for (final region in data) {
      seen.add(region.id);
      final existing = _regions[region.id];
      if (existing != null) {
        existing.updateFromList(region);
        result.add(existing);
        continue;
      }
      final handle = MapLibreOfflineRegion.internal(
        store: store,
        id: region.id,
        definition: region.definition,
        metadata: region.metadata,
        status: region.status,
        onDeleted: _regions.remove,
      );
      _regions[region.id] = handle;
      result.add(handle);
    }
    // A region that has gone from the database — deleted by another isolate, or
    // by resetDatabase — must not keep a live handle claiming otherwise.
    for (final id in _regions.keys.toList()) {
      if (!seen.contains(id)) _regions.remove(id)?.markDeleted();
    }
    return result;
  }

  /// One region by id, or null if the database has none — a convenience over
  /// [listRegions], with the same "list before you touch" caveat.
  Future<MapLibreOfflineRegion?> getRegion(int id) async {
    final regions = await listRegions();
    for (final region in regions) {
      if (region.id == id) return region;
    }
    return null;
  }

  /// Raises or lowers the per-database tile cap. The engine's default is 6000.
  ///
  /// **Not a Mapbox-only limit**, despite mbgl calling it
  /// `setOfflineMapboxTileCountLimit` and citing the Mapbox terms of service:
  /// the counter is over tiles whose URL is canonical for the CONFIGURED tile
  /// server, and offline downloads canonicalise tile URLs before storing them,
  /// so self-hosted tiles count too. Past the cap the engine stops storing
  /// tiles and reports [MapLibreOfflineTileCountLimitExceeded] on the region's
  /// [MapLibreOfflineRegion.errors] — a large region reaches it long before it
  /// runs out of disk.
  void setTileCountLimit(int limit) => _store.setTileCountLimit(limit);

  /// Compacts the database file, releasing the space deleted regions freed.
  ///
  /// The engine already does this after every delete, so this is for a caller
  /// who turned that off or wants it at a chosen moment. It vacuums, which is
  /// slow and rewrites pages — not something to run on a frame.
  Future<void> packDatabase() => _store.packDatabase();

  /// Erases the ambient (opportunistic) tile cache — the "clear cache" button.
  ///
  /// **Downloaded regions survive.** The engine never evicts a resource a
  /// region requires, which is the point of keeping both in one database.
  /// Users assume this wipes everything, so say otherwise in your UI.
  Future<void> clearAmbientCache() => _store.clearAmbientCache();

  /// Caps the ambient cache at [bytes].
  ///
  /// **0 disables ambient caching entirely** while leaving regions alone —
  /// the supported way to run "only what I downloaded, nothing opportunistic".
  ///
  /// Expensive: it trims to fit before returning. The cap is over the whole
  /// database, so regions eat into it — 40 MB of regions under a 50 MB cap
  /// leaves the ambient cache 10.
  Future<void> setMaximumAmbientCacheSize(int bytes) =>
      _store.setMaximumAmbientCacheSize(bytes);

  /// Deletes the database and starts again — regions, ambient cache, all of it.
  ///
  /// The only call here that destroys downloaded regions. Every handle this
  /// manager has handed out is dead afterwards.
  Future<void> resetDatabase() async {
    for (final region in _regions.values.toList()) {
      region.markDeleted();
    }
    _regions.clear();
    await _store.resetDatabase();
  }

  /// How much disk the cache database is using, in bytes, or 0 if there is no
  /// persistent one.
  ///
  /// Read from the file rather than from the engine, which does not report it.
  /// It covers regions AND the ambient cache together — they share one file —
  /// so it is the number to show next to a "clear cache" row, not a per-region
  /// figure.
  Future<int> get cacheSizeOnDisk async {
    final path = MapLibreFlutterPlatform.instance.cachePath;
    if (path == null || path.isEmpty || path == ':memory:') return 0;
    if (kIsWeb) return 0;
    final file = File(path);
    return file.existsSync() ? file.length() : 0;
  }
}
