/// Loader for the **experimental** native-core WASM renderer.
///
/// Mirrors `maplibre_gl_loader.dart`, but instead of fetching maplibre-gl-js from
/// a CDN it loads the Emscripten build of `maplibre_flutter_core` (the `.js` glue
/// + sibling `.wasm`) and instantiates the module. Idempotent and memoised.
///
/// The artifact is **not** produced by `flutter build web` — it is a separate
/// Emscripten build (see `docs/experimental-web-core-wasm.md`). If the flag is on
/// but the artifact is missing, this throws a clear, actionable error rather than
/// failing obscurely.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'core_wasm_interop.dart';

/// Where the Emscripten `.js` glue is served from. Override at build time with
/// `--dart-define=MAPLIBRE_WEB_CORE_URL=...`. The default assumes the artifact is
/// copied into the app's web assets for this plugin.
const String coreModuleUrl = String.fromEnvironment(
  'MAPLIBRE_WEB_CORE_URL',
  defaultValue:
      'assets/packages/maplibre_flutter_core/web/maplibre_flutter_core.js',
);

Future<CoreModule>? _moduleFuture;

/// Loads and instantiates the native-core WASM module exactly once; subsequent
/// calls await the same future.
Future<CoreModule> ensureCoreModuleLoaded() => _moduleFuture ??= _load();

Future<CoreModule> _load() async {
  // The consumer may have pre-loaded the glue (e.g. via index.html under a strict
  // CSP); only inject if the factory isn't already present.
  if (!globalContext.has('MaplibreFlutterCore')) {
    await _injectScript(coreModuleUrl);
  }

  if (!globalContext.has('MaplibreFlutterCore')) {
    throw StateError(
      'The experimental native-core web renderer is selected '
      '(--dart-define=MAPLIBRE_WEB_CORE=true), but the Emscripten module was not '
      'found at "$coreModuleUrl". Build the WASM artifact and serve it (or set '
      '--dart-define=MAPLIBRE_WEB_CORE_URL), per docs/experimental-web-core-wasm.md. '
      'The default web renderer (maplibre-gl-js) needs no build step.',
    );
  }

  // MODULARIZE factory → Promise<CoreModule>. Awaiting it runs WASM instantiation
  // (and, in a threaded build, spins up the pthread workers).
  return instantiateCoreModule().toDart;
}

Future<void> _injectScript(String url) async {
  final completer = Completer<void>();
  // Hold the JS callbacks until they fire so the GC can't collect the proxies
  // mid-load (same pitfall the gl-js loader guards against).
  final onLoad = ((JSAny _) {
    if (!completer.isCompleted) completer.complete();
  }).toJS;
  final onError = ((JSAny _) {
    if (!completer.isCompleted) {
      completer.completeError(
        StateError('Failed to load the native-core WASM glue from $url'),
      );
    }
  }).toJS;

  final script = web.HTMLScriptElement()
    ..src = url
    ..async = true
    ..onload = onLoad
    ..onerror = onError;
  web.document.head!.appendChild(script);

  await completer.future;
}
