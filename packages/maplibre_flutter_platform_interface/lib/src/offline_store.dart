import 'package:flutter/foundation.dart';

import 'lat_lng_bounds.dart';

/// What an offline region covers.
///
/// Sealed because the engine has exactly two shapes and only one of them can be
/// created here — see [MapLibreOtherRegionDefinition].
sealed class MapLibreOfflineRegionDefinition {
  const MapLibreOfflineRegionDefinition({
    required this.styleUrl,
    required this.minZoom,
    required this.maxZoom,
    this.pixelRatio = 1.0,
    this.includeIdeographs = false,
  });

  /// The style to download, and everything it references.
  final String styleUrl;

  /// The shallowest zoom to fetch tiles for.
  final double minZoom;

  /// The deepest. [double.infinity] means "as deep as each source goes", which
  /// is a real option and not a mistake.
  final double maxZoom;

  /// The device pixel ratio the region is for.
  ///
  /// **A region downloaded at 1.0 and displayed at 2.0 re-fetches every raster
  /// tile**, which on a mixed-DPI fleet is an offline map that is not offline.
  /// mbgl requires it; Apple's initializer hides it, and that is the gotcha.
  final double pixelRatio;

  /// Whether to download CJK glyphs rather than render them locally. Large.
  final bool includeIdeographs;
}

/// A bounding box and zoom range — Apple `MLNTilePyramidOfflineRegion`, mbgl
/// `OfflineTilePyramidRegionDefinition`.
@immutable
final class MapLibreTilePyramidRegionDefinition
    extends MapLibreOfflineRegionDefinition {
  const MapLibreTilePyramidRegionDefinition({
    required super.styleUrl,
    required this.bounds,
    required super.minZoom,
    required super.maxZoom,
    super.pixelRatio,
    super.includeIdeographs,
  });

  /// The area to cover.
  ///
  /// A box crossing the antimeridian needs an UNWRAPPED east — south-west
  /// longitude 170, north-east longitude 190. An inverted pair is rejected
  /// rather than normalised: the engine would hull it into the complementary
  /// box, which is the rest of the world, and downloading that silently is
  /// worse than an error.
  final LatLngBounds bounds;

  @override
  String toString() =>
      'MapLibreTilePyramidRegionDefinition(styleUrl: $styleUrl, '
      'bounds: $bounds, minZoom: $minZoom, maxZoom: $maxZoom, '
      'pixelRatio: $pixelRatio, includeIdeographs: $includeIdeographs)';
}

/// A region this binding cannot describe — in practice mbgl's
/// `OfflineGeometryRegionDefinition`, which covers a GeoJSON shape rather than
/// a box.
///
/// It can only appear if something else wrote to the same database. It is
/// reported as its own type, carrying no bounds, rather than flattened to a
/// bounding box it never had; it can still be listed, invalidated and deleted.
@immutable
final class MapLibreOtherRegionDefinition
    extends MapLibreOfflineRegionDefinition {
  const MapLibreOtherRegionDefinition({
    required super.styleUrl,
    required super.minZoom,
    required super.maxZoom,
    super.pixelRatio,
    super.includeIdeographs,
  });

  @override
  String toString() =>
      'MapLibreOtherRegionDefinition(styleUrl: $styleUrl, '
      'minZoom: $minZoom, maxZoom: $maxZoom)';
}

/// Whether a region is downloading. Mirrors `mbgl::OfflineRegionDownloadState`.
enum MapLibreOfflineDownloadState {
  /// Not fetching. Whatever was already downloaded stays usable — this is not
  /// "empty".
  inactive,

  /// Fetching, or waiting for the network to come back so it can.
  active,
}

/// How far a region's download has got. Field-for-field
/// `mbgl::OfflineRegionStatus`, because all three upstream SDKs agree on it.
///
/// **A byte-accurate progress bar is impossible** and that is upstream's own
/// position: mbgl states outright that the required total *size* is not
/// available, only counts. The only correct fraction is
/// [completedResourceCount] / [requiredResourceCount] — and even that jumps
/// while [requiredResourceCountIsPrecise] is false, because the total is a
/// lower bound that grows as sources are discovered. Show a spinner until it
/// turns true, or the UI will look broken.
@immutable
final class MapLibreOfflineRegionStatus {
  const MapLibreOfflineRegionStatus({
    required this.downloadState,
    required this.completedResourceCount,
    required this.completedResourceSize,
    required this.completedTileCount,
    required this.completedTileSize,
    required this.requiredResourceCount,
    required this.requiredTileCount,
    required this.requiredResourceCountIsPrecise,
  });

  final MapLibreOfflineDownloadState downloadState;

  /// Resources fully downloaded and ready for offline use.
  final int completedResourceCount;

  /// Their cumulative size in bytes.
  final int completedResourceSize;

  /// Tiles fully downloaded — a subset of [completedResourceCount].
  final int completedTileCount;

  /// Their cumulative size in bytes.
  final int completedTileSize;

  /// Resources known to be required. See [requiredResourceCountIsPrecise].
  final int requiredResourceCount;

  /// Tiles known to be required.
  final int requiredTileCount;

  /// Whether [requiredResourceCount] is a count rather than a lower bound.
  ///
  /// False during the early phase of a download, until the style and its tile
  /// sources have been fetched and the pyramid enumerated.
  final bool requiredResourceCountIsPrecise;

  /// Whether everything required is downloaded.
  bool get isComplete => completedResourceCount >= requiredResourceCount;

  /// Downloaded fraction in 0..1, or null while it would be meaningless —
  /// which is exactly while [requiredResourceCountIsPrecise] is false.
  ///
  /// Null rather than a guess on purpose: a bar that runs backwards is a worse
  /// answer than an indeterminate one.
  double? get progress {
    if (!requiredResourceCountIsPrecise || requiredResourceCount == 0) {
      return null;
    }
    final fraction = completedResourceCount / requiredResourceCount;
    return fraction > 1 ? 1 : fraction;
  }

  @override
  String toString() =>
      'MapLibreOfflineRegionStatus($downloadState, '
      '$completedResourceCount/$requiredResourceCount resources, '
      'precise: $requiredResourceCountIsPrecise, '
      '$completedTileCount/$requiredTileCount tiles, '
      '$completedResourceSize bytes)';
}

/// Something that went wrong while downloading a region.
///
/// Sealed so a handler can switch exhaustively (CLAUDE.md §9), which matters
/// here because the two cases want opposite responses: one is transient and the
/// other is not.
@immutable
sealed class MapLibreOfflineError {
  const MapLibreOfflineError({required this.regionId, required this.message});

  /// The region the failure belongs to.
  final int regionId;

  /// The engine's own text.
  final String message;
}

/// A resource could not be fetched.
///
/// **Recoverable, and already being retried**: mbgl re-requests failed
/// resources on an exponential backoff and again when the network returns. Show
/// it; do not act on it.
final class MapLibreOfflineResponseError extends MapLibreOfflineError {
  const MapLibreOfflineResponseError({
    required super.regionId,
    required super.message,
  });

  @override
  String toString() => 'MapLibreOfflineResponseError($regionId): $message';
}

/// The database's tile cap was reached; **no further tiles will be stored** for
/// any region in it until some are freed.
///
/// Not a Mapbox-only condition, despite mbgl calling the setter
/// `setOfflineMapboxTileCountLimit`: the counter is over tiles whose URL is
/// canonical for the CONFIGURED tile server, and downloads canonicalise tile
/// URLs before storing them, so self-hosted tiles count too. Raise the cap with
/// `MapLibreOfflineManager.setTileCountLimit` or delete a region.
final class MapLibreOfflineTileCountLimitExceeded extends MapLibreOfflineError {
  const MapLibreOfflineTileCountLimitExceeded({
    required super.regionId,
    required super.message,
  });

  @override
  String toString() =>
      'MapLibreOfflineTileCountLimitExceeded($regionId): $message';
}

/// The offline database could not do what was asked. Carries the engine's text.
class MapLibreOfflineException implements Exception {
  const MapLibreOfflineException(this.message);

  final String message;

  @override
  String toString() => 'MapLibreOfflineException: $message';
}

/// One region as the store sees it: identity, definition, blob and progress.
///
/// The app-facing package wraps this in a handle with streams; this is the flat
/// value that crosses the interface.
@immutable
final class MapLibreOfflineRegionData {
  const MapLibreOfflineRegionData({
    required this.id,
    required this.definition,
    required this.metadata,
    required this.status,
  });

  final int id;
  final MapLibreOfflineRegionDefinition definition;

  /// The application's own opaque blob, empty when none was stored.
  final Uint8List metadata;
  final MapLibreOfflineRegionStatus status;
}

/// The offline capability, feature-detected rather than part of the base
/// contract (CLAUDE.md §3): a tier that cannot store regions returns null from
/// `MapLibreFlutterPlatform.offlineStore` and the app-facing manager reports
/// itself unsupported.
///
/// Every method here is flat and id-keyed. The handle-shaped API — region
/// objects with `statusChanges` streams — is built on top in `maplibre_flutter`,
/// so this interface stays cheap for an implementation to satisfy.
abstract interface class MapLibreOfflineStore {
  /// Defines a region and returns its id. **It downloads nothing** until
  /// [setDownloadState] — the engine's behaviour, shared by every SDK over it.
  Future<int> createRegion(
    MapLibreOfflineRegionDefinition definition, {
    Uint8List? metadata,
  });

  /// Every region in the database, each with its progress.
  ///
  /// Also what makes a region from a previous run actionable: the engine's
  /// mutators take a region object whose constructor is private to it, so an id
  /// alone cannot be turned back into one.
  Future<List<MapLibreOfflineRegionData>> listRegions();

  /// Starts or pauses a download. A no-op for an id this process has not
  /// listed.
  void setDownloadState(int regionId, MapLibreOfflineDownloadState state);

  /// Reads progress once. Null for an id this process does not hold.
  Future<MapLibreOfflineRegionStatus?> getRegionStatus(int regionId);

  /// Watches one region. Both handlers null removes the observer. Returns false
  /// for an id this process does not hold, in which case nothing was
  /// registered.
  bool setObserver(
    int regionId, {
    void Function(MapLibreOfflineRegionStatus status)? onStatus,
    void Function(MapLibreOfflineError error)? onError,
  });

  /// Replaces a region's opaque metadata blob.
  Future<void> setMetadata(int regionId, Uint8List metadata);

  /// Deletes a region and evicts the resources no other region needs.
  Future<void> deleteRegion(int regionId);

  /// Marks a region's tiles stale so the next load revalidates them.
  Future<void> invalidateRegion(int regionId);

  /// Raises or lowers the per-database tile cap (the engine default is 6000).
  void setTileCountLimit(int limit);

  /// Compacts the database file. Slow; the engine already does it after a
  /// delete.
  Future<void> packDatabase();

  /// Erases the ambient (opportunistic) cache. Regions survive.
  Future<void> clearAmbientCache();

  /// Caps the ambient cache. 0 disables ambient caching while leaving regions
  /// alone.
  Future<void> setMaximumAmbientCacheSize(int bytes);

  /// Deletes the database and starts again — regions included.
  Future<void> resetDatabase();
}
