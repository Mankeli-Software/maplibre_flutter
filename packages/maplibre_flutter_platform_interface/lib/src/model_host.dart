import 'lat_lng.dart';

/// A 3D model anchored to a geographic point.
///
/// EXPERIMENTAL. The renderer draws the mesh inside the map engine, so it
/// depth-occludes against 3D buildings and other models rather than floating over
/// them like a widget overlay.
///
/// The engine's built-in geometry shader is unlit — texture times tint, no normals
/// and no lights — so **bake lighting into the texture** and expect flat shading.
/// Animation is rigid-body only (position/heading/spin); skinned or morph
/// animation is not expressible.
class MapLibreModel {
  const MapLibreModel({
    required this.id,
    required this.assetPath,
    required this.point,
    this.scale = 1,
    this.headingDegrees = 0,
    this.spinDegreesPerSecond = 0,
    this.elevationMetres = 0,
  });

  /// Identifies this model; re-using an id replaces the previous model.
  final String id;

  /// Filesystem path to a binary glTF (`.glb`).
  ///
  /// Must be a real file path, not a Flutter asset key — the engine reads it
  /// natively. Copy bundled assets out to a temp file first.
  final String assetPath;

  /// Where the model's origin sits on the map.
  final LatLng point;

  /// Multiplies the model's own units. 1.0 renders a glTF authored in metres at
  /// life size, and the model then keeps its ground footprint across zooms.
  ///
  /// Many models (Sketchfab exports especially) are NOT authored in metres — check
  /// the loaded bounding box against the real object rather than assuming 1.0.
  final double scale;

  /// Yaws the model clockwise from north.
  ///
  /// glTF's convention is that -Z is "forward", which this treats as facing north
  /// at 0 — but plenty of models ignore that convention, so expect to set this
  /// per asset.
  final double headingDegrees;

  /// Lifts the model off the ground, in metres.
  ///
  /// A model whose base sits exactly at ground level is coplanar with the
  /// basemap's own geometry and z-fights — the map visibly bleeds through the
  /// model. A few centimetres resolves it.
  final double elevationMetres;

  /// Adds a continuous yaw, in degrees per second. 0 leaves the model static.
  ///
  /// A non-zero value makes the map render continuously while the model is alive,
  /// which costs power — prefer 0 unless something is actually meant to spin.
  final double spinDegreesPerSecond;

  /// Whether only the PLACEMENT differs, so this model can be moved in place
  /// rather than reloaded.
  ///
  /// [assetPath] is excluded because a different mesh has to be re-read, and
  /// [spinDegreesPerSecond] because the spin clock starts when the model is
  /// created — changing it in place would make the rotation jump.
  bool isSamePlacementSourceAs(MapLibreModel other) =>
      id == other.id &&
      assetPath == other.assetPath &&
      spinDegreesPerSecond == other.spinDegreesPerSecond;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MapLibreModel &&
          other.id == id &&
          other.assetPath == assetPath &&
          other.point == point &&
          other.scale == scale &&
          other.headingDegrees == headingDegrees &&
          other.elevationMetres == elevationMetres &&
          other.spinDegreesPerSecond == spinDegreesPerSecond;

  @override
  int get hashCode => Object.hash(
    id,
    assetPath,
    point,
    scale,
    headingDegrees,
    elevationMetres,
    spinDegreesPerSecond,
  );
}

/// Optional capability: a platform controller that can draw 3D models inside the
/// map engine.
///
/// Implemented by the `mbgl-core` tiers. The `MapLibreMap` widget feature-detects
/// it with `is` (exactly like `MapLibreMapProjector`), so a controller without it
/// simply draws no models rather than throwing, and this never ripples into every
/// platform implementation.
abstract interface class MapLibreModelHost {
  /// Adds or replaces [model]. Throws [ArgumentError] if the file cannot be
  /// loaded, with the native reason.
  ///
  /// The `.glb` is parsed synchronously, so this blocks for a file read; call it
  /// off the first frame for large models.
  void addModel(MapLibreModel model);

  /// Moves or re-orients an existing model WITHOUT re-uploading its geometry —
  /// the way to animate one along a path. A no-op if [model]'s id is unknown.
  ///
  /// [MapLibreModel.assetPath] is ignored here; only the placement is applied.
  void updateModel(MapLibreModel model);

  /// How many drawables one instance of the model at [assetPath] costs, or null
  /// if it is not loaded. Lets callers report real draw-call counts.
  int? modelPartCount(String assetPath);

  /// Frames the renderer has actually published since creation, or null if the
  /// tier cannot report it.
  ///
  /// Difference it over time for the MAP's frame rate. Measuring with a Flutter
  /// `Ticker` instead reports Flutter's vsync, which stays pinned at the display
  /// rate however far behind the map falls — the map is a texture, so Flutter has
  /// nothing to wait for.
  int? get renderedFrameCount;

  /// Removes the model with [id]. A no-op if there is none.
  void removeModel(String id);
}
