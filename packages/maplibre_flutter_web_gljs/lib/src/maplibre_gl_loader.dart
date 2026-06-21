import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Pinned maplibre-gl-js version. Bump the JS *and* CSS together, and re-check
/// the interop surface in `maplibre_gl_interop.dart` against the new release
/// (CLAUDE.md §10). 5.x is the current stable line; do not jump to a prerelease.
const String maplibreGlVersion = '5.24.0';

const String _jsUrl =
    'https://unpkg.com/maplibre-gl@$maplibreGlVersion/dist/maplibre-gl.js';
const String _cssUrl =
    'https://unpkg.com/maplibre-gl@$maplibreGlVersion/dist/maplibre-gl.css';

Future<void>? _loadFuture;

/// Ensures maplibre-gl-js is loaded: injects its `<script>` and (required) CSS
/// `<link>` into `document.head`, completing once the global `maplibregl`
/// exists — so a [web map][MaplibreMap] can be constructed safely.
///
/// Idempotent and memoised: safe to await from every map creation and across
/// hot reloads (one injection, one shared future). If a consumer already added
/// the script to `index.html` (e.g. a CSP-locked app where runtime injection is
/// blocked), the existing global is detected and reused. The CSS is mandatory —
/// without `maplibre-gl.css` the map's controls/markers/popups render broken.
Future<void> ensureMaplibreLoaded() => _loadFuture ??= _inject();

Future<void> _inject() async {
  final head = web.document.head!;

  // CSS first (required; one tag is enough — memoisation prevents re-entry).
  final link = web.HTMLLinkElement()
    ..rel = 'stylesheet'
    ..href = _cssUrl;
  head.appendChild(link);

  // A consumer may have pre-loaded the script via index.html.
  if (globalContext.has('maplibregl')) return;

  final completer = Completer<void>();
  // Hold the JS callbacks until they fire so the GC can't collect the proxies
  // mid-load (CLAUDE.md §5d). They go out of scope once [completer] resolves.
  final onLoad = ((JSAny _) {
    if (!completer.isCompleted) completer.complete();
  }).toJS;
  final onError = ((JSAny _) {
    if (!completer.isCompleted) {
      completer.completeError(
        StateError('Failed to load maplibre-gl-js from $_jsUrl'),
      );
    }
  }).toJS;

  final script = web.HTMLScriptElement()
    ..src = _jsUrl
    ..async = true
    ..onload = onLoad
    ..onerror = onError;
  head.appendChild(script);

  await completer.future;
}
