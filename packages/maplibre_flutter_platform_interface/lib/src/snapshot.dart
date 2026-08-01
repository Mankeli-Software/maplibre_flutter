import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import 'camera.dart';

/// What to render — Apple `MLNMapSnapshotOptions`.
@immutable
class MapSnapshotOptions {
  const MapSnapshotOptions({
    required this.style,
    required this.camera,
    this.size = const Size(512, 512),
    this.pixelRatio = 1,
    this.timeout = const Duration(seconds: 30),
  });

  /// The style to render: a URL, an inline document, or `asset://…` — the same
  /// three forms `MapLibreMap.style` takes.
  final String style;

  /// Where to point it.
  final MapCamera camera;

  /// Output size in LOGICAL points; the pixel dimensions are this times
  /// [pixelRatio], matching how sizes work everywhere else in this API.
  final Size size;

  /// Device pixel ratio. Pass the view's for a snapshot that matches what is on
  /// screen; leave it 1 for a fixed-size export.
  final double pixelRatio;

  /// How long to wait for the tiles.
  ///
  /// A snapshot renders in **Static** mode, which blocks until every tile for
  /// the frame has loaded — that is the point, and it is why this needs a
  /// generous budget rather than a frame's worth. A live map is Continuous and
  /// would happily hand back a half-loaded picture.
  final Duration timeout;
}

/// A rendered snapshot.
@immutable
class MapSnapshot {
  const MapSnapshot({
    required this.pixels,
    required this.width,
    required this.height,
  });

  /// Tightly packed **RGBA**, premultiplied — the layout
  /// `ui.decodeImageFromPixels` and `Image.memory` expect.
  ///
  /// The engine produces BGRA; the conversion happens on the way out so callers
  /// never have to know. (Getting that backwards is not hypothetical: it had
  /// been wrong in this repo's own test helper for months, invisible because
  /// every test colour had R equal to B.)
  final Uint8List pixels;

  /// Size in DEVICE pixels.
  final int width;
  final int height;
}
