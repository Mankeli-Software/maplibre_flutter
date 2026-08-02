import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// Process-wide map configuration — **call before building your first
/// [MapLibreMap]**.
///
/// Named and shaped after Apple's `MLNSettings`, which is a static
/// configure-before-first-map surface for the same reason ours is: mbgl caches
/// file sources by `(type, ResourceOptions)`, so a per-map cache path or API
/// key mints a SECOND cache database and a second connection pool per distinct
/// value. There is no per-map form of this and there should not be.
///
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   final dir = await getApplicationSupportDirectory();
///   MapLibreSettings.configure(
///     cachePath: '${dir.path}/maplibre/tiles.db',
///     apiKey: const String.fromEnvironment('MAPLIBRE_KEY'),
///   );
///   runApp(const MyApp());
/// }
/// ```
abstract final class MapLibreSettings {
  /// Configures the tile cache and the API key.
  ///
  /// Returns false when the call was too late (a map already exists) or the
  /// renderer has no configurable cache — and in that case **nothing changed**.
  /// It is a return value rather than a throw because "this tier has no cache"
  /// is a normal condition, but it should not be ignored: silently doing
  /// nothing is how an app ships believing it has a cache.
  ///
  /// [cachePath] is a SQLite database file; its parent directories are created.
  /// **mbgl's own default is `:memory:`**, so without this every app restart
  /// re-downloads every tile. Passing a real path is not a tuning knob, it is
  /// the difference between having a tile cache and not having one. Put it
  /// somewhere the OS will not purge without warning — an application-support
  /// directory rather than a cache directory, if losing it would be expensive.
  ///
  /// [maximumCacheBytes] null keeps mbgl's default (50 MB).
  ///
  /// [apiKey] is how MapTiler, Mapbox and other keyed providers authenticate —
  /// **but only together with [tileServer]**. The engine reads the key on
  /// exactly one path, rewriting a URL under the configured scheme, and the
  /// default configuration declares that it requires no key and names no
  /// parameter for it. A key passed on its own is stored and never read; the
  /// two are one setting wearing two names.
  ///
  /// [tileServer] selects those URL conventions. Pass it whenever the style is
  /// a short scheme URL (`maptiler://maps/streets`) or whenever [apiKey] is set.
  /// An app whose style URL is a plain `https://…` with the key already in the
  /// query string needs neither — that path is left untouched — though it also
  /// never reaches the sprite, glyph and tile sub-requests, whose URLs come out
  /// of the style document rather than from the app.
  ///
  /// Neither adds an `Authorization` header; see the package README for
  /// providers that need one.
  static bool configure({
    String? cachePath,
    int? maximumCacheBytes,
    String? apiKey,
    MapLibreTileServer? tileServer,
  }) => MapLibreFlutterPlatform.instance.configureResources(
    cachePath: cachePath,
    maximumCacheBytes: maximumCacheBytes,
    apiKey: apiKey,
    tileServer: tileServer,
  );

  /// Extra HTTP request headers, scoped by URL prefix — how an app
  /// authenticates to a provider that wants an `Authorization` header rather
  /// than a key in the query string.
  ///
  /// ```dart
  /// MapLibreSettings.setHttpHeaders({
  ///   'https://tiles.example.com/': {'Authorization': 'Bearer $token'},
  /// });
  /// ```
  ///
  /// REPLACE-ALL, which is also the whole token-rotation story: call it again
  /// with the new value. `{}` clears. Returns false if a header name or value
  /// is not sendable (a control character, or a `:` in a name) or the tier
  /// cannot do it — and then **nothing changed**, because half-applied auth is
  /// worse than a rejected change.
  ///
  /// **Callable at any time**, unlike [configure]. Headers are not baked into
  /// the engine's file sources, so they are read fresh as each request is
  /// built — which is the only way an hour-long bearer token is usable at all.
  ///
  /// **The URL prefix is required, and that is a deliberate divergence from
  /// upstream.** Apple applies its headers to a whole `NSURLSession` and
  /// Android to the whole OkHttp client, so both send your credential to every
  /// host a style names — and a style routinely names hosts you do not own, for
  /// sprites, glyphs, or a basemap from another vendor. Scoping is what stops
  /// the token leaking to them. If you genuinely want every host, pass
  /// `'https://'`: explicit, greppable, and your call.
  ///
  /// Matching is a case-sensitive prefix over the whole URL. Every matching
  /// rule contributes; a later rule wins a name an earlier one also set. Your
  /// headers are added last but never displace the engine's own — the
  /// conditional-GET headers it uses for caching, and its `User-Agent`.
  static bool setHttpHeaders(
    Map<String, Map<String, String>> rulesByUrlPrefix,
  ) => MapLibreFlutterPlatform.instance.setHttpHeaders(rulesByUrlPrefix);

  /// The cache path actually in force, so an app can log what it got rather
  /// than what it asked for.
  ///
  /// Null on a renderer with no cache; `':memory:'` means the cache is not
  /// persistent — which is what you get if [configure] was never called.
  static String? get cachePath => MapLibreFlutterPlatform.instance.cachePath;
}
