/// Loader for the native-core WASM renderer (the default web engine).
///
/// Loads the Emscripten build of `maplibre_flutter_core` (the `.js` glue +
/// sibling `.wasm`) and instantiates the module. Idempotent and memoised.
///
/// The artifact is a separate Emscripten build (see
/// `docs/experimental-web-core-wasm.md`); if it is missing from the served assets
/// this throws a clear, actionable error rather than failing obscurely.
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
      'The native-core web renderer (the default) needs its Emscripten module, '
      'but it was not found at "$coreModuleUrl". Build the WASM artifact and serve '
      'it with the required COOP/COEP headers (or set '
      '--dart-define=MAPLIBRE_WEB_CORE_URL), per docs/experimental-web-core-wasm.md. '
      'To render with maplibre-gl-js instead (no build step, no special headers), '
      'add the maplibre_flutter_web_gljs package to your app.',
    );
  }

  // MODULARIZE factory → Promise<CoreModule>. Awaiting it runs WASM instantiation
  // (and, in a threaded build, spins up the pthread workers). We pass
  // mainScriptUrlOrBlob so Emscripten can locate its worker/.wasm even though the
  // glue script was injected dynamically (no document.currentScript).
  return instantiateCoreModule(
    CoreModuleArg(mainScriptUrlOrBlob: coreModuleUrl),
  ).toDart;
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
