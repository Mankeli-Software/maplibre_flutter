import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter/maplibre_flutter.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// A store that records what it was asked and answers from memory.
///
/// Everything below is about the app-facing layer — handle identity, stream
/// lifecycle, the dead-handle contract — none of which needs an engine. The
/// engine side is covered where it can actually be observed, in
/// `maplibre_flutter_core`'s native suite.
class _FakeStore implements MapLibreOfflineStore {
  final Map<int, MapLibreOfflineRegionData> regions = {};
  final List<String> calls = [];
  int _nextId = 1;

  /// The single observer the engine allows per region, as installed.
  final Map<
    int,
    ({
      void Function(MapLibreOfflineRegionStatus)? onStatus,
      void Function(MapLibreOfflineError)? onError,
    })
  >
  observers = {};

  static const idleStatus = MapLibreOfflineRegionStatus(
    downloadState: MapLibreOfflineDownloadState.inactive,
    completedResourceCount: 0,
    completedResourceSize: 0,
    completedTileCount: 0,
    completedTileSize: 0,
    requiredResourceCount: 0,
    requiredTileCount: 0,
    requiredResourceCountIsPrecise: false,
  );

  @override
  Future<int> createRegion(
    MapLibreOfflineRegionDefinition definition, {
    Uint8List? metadata,
  }) async {
    if (definition is! MapLibreTilePyramidRegionDefinition) {
      throw const MapLibreOfflineException('not downloadable');
    }
    calls.add('createRegion');
    final id = _nextId++;
    regions[id] = MapLibreOfflineRegionData(
      id: id,
      definition: definition,
      metadata: metadata ?? Uint8List(0),
      status: idleStatus,
    );
    return id;
  }

  @override
  Future<List<MapLibreOfflineRegionData>> listRegions() async {
    calls.add('listRegions');
    return regions.values.toList();
  }

  @override
  void setDownloadState(int regionId, MapLibreOfflineDownloadState state) {
    calls.add('setDownloadState($regionId, ${state.name})');
    final region = regions[regionId];
    if (region == null) return;
    regions[regionId] = MapLibreOfflineRegionData(
      id: region.id,
      definition: region.definition,
      metadata: region.metadata,
      status: _withState(region.status, state),
    );
  }

  @override
  Future<MapLibreOfflineRegionStatus?> getRegionStatus(int regionId) async =>
      regions[regionId]?.status;

  @override
  bool setObserver(
    int regionId, {
    void Function(MapLibreOfflineRegionStatus status)? onStatus,
    void Function(MapLibreOfflineError error)? onError,
  }) {
    if (onStatus == null && onError == null) {
      calls.add('removeObserver($regionId)');
      observers.remove(regionId);
      return true;
    }
    calls.add('setObserver($regionId)');
    observers[regionId] = (onStatus: onStatus, onError: onError);
    return true;
  }

  @override
  Future<void> setMetadata(int regionId, Uint8List metadata) async {
    final region = regions[regionId]!;
    regions[regionId] = MapLibreOfflineRegionData(
      id: region.id,
      definition: region.definition,
      metadata: metadata,
      status: region.status,
    );
  }

  /// Set to make the next [deleteRegion] fail, as a full or read-only volume
  /// would.
  bool failDelete = false;

  @override
  Future<void> deleteRegion(int regionId) async {
    calls.add('deleteRegion($regionId)');
    // The engine drops the observer BEFORE attempting the delete, so a fake
    // that failed without doing that would not reproduce what a real failure
    // leaves behind.
    observers.remove(regionId);
    if (failDelete) throw const MapLibreOfflineException('disk full');
    regions.remove(regionId);
  }

  @override
  Future<void> invalidateRegion(int regionId) async =>
      calls.add('invalidateRegion($regionId)');

  @override
  void setTileCountLimit(int limit) => calls.add('setTileCountLimit($limit)');

  @override
  Future<void> packDatabase() async => calls.add('packDatabase');

  @override
  Future<void> clearAmbientCache() async => calls.add('clearAmbientCache');

  @override
  Future<void> setMaximumAmbientCacheSize(int bytes) async =>
      calls.add('setMaximumAmbientCacheSize($bytes)');

  @override
  Future<void> resetDatabase() async {
    calls.add('resetDatabase');
    regions.clear();
  }

  /// Pushes a status the way the engine's observer would.
  void emitStatus(int regionId, MapLibreOfflineRegionStatus status) {
    final region = regions[regionId];
    if (region != null) {
      regions[regionId] = MapLibreOfflineRegionData(
        id: region.id,
        definition: region.definition,
        metadata: region.metadata,
        status: status,
      );
    }
    observers[regionId]?.onStatus?.call(status);
  }

  void emitError(int regionId, MapLibreOfflineError error) =>
      observers[regionId]?.onError?.call(error);

  static MapLibreOfflineRegionStatus _withState(
    MapLibreOfflineRegionStatus status,
    MapLibreOfflineDownloadState state,
  ) => MapLibreOfflineRegionStatus(
    downloadState: state,
    completedResourceCount: status.completedResourceCount,
    completedResourceSize: status.completedResourceSize,
    completedTileCount: status.completedTileCount,
    completedTileSize: status.completedTileSize,
    requiredResourceCount: status.requiredResourceCount,
    requiredTileCount: status.requiredTileCount,
    requiredResourceCountIsPrecise: status.requiredResourceCountIsPrecise,
  );
}

class _OfflinePlatform extends MapLibreFlutterPlatform {
  _OfflinePlatform(this.store, {this.path = '/tmp/does-not-exist/tiles.db'});

  final MapLibreOfflineStore? store;
  final String? path;

  @override
  MapLibreOfflineStore? get offlineStore => store;

  @override
  String? get cachePath => path;
}

MapLibreTilePyramidRegionDefinition _definition({
  double maxZoom = 12,
  double pixelRatio = 1,
}) => MapLibreTilePyramidRegionDefinition(
  styleUrl: 'https://example.com/style.json',
  bounds: LatLngBounds(
    southwest: const LatLng(51.0, -0.6),
    northeast: const LatLng(51.8, 0.4),
  ),
  minZoom: 0,
  maxZoom: maxZoom,
  pixelRatio: pixelRatio,
);

MapLibreOfflineRegionStatus _status({
  int completed = 0,
  int required = 0,
  bool precise = false,
  MapLibreOfflineDownloadState state = MapLibreOfflineDownloadState.active,
}) => MapLibreOfflineRegionStatus(
  downloadState: state,
  completedResourceCount: completed,
  completedResourceSize: completed * 1000,
  completedTileCount: completed,
  completedTileSize: completed * 900,
  requiredResourceCount: required,
  requiredTileCount: required,
  requiredResourceCountIsPrecise: precise,
);

void main() {
  late _FakeStore store;

  setUp(() async {
    store = _FakeStore();
    MapLibreFlutterPlatform.instance = _OfflinePlatform(store);
    // The manager is a singleton, so a region left over from a previous test
    // would leak its handle into the next one.
    await MapLibreOfflineManager.instance.resetDatabase();
    store.calls.clear();
  });

  group('support', () {
    test(
      'a tier with no store reports itself unsupported and throws',
      () async {
        MapLibreFlutterPlatform.instance = _OfflinePlatform(null);
        expect(MapLibreOfflineManager.isSupported, isFalse);
        await expectLater(
          MapLibreOfflineManager.instance.listRegions(),
          throwsA(isA<MapLibreOfflineException>()),
        );
      },
    );

    test('a tier with a store reports itself supported', () {
      expect(MapLibreOfflineManager.isSupported, isTrue);
    });
  });

  group('createRegion', () {
    test('creates INACTIVE by default — the upstream behaviour everyone '
        'trips over', () async {
      final region = await MapLibreOfflineManager.instance.createRegion(
        _definition(),
      );
      expect(region.downloadState, MapLibreOfflineDownloadState.inactive);
      expect(
        store.calls,
        isNot(contains(startsWith('setDownloadState'))),
        reason: 'creating must not start a download by itself',
      );
    });

    test('startDownload resumes it in the same call', () async {
      final region = await MapLibreOfflineManager.instance.createRegion(
        _definition(),
        startDownload: true,
      );
      expect(region.downloadState, MapLibreOfflineDownloadState.active);
      expect(store.calls, contains('setDownloadState(1, active)'));
    });

    test(
      'metadata survives as bytes, including bytes that are not text',
      () async {
        final blob = Uint8List.fromList([0, 255, 16, 0, 128]);
        final region = await MapLibreOfflineManager.instance.createRegion(
          _definition(),
          metadata: blob,
        );
        expect(region.metadata, orderedEquals(blob));

        await region.setMetadata(Uint8List.fromList(utf8.encode('renamed')));
        expect(utf8.decode(region.metadata), 'renamed');
      },
    );

    test('a definition this binding cannot download is refused', () async {
      // A geometry region can only come out of a database something else wrote;
      // recreating it would mean inventing a bounding box it never had.
      await expectLater(
        MapLibreOfflineManager.instance.createRegion(
          const MapLibreOtherRegionDefinition(
            styleUrl: 'https://example.com/style.json',
            minZoom: 0,
            maxZoom: 5,
          ),
        ),
        throwsA(isA<MapLibreOfflineException>()),
      );
    });
  });

  group('handles', () {
    test('listing twice returns the SAME handle, refreshed', () async {
      final created = await MapLibreOfflineManager.instance.createRegion(
        _definition(),
      );
      store.emitStatus(created.id, _status(completed: 3, required: 9));

      final first =
          (await MapLibreOfflineManager.instance.listRegions()).single;
      final second =
          (await MapLibreOfflineManager.instance.listRegions()).single;

      // Identity is the assertion, not equality: two handles for one region
      // would fight over the single observer the engine allows it, and the
      // loser's stream would go quiet with nothing to show for it.
      expect(identical(first, created), isTrue);
      expect(identical(second, created), isTrue);
      expect(first.status.completedResourceCount, 3);
    });

    test('a region that vanished from the database kills its handle', () async {
      final region = await MapLibreOfflineManager.instance.createRegion(
        _definition(),
      );
      // As if another isolate — or another app — deleted it.
      store.regions.remove(region.id);

      expect(await MapLibreOfflineManager.instance.listRegions(), isEmpty);
      expect(region.isDeleted, isTrue);
      expect(() => region.resume(), throwsStateError);
    });

    test(
      'delete kills the handle, mirroring the engine taking ownership',
      () async {
        final region = await MapLibreOfflineManager.instance.createRegion(
          _definition(),
        );
        await region.delete();

        expect(region.isDeleted, isTrue);
        expect(() => region.statusChanges, throwsStateError);
        expect(() => region.getStatus(), throwsStateError);
        expect(() => region.delete(), throwsStateError);
        expect(await MapLibreOfflineManager.instance.listRegions(), isEmpty);
      },
    );

    test('getRegion finds one by id, or returns null', () async {
      final region = await MapLibreOfflineManager.instance.createRegion(
        _definition(),
      );
      expect(
        identical(
          await MapLibreOfflineManager.instance.getRegion(region.id),
          region,
        ),
        isTrue,
      );
      expect(await MapLibreOfflineManager.instance.getRegion(4242), isNull);
    });

    test('the definition round-trips through a listing', () async {
      final created = await MapLibreOfflineManager.instance.createRegion(
        _definition(maxZoom: double.infinity, pixelRatio: 3),
      );
      final listed =
          (await MapLibreOfflineManager.instance.listRegions()).single;
      final definition =
          listed.definition as MapLibreTilePyramidRegionDefinition;

      expect(listed.id, created.id);
      expect(definition.maxZoom, double.infinity);
      expect(definition.pixelRatio, 3);
      // Asymmetric corners, so a swapped north/south or east/west shows up
      // (CLAUDE.md §11).
      expect(definition.bounds.southwest, const LatLng(51.0, -0.6));
      expect(definition.bounds.northeast, const LatLng(51.8, 0.4));
    });
  });

  group('streams', () {
    test(
      'the observer is installed on first listen and removed on cancel',
      () async {
        final region = await MapLibreOfflineManager.instance.createRegion(
          _definition(),
        );
        expect(store.observers, isEmpty);

        final sub = region.statusChanges.listen((_) {});
        await pumpEventQueue();
        expect(store.observers.keys, contains(region.id));

        await sub.cancel();
        await pumpEventQueue();
        expect(
          store.observers,
          isEmpty,
          reason: 'an idle screen must not keep an observer alive',
        );
      },
    );

    test(
      'one observer serves both streams, and outlives either alone',
      () async {
        final region = await MapLibreOfflineManager.instance.createRegion(
          _definition(),
        );
        final statusSub = region.statusChanges.listen((_) {});
        final errorSub = region.errors.listen((_) {});
        await pumpEventQueue();
        expect(store.observers.keys, contains(region.id));

        await statusSub.cancel();
        await pumpEventQueue();
        expect(
          store.observers.keys,
          contains(region.id),
          reason: 'the errors stream still has a listener',
        );

        await errorSub.cancel();
        await pumpEventQueue();
        expect(store.observers, isEmpty);
      },
    );

    test(
      'status events reach the stream AND update the synchronous getter',
      () async {
        final region = await MapLibreOfflineManager.instance.createRegion(
          _definition(),
        );
        final seen = <MapLibreOfflineRegionStatus>[];
        final sub = region.statusChanges.listen(seen.add);
        await pumpEventQueue();

        store.emitStatus(region.id, _status(completed: 5, required: 10));
        await pumpEventQueue();

        expect(seen, hasLength(1));
        expect(seen.single.completedResourceCount, 5);
        // A widget painting outside a StreamBuilder needs the last value without
        // waiting for the next one.
        expect(region.status.completedResourceCount, 5);
        await sub.cancel();
      },
    );

    test(
      'errors arrive sealed, so a handler can switch exhaustively',
      () async {
        final region = await MapLibreOfflineManager.instance.createRegion(
          _definition(),
        );
        final seen = <MapLibreOfflineError>[];
        final sub = region.errors.listen(seen.add);
        await pumpEventQueue();

        store.emitError(
          region.id,
          MapLibreOfflineResponseError(regionId: region.id, message: '404'),
        );
        store.emitError(
          region.id,
          MapLibreOfflineTileCountLimitExceeded(
            regionId: region.id,
            message: 'limit',
          ),
        );
        await pumpEventQueue();

        expect(seen, hasLength(2));
        final descriptions = seen
            .map(
              (e) => switch (e) {
                MapLibreOfflineResponseError() => 'retrying',
                MapLibreOfflineTileCountLimitExceeded() => 'stopped',
              },
            )
            .toList();
        expect(descriptions, ['retrying', 'stopped']);
        await sub.cancel();
      },
    );

    test('a FAILED delete leaves the region observable', () async {
      // The engine tears the observer down before it tries the delete, so
      // without a restore an app that catches "could not delete" and keeps its
      // progress screen up would sit there watching a download report nothing.
      final region = await MapLibreOfflineManager.instance.createRegion(
        _definition(),
      );
      final seen = <MapLibreOfflineRegionStatus>[];
      final sub = region.statusChanges.listen(seen.add);
      await pumpEventQueue();
      expect(store.observers.keys, contains(region.id));

      store.failDelete = true;
      await expectLater(
        region.delete(),
        throwsA(isA<MapLibreOfflineException>()),
      );

      expect(region.isDeleted, isFalse);
      expect(
        store.observers.keys,
        contains(region.id),
        reason: 'the observer must be back',
      );
      store.emitStatus(region.id, _status(completed: 1, required: 2));
      await pumpEventQueue();
      expect(seen, hasLength(1));
      await sub.cancel();
    });

    test('deleting closes the streams and drops the observer', () async {
      final region = await MapLibreOfflineManager.instance.createRegion(
        _definition(),
      );
      var closed = false;
      final sub = region.statusChanges.listen(
        (_) {},
        onDone: () => closed = true,
      );
      await pumpEventQueue();

      await region.delete();
      await pumpEventQueue();

      expect(closed, isTrue);
      expect(store.observers, isEmpty);
      await sub.cancel();
    });
  });

  group('progress', () {
    test('is null while the required total is only a lower bound', () {
      // mbgl grows requiredResourceCount as it discovers sources, so a fraction
      // computed before it is precise runs BACKWARDS. Null is the honest
      // answer and an indeterminate bar is the honest UI.
      expect(_status(completed: 5, required: 10).progress, isNull);
      expect(_status(completed: 5, required: 10, precise: true).progress, 0.5);
    });

    test('is null rather than a divide-by-zero when nothing is required', () {
      expect(_status(precise: true).progress, isNull);
    });

    test('clamps at 1 — completed can exceed required', () {
      // isComplete is `completed >= required`, so the engine can and does
      // report more than 100%.
      final status = _status(completed: 12, required: 10, precise: true);
      expect(status.progress, 1);
      expect(status.isComplete, isTrue);
    });
  });

  group('manager-level operations', () {
    test('resume and suspend go through to the store', () async {
      final region = await MapLibreOfflineManager.instance.createRegion(
        _definition(),
      );
      await region.resume();
      expect(region.downloadState, MapLibreOfflineDownloadState.active);
      await region.suspend();
      expect(region.downloadState, MapLibreOfflineDownloadState.inactive);
      expect(
        store.calls,
        containsAllInOrder([
          'setDownloadState(${region.id}, active)',
          'setDownloadState(${region.id}, inactive)',
        ]),
      );
    });

    test('invalidate does not delete', () async {
      final region = await MapLibreOfflineManager.instance.createRegion(
        _definition(),
      );
      await region.invalidate();
      expect(store.calls, contains('invalidateRegion(${region.id})'));
      expect(region.isDeleted, isFalse);
      expect(await MapLibreOfflineManager.instance.listRegions(), hasLength(1));
    });

    test('resetDatabase kills every outstanding handle', () async {
      final a = await MapLibreOfflineManager.instance.createRegion(
        _definition(),
      );
      final b = await MapLibreOfflineManager.instance.createRegion(
        _definition(),
      );
      await MapLibreOfflineManager.instance.resetDatabase();

      expect(a.isDeleted, isTrue);
      expect(b.isDeleted, isTrue);
      expect(await MapLibreOfflineManager.instance.listRegions(), isEmpty);
    });

    test('the ambient-cache calls forward, and keep regions', () async {
      await MapLibreOfflineManager.instance.createRegion(_definition());
      await MapLibreOfflineManager.instance.clearAmbientCache();
      await MapLibreOfflineManager.instance.setMaximumAmbientCacheSize(0);
      await MapLibreOfflineManager.instance.packDatabase();
      MapLibreOfflineManager.instance.setTileCountLimit(50000);

      expect(
        store.calls,
        containsAll([
          'clearAmbientCache',
          'setMaximumAmbientCacheSize(0)',
          'packDatabase',
          'setTileCountLimit(50000)',
        ]),
      );
      expect(await MapLibreOfflineManager.instance.listRegions(), hasLength(1));
    });

    test('cacheSizeOnDisk is 0 when there is no persistent database', () async {
      MapLibreFlutterPlatform.instance = _OfflinePlatform(
        store,
        path: ':memory:',
      );
      expect(await MapLibreOfflineManager.instance.cacheSizeOnDisk, 0);

      MapLibreFlutterPlatform.instance = _OfflinePlatform(store, path: null);
      expect(await MapLibreOfflineManager.instance.cacheSizeOnDisk, 0);
    });
  });
}
