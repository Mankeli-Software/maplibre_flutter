import 'package:flutter/foundation.dart';

/// How a created map should be embedded in the Flutter tree.
///
/// This is the single place where the rendering split (CLAUDE.md §3) leaks
/// across the interface: mobile SDKs hand back a native view to embed, the
/// desktop core renders off-screen and hands back a texture id, and web hands
/// back an element view. The app-facing widget switches on this; the public API
/// stays identical everywhere.
@immutable
sealed class MapLibreRenderHandle {
  const MapLibreRenderHandle();
}

/// Embed via `AndroidView` / `UiKitView` — used by the mobile SDK tier.
@immutable
final class PlatformViewHandle extends MapLibreRenderHandle {
  const PlatformViewHandle({required this.viewType, this.id});

  /// Registered platform-view type name.
  final String viewType;

  /// Optional native-side id for routing later calls to this view.
  final int? id;
}

/// Embed via a `Texture` widget — used by the desktop core tier.
@immutable
final class TextureHandle extends MapLibreRenderHandle {
  const TextureHandle({required this.textureId});

  /// Engine texture id registered by the native plugin's texture registrar.
  final int textureId;
}

/// Embed via `HtmlElementView` — used by the web tier.
@immutable
final class ElementViewHandle extends MapLibreRenderHandle {
  const ElementViewHandle({required this.viewType});

  /// Registered platform-view type name for the `<div>` host element.
  final String viewType;
}
