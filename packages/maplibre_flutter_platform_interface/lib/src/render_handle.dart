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
  const MapLibreRenderHandle({this.providesOwnSemantics = false});

  /// Whether the embedded native view or DOM element already publishes its own
  /// accessibility tree, so the widget must **not** synthesize a second one.
  ///
  /// This is the one accessibility fact that has to cross the interface, and it
  /// could not be a marker interface on the controller or a branch on the
  /// handle's type: **both web tiers hand back an [ElementViewHandle] and only
  /// maplibre-gl-js has canvas ARIA; both SDK tiers hand back a
  /// [PlatformViewHandle] and only the Apple SDK has a rich
  /// `UIAccessibilityContainer`.** The type carries the wrong information, so
  /// the renderer has to state it. It lands on the handle because the widget
  /// already switches there.
  ///
  /// Renderer trivia, not an app-facing ability — hence a defaulted field here
  /// rather than a [MapLibreCapabilities] row.
  final bool providesOwnSemantics;
}

/// Embed via `AndroidView` / `UiKitView` — used by the mobile SDK tier.
@immutable
final class PlatformViewHandle extends MapLibreRenderHandle {
  const PlatformViewHandle({
    required this.viewType,
    this.id,
    this.creationParams,
    super.providesOwnSemantics,
  });

  /// Registered platform-view type name.
  final String viewType;

  /// Optional native-side id for routing later calls to this view.
  final int? id;

  /// Initial configuration handed to the native view at construction time
  /// (e.g. style URI and camera), passed through the platform-view registrar's
  /// `creationParams` — not a data-path method channel (CLAUDE.md §10). The
  /// mobile tier (Android/iOS) serialises [MapOptions] into this map; the
  /// desktop/web tiers leave it null.
  final Map<String, Object?>? creationParams;
}

/// Embed via a `Texture` widget — used by the desktop core tier.
@immutable
final class TextureHandle extends MapLibreRenderHandle {
  /// A [Texture] contributes no semantics of its own — the string "semantic"
  /// does not occur in Flutter's `texture.dart` at all — so no texture tier
  /// sets [providesOwnSemantics] today, and none can while that stays true. It
  /// is accepted here so the sealed family is uniform and the widget's branch
  /// is reachable from a test.
  const TextureHandle({required this.textureId, super.providesOwnSemantics});

  /// Engine texture id registered by the native plugin's texture registrar.
  final int textureId;
}

/// Embed via `HtmlElementView` — used by the web tier.
@immutable
final class ElementViewHandle extends MapLibreRenderHandle {
  const ElementViewHandle({required this.viewType, super.providesOwnSemantics});

  /// Registered platform-view type name for the `<div>` host element.
  final String viewType;
}
