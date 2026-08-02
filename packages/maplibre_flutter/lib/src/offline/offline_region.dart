import 'dart:async';
import 'dart:typed_data';

import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:meta/meta.dart';

/// One downloaded (or downloading) region.
///
/// Get one from `MapLibreOfflineManager.instance` — never construct it. The
/// manager keeps one handle per region id, so the streams below belong to the
/// region rather than to whoever happened to list it.
///
/// Named after mbgl and Android's `OfflineRegion` rather than Apple's
/// `MLNOfflinePack`: two of the three upstreams agree, it is the engine's own
/// word, and calling an `mbgl::OfflineRegion` a "pack" invites exactly the
/// confusion this binding does not need.
class MapLibreOfflineRegion {
  /// Not public API — `MapLibreOfflineManager` builds these.
  @internal
  MapLibreOfflineRegion.internal({
    required MapLibreOfflineStore store,
    required this.id,
    required MapLibreOfflineRegionDefinition definition,
    required Uint8List metadata,
    required MapLibreOfflineRegionStatus status,
    required void Function(int id) onDeleted,
  }) : _store = store,
       _definition = definition,
       _metadata = metadata,
       _status = status,
       _onDeleted = onDeleted;
  // ignore_for_file: prefer_initializing_formals — the fields are private and
  // the parameters are not: this constructor is @internal but its signature is
  // still what a reader sees, and `_store` reads as a typo there.

  final MapLibreOfflineStore _store;
  final void Function(int id) _onDeleted;

  /// The engine's id for this region, stable across restarts. Persist it if you
  /// want to find a particular region again — but see
  /// `MapLibreOfflineManager.listRegions` for why an id alone is not enough.
  final int id;

  MapLibreOfflineRegionDefinition _definition;
  Uint8List _metadata;
  MapLibreOfflineRegionStatus _status;
  bool _deleted = false;

  StreamController<MapLibreOfflineRegionStatus>? _statusController;
  StreamController<MapLibreOfflineError>? _errorController;

  /// What this region covers.
  MapLibreOfflineRegionDefinition get definition => _definition;

  /// The application's own opaque blob, empty when none was stored.
  Uint8List get metadata => _metadata;

  /// The most recent progress seen — from the last list, [getStatus], or an
  /// observed change. Synchronous, so a widget can paint from it; call
  /// [getStatus] to refresh it.
  MapLibreOfflineRegionStatus get status => _status;

  /// Whether this region is downloading. Shorthand for
  /// `status.downloadState`.
  MapLibreOfflineDownloadState get downloadState => _status.downloadState;

  /// Whether this region has been [delete]d, or the database reset under it.
  /// Every other member throws [StateError] once this is true.
  bool get isDeleted => _deleted;

  /// Starts (or restarts) downloading — Apple's verb.
  ///
  /// The engine downloads what is missing and skips what it already has, so
  /// resuming an interrupted region costs only the remainder. It also keeps
  /// retrying failed resources on its own backoff while active, so a region
  /// that stalls on a flaky network does not need resuming by hand.
  Future<void> resume() async {
    _check();
    _store.setDownloadState(id, MapLibreOfflineDownloadState.active);
    await _refresh();
  }

  /// Pauses downloading. What is already downloaded stays usable.
  Future<void> suspend() async {
    _check();
    _store.setDownloadState(id, MapLibreOfflineDownloadState.inactive);
    await _refresh();
  }

  /// Reads progress now, and updates [status].
  ///
  /// This is what a UI needs on startup: [statusChanges] only fires on a
  /// CHANGE, so a finished region that nobody is downloading never reports
  /// anything at all.
  Future<MapLibreOfflineRegionStatus> getStatus() async {
    _check();
    final status = await _store.getRegionStatus(id);
    if (status != null) _status = status;
    return _status;
  }

  /// Progress, as it changes.
  ///
  /// A broadcast stream over what mbgl calls an `OfflineRegionObserver`, Apple
  /// posts as `MLNOfflinePackProgressChangedNotification`, and Android takes an
  /// observer object for — one Flutter idiom in place of three mechanisms, so
  /// do not go looking for `setObserver`.
  ///
  /// The observer is installed on the first listener and removed when this and
  /// [errors] both have none, so an idle screen costs nothing. Events arrive on
  /// this isolate; the engine reports from its own database thread.
  ///
  /// During an active download this fires often — per resource, not per second.
  /// Build the UI on [MapLibreOfflineRegionStatus.progress], which is null
  /// precisely while a fraction would be misleading.
  Stream<MapLibreOfflineRegionStatus> get statusChanges {
    _check();
    return (_statusController ??= StreamController.broadcast(
      onListen: _syncObserver,
      onCancel: _syncObserver,
    )).stream;
  }

  /// Failures while downloading.
  ///
  /// Sealed, because the two cases want opposite responses:
  /// [MapLibreOfflineResponseError] is transient and already being retried, and
  /// [MapLibreOfflineTileCountLimitExceeded] means nothing more will be stored
  /// until something is freed.
  ///
  /// Shares one observer with [statusChanges]; see there for lifecycle.
  Stream<MapLibreOfflineError> get errors {
    _check();
    return (_errorController ??= StreamController.broadcast(
      onListen: _syncObserver,
      onCancel: _syncObserver,
    )).stream;
  }

  /// Replaces the opaque metadata blob — how an app renames a region.
  Future<void> setMetadata(Uint8List metadata) async {
    _check();
    await _store.setMetadata(id, metadata);
    _metadata = metadata;
  }

  /// Marks this region's tiles stale, so the next map load revalidates them
  /// against the server rather than trusting the cache.
  ///
  /// Much cheaper than deleting and re-downloading: an unchanged tile costs one
  /// conditional request instead of its bytes.
  Future<void> invalidate() async {
    _check();
    await _store.invalidateRegion(id);
  }

  /// Deletes this region. **The handle is dead afterwards** — every member
  /// throws [StateError], which mirrors the engine, where deletion takes
  /// ownership of the region.
  ///
  /// Only resources no OTHER region needs are evicted, so deleting one of two
  /// overlapping regions frees less than its own size.
  Future<void> delete() async {
    _check();
    try {
      await _store.deleteRegion(id);
    } on Object {
      // The engine drops the observer before attempting the delete, so a failed
      // delete otherwise leaves this handle alive, still listened to, and
      // permanently silent — the streams have not changed, so nothing would
      // re-install it. An app that catches "could not delete" and leaves the
      // progress screen up must keep seeing progress.
      _syncObserver();
      rethrow;
    }
    markDeleted();
  }

  /// Not public API — the manager calls this when the region is gone from the
  /// database, whether or not this handle deleted it.
  @internal
  void markDeleted() {
    if (_deleted) return;
    _deleted = true;
    _store.setObserver(id);
    _statusController?.close();
    _errorController?.close();
    _statusController = null;
    _errorController = null;
    _onDeleted(id);
  }

  /// Not public API — the manager refreshes a live handle from a fresh listing.
  @internal
  void updateFromList(MapLibreOfflineRegionData data) {
    _definition = data.definition;
    _metadata = data.metadata;
    _status = data.status;
  }

  /// Installs the native observer exactly while somebody is listening.
  ///
  /// One observer serves both streams because the engine allows one per region,
  /// so this is driven by whether EITHER has listeners.
  void _syncObserver() {
    if (_deleted) return;
    final wanted =
        (_statusController?.hasListener ?? false) ||
        (_errorController?.hasListener ?? false);
    if (!wanted) {
      _store.setObserver(id);
      return;
    }
    _store.setObserver(
      id,
      onStatus: (status) {
        _status = status;
        _statusController?.add(status);
      },
      onError: (error) => _errorController?.add(error),
    );
  }

  /// Reads progress back without letting a failure escape a state change that
  /// already happened — [resume] has taken effect whether or not the follow-up
  /// read worked.
  Future<void> _refresh() async {
    try {
      await getStatus();
    } on MapLibreOfflineException {
      // Leave [status] as it was; the observer or the next getStatus will
      // correct it.
    }
  }

  void _check() {
    if (_deleted) {
      throw StateError(
        'MapLibreOfflineRegion $id has been deleted; get a fresh list from '
        'MapLibreOfflineManager.instance.listRegions()',
      );
    }
  }

  @override
  String toString() =>
      'MapLibreOfflineRegion($id, $_definition, deleted: $_deleted)';
}
