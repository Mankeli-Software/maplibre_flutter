import 'dart:typed_data';

import 'package:maplibre_flutter_core/maplibre_flutter_core.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// Adapts `maplibre_flutter_core`'s process-wide offline API to the platform
/// interface's [MapLibreOfflineStore] capability.
///
/// Identical in all five mbgl-core tiers, and duplicated in each rather than
/// shared: `maplibre_flutter_core` is deliberately Flutter-free so `dart test`
/// can run it, and the platform interface is Flutter-only, so the only packages
/// where the two types can meet are the platform packages themselves.
///
/// Stateless — the state is in the core, which is process-wide by design (an
/// offline region is rows in the cache database, not a property of any map).
class CoreOfflineStore implements MapLibreOfflineStore {
  const CoreOfflineStore();

  @override
  Future<int> createRegion(
    MapLibreOfflineRegionDefinition definition, {
    Uint8List? metadata,
  }) {
    // A region whose shape this binding cannot express did not come from here
    // — it was read out of a database something else wrote. Recreating it would
    // mean inventing a bounding box it never had.
    if (definition is! MapLibreTilePyramidRegionDefinition) {
      throw MapLibreOfflineException(
        'cannot create a region from a ${definition.runtimeType}: only a '
        'MapLibreTilePyramidRegionDefinition can be downloaded',
      );
    }
    return _guard(
      () => MapLibreCoreOffline.createRegion(
        styleUrl: definition.styleUrl,
        bounds: (
          swLat: definition.bounds.southwest.latitude,
          swLng: definition.bounds.southwest.longitude,
          neLat: definition.bounds.northeast.latitude,
          neLng: definition.bounds.northeast.longitude,
        ),
        minZoom: definition.minZoom,
        maxZoom: definition.maxZoom,
        pixelRatio: definition.pixelRatio,
        includeIdeographs: definition.includeIdeographs,
        metadata: metadata,
      ),
    );
  }

  @override
  Future<List<MapLibreOfflineRegionData>> listRegions() => _guard(() async {
    final regions = await MapLibreCoreOffline.listRegions();
    return regions.map(_toRegionData).toList();
  });

  @override
  void setDownloadState(int regionId, MapLibreOfflineDownloadState state) {
    MapLibreCoreOffline.setDownloadState(
      regionId,
      state == MapLibreOfflineDownloadState.active
          ? CoreOfflineDownloadState.active
          : CoreOfflineDownloadState.inactive,
    );
  }

  @override
  Future<MapLibreOfflineRegionStatus?> getRegionStatus(int regionId) =>
      _guard(() async {
        final status = await MapLibreCoreOffline.getRegionStatus(regionId);
        return status == null ? null : _toStatus(status);
      });

  @override
  bool setObserver(
    int regionId, {
    void Function(MapLibreOfflineRegionStatus status)? onStatus,
    void Function(MapLibreOfflineError error)? onError,
  }) => MapLibreCoreOffline.setObserver(
    regionId,
    onStatus: onStatus == null ? null : (s) => onStatus(_toStatus(s)),
    onError: onError == null ? null : (e) => onError(_toError(e)),
  );

  @override
  Future<void> setMetadata(int regionId, Uint8List metadata) =>
      _guard(() => MapLibreCoreOffline.setMetadata(regionId, metadata));

  @override
  Future<void> deleteRegion(int regionId) =>
      _guard(() => MapLibreCoreOffline.deleteRegion(regionId));

  @override
  Future<void> invalidateRegion(int regionId) =>
      _guard(() => MapLibreCoreOffline.invalidateRegion(regionId));

  @override
  void setTileCountLimit(int limit) =>
      MapLibreCoreOffline.setTileCountLimit(limit);

  @override
  Future<void> packDatabase() => _guard(MapLibreCoreOffline.packDatabase);

  @override
  Future<void> clearAmbientCache() =>
      _guard(MapLibreCoreOffline.clearAmbientCache);

  @override
  Future<void> setMaximumAmbientCacheSize(int bytes) =>
      _guard(() => MapLibreCoreOffline.setMaximumAmbientCacheSize(bytes));

  @override
  Future<void> resetDatabase() => _guard(MapLibreCoreOffline.resetDatabase);

  /// Re-throws the core's engine-level failure as the public one, so an app
  /// never has to import `maplibre_flutter_core` to catch it.
  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on CoreOfflineException catch (e) {
      throw MapLibreOfflineException(e.message);
    }
  }

  static MapLibreOfflineRegionData _toRegionData(CoreOfflineRegion region) =>
      MapLibreOfflineRegionData(
        id: region.id,
        definition: switch (region.kind) {
          CoreOfflineRegionKind.tilePyramid =>
            MapLibreTilePyramidRegionDefinition(
              styleUrl: region.styleUrl,
              bounds: LatLngBounds(
                southwest: LatLng(region.bounds!.swLat, region.bounds!.swLng),
                northeast: LatLng(region.bounds!.neLat, region.bounds!.neLng),
              ),
              minZoom: region.minZoom,
              maxZoom: region.maxZoom,
              pixelRatio: region.pixelRatio,
              includeIdeographs: region.includeIdeographs,
            ),
          CoreOfflineRegionKind.geometry => MapLibreOtherRegionDefinition(
            styleUrl: region.styleUrl,
            minZoom: region.minZoom,
            maxZoom: region.maxZoom,
            pixelRatio: region.pixelRatio,
            includeIdeographs: region.includeIdeographs,
          ),
        },
        metadata: region.metadata,
        status: _toStatus(region.status),
      );

  static MapLibreOfflineRegionStatus _toStatus(CoreOfflineRegionStatus s) =>
      MapLibreOfflineRegionStatus(
        downloadState: s.downloadState == CoreOfflineDownloadState.active
            ? MapLibreOfflineDownloadState.active
            : MapLibreOfflineDownloadState.inactive,
        completedResourceCount: s.completedResourceCount,
        completedResourceSize: s.completedResourceSize,
        completedTileCount: s.completedTileCount,
        completedTileSize: s.completedTileSize,
        requiredResourceCount: s.requiredResourceCount,
        requiredTileCount: s.requiredTileCount,
        requiredResourceCountIsPrecise: s.requiredResourceCountIsPrecise,
      );

  static MapLibreOfflineError _toError(CoreOfflineError e) => e.isTileCountLimit
      ? MapLibreOfflineTileCountLimitExceeded(
          regionId: e.regionId,
          message: e.message,
        )
      : MapLibreOfflineResponseError(regionId: e.regionId, message: e.message);
}
