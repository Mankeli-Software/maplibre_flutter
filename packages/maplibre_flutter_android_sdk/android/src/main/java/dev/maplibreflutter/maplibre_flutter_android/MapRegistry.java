package dev.maplibreflutter.maplibre_flutter_android;

import androidx.annotation.Keep;
import java.util.HashMap;
import java.util.Map;

/**
 * Maps the Dart-generated {@code mapId} to its {@link MapLibreController}.
 *
 * <p>The Dart side mints a {@code mapId}, passes it in the {@code AndroidView}
 * creation params, and later looks the controller up here over jnigen — so
 * control flows Dart → jni → controller with no data-path method channel
 * (CLAUDE.md §10) and without coordinating the engine's platform-view id.
 *
 * <p>Java, not Kotlin — see {@link MapLibreController} for why.
 */
@Keep
public final class MapRegistry {
  private MapRegistry() {}

  private static final Map<Integer, MapLibreController> CONTROLLERS = new HashMap<>();

  /** Create and register a controller for {@code mapId} (called from the view factory). */
  @Keep
  public static synchronized MapLibreController register(int mapId) {
    MapLibreController controller = new MapLibreController();
    CONTROLLERS.put(mapId, controller);
    return controller;
  }

  /** The controller for {@code mapId}, or null if the view does not exist (yet). */
  @Keep
  public static synchronized MapLibreController get(int mapId) {
    return CONTROLLERS.get(mapId);
  }

  @Keep
  public static synchronized void unregister(int mapId) {
    CONTROLLERS.remove(mapId);
  }
}
