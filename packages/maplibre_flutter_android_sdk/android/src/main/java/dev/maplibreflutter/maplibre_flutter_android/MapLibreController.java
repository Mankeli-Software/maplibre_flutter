package dev.maplibreflutter.maplibre_flutter_android;

import android.os.Handler;
import android.os.Looper;
import androidx.annotation.Keep;
import org.maplibre.android.camera.CameraPosition;
import org.maplibre.android.camera.CameraUpdate;
import org.maplibre.android.camera.CameraUpdateFactory;
import org.maplibre.android.geometry.LatLng;
import org.maplibre.android.maps.MapLibreMap;

/**
 * Thin, jnigen-bound controller for one live map (CLAUDE.md §5d: own a small
 * shim rather than binding the whole SDK from Dart).
 *
 * <p>Written in <b>Java</b> on purpose: jnigen 0.16's summarizer cannot read the
 * Kotlin 2.3 metadata emitted by AGP 9's built-in Kotlin, so the two classes we
 * actually bind ({@link MapRegistry} + this) are Java. The rest of the module
 * stays Kotlin.
 *
 * <p>The MapLibre SDK is <b>main-thread only</b>, but Dart calls these methods
 * from the Dart isolate thread, so every command marshals onto the main looper.
 * The camera is cached from an idle listener so the getters are a cheap,
 * thread-safe read with no round-trip.
 *
 * <p>The public surface is primitives + {@link String} only, so jnigen leaves
 * referenced {@code org.maplibre.*} types opaque ({@link #attachMap} takes one,
 * but Dart never calls it — {@code MapLibrePlatformView} does, on the main
 * thread). Everything reachable from Dart is {@code @Keep} so R8 cannot strip it.
 */
@Keep
public class MapLibreController {
  private final Handler main = new Handler(Looper.getMainLooper());

  private volatile MapLibreMap map;

  private volatile double lat;
  private volatile double lng;
  private volatile double zoom;
  private volatile double bearing;
  private volatile double pitch;

  /** Called on the main thread by {@code MapLibrePlatformView} once the map exists. */
  public void attachMap(MapLibreMap m) {
    map = m;
    cache(m.getCameraPosition());
    m.addOnCameraIdleListener(
        () -> {
          MapLibreMap current = map;
          if (current != null) {
            cache(current.getCameraPosition());
          }
        });
  }

  private void cache(CameraPosition c) {
    if (c.target != null) {
      lat = c.target.getLatitude();
      lng = c.target.getLongitude();
    }
    zoom = c.zoom;
    bearing = c.bearing;
    pitch = c.tilt;
  }

  @Keep
  public boolean isReady() {
    return map != null;
  }

  @Keep
  public double getLat() {
    return lat;
  }

  @Keep
  public double getLng() {
    return lng;
  }

  @Keep
  public double getZoom() {
    return zoom;
  }

  @Keep
  public double getBearing() {
    return bearing;
  }

  @Keep
  public double getPitch() {
    return pitch;
  }

  @Keep
  public void moveCamera(
      double lat, double lng, double zoom, double bearing, double pitch, long durationMs) {
    main.post(
        () -> {
          MapLibreMap m = map;
          if (m == null) {
            return;
          }
          CameraPosition pos =
              new CameraPosition.Builder()
                  .target(new LatLng(lat, lng))
                  .zoom(zoom)
                  .bearing(bearing)
                  .tilt(pitch)
                  .build();
          CameraUpdate update = CameraUpdateFactory.newCameraPosition(pos);
          if (durationMs > 0) {
            m.animateCamera(update, (int) durationMs);
          } else {
            m.moveCamera(update);
          }
        });
  }

  @Keep
  public void setStyle(String uri) {
    main.post(
        () -> {
          MapLibreMap m = map;
          if (m != null) {
            m.setStyle(uri);
          }
        });
  }
}
