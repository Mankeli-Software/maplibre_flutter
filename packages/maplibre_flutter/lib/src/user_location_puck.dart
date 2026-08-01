import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';

/// The blue dot, its accuracy halo and its direction cone.
///
/// A plain widget, drawn through the ordinary marker overlay — so it inherits
/// the projection correlation that keeps markers from swimming during movement,
/// and an app can replace it wholesale with its own via
/// `MapLibreMap.userLocationBuilder`.
class UserLocationPuck extends StatelessWidget {
  const UserLocationPuck({
    required this.location,
    required this.metresPerPixel,
    super.key,
    this.color = const Color(0xFF1E88E5),
  });

  /// Where the user is.
  final MapUserLocation location;

  /// Ground resolution at the puck, so the accuracy halo can be drawn at its
  /// TRUE size.
  ///
  /// An accuracy circle drawn at a fixed pixel radius is a lie: 30 m of
  /// uncertainty covers most of the screen at street level and less than a pixel
  /// at country level, and drawing it the same either way tells the user
  /// nothing.
  final double metresPerPixel;

  /// The puck's colour; the halo is a translucent version of it.
  final Color color;

  @override
  Widget build(BuildContext context) {
    final accuracy = location.accuracy;
    final haloRadius = accuracy == null || metresPerPixel <= 0
        ? 0.0
        : (accuracy / metresPerPixel).clamp(0.0, 400.0);
    // The direction the cone points: course if we have it (where they are
    // GOING), else heading (where the device is POINTING).
    final direction = location.course ?? location.heading;
    final size = math.max(haloRadius * 2, 44.0);

    return IgnorePointer(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _PuckPainter(
            color: color,
            haloRadius: haloRadius,
            directionDegrees: direction,
          ),
        ),
      ),
    );
  }
}

class _PuckPainter extends CustomPainter {
  const _PuckPainter({
    required this.color,
    required this.haloRadius,
    required this.directionDegrees,
  });

  final Color color;
  final double haloRadius;
  final double? directionDegrees;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);

    if (haloRadius > 1) {
      canvas
        ..drawCircle(
          centre,
          haloRadius,
          Paint()..color = color.withValues(alpha: 0.15),
        )
        ..drawCircle(
          centre,
          haloRadius,
          Paint()
            ..color = color.withValues(alpha: 0.35)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
    }

    if (directionDegrees != null) {
      // Clockwise from NORTH, and north is up — so subtract 90° to get into
      // canvas angles, which start at east. Getting this wrong points the cone
      // 90° off, and a cone that is merely rotated still looks plausible, which
      // is why the test asserts an absolute direction rather than a round trip.
      final radians = (directionDegrees! - 90) * math.pi / 180;
      const spread = 0.5;
      const length = 26.0;
      final path = Path()
        ..moveTo(centre.dx, centre.dy)
        ..lineTo(
          centre.dx + math.cos(radians - spread) * length,
          centre.dy + math.sin(radians - spread) * length,
        )
        ..lineTo(
          centre.dx + math.cos(radians + spread) * length,
          centre.dy + math.sin(radians + spread) * length,
        )
        ..close();
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.45));
    }

    canvas
      ..drawCircle(centre, 9, Paint()..color = const Color(0xFFFFFFFF))
      ..drawCircle(centre, 7, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_PuckPainter old) =>
      old.color != color ||
      old.haloRadius != haloRadius ||
      old.directionDegrees != directionDegrees;
}
