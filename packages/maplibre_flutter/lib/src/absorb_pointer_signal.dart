import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Stops mouse-wheel and trackpad scroll events reaching whatever is beneath —
/// the pointer-signal counterpart of [AbsorbPointer].
///
/// **Why you need it over a map.** A pointer signal is offered to every
/// [Listener] under the cursor, and Flutter arbitrates with
/// `PointerSignalResolver`: the first widget to *register* wins, innermost
/// first. Absorbing taps does nothing here — a `Container`, an `IconButton`, a
/// `DropdownButton` menu all take the pointer but register no signal handler,
/// so a scroll over them still reaches the map underneath and zooms it. That is
/// the whole bug this exists to fix:
///
/// ```dart
/// Stack(
///   children: [
///     MapLibreMap(controller: controller, style: style),
///     Positioned(
///       top: 16,
///       left: 16,
///       // Without this, scrolling anywhere over the panel zooms the map.
///       child: AbsorbPointerSignal(child: MyControlPanel()),
///     ),
///   ],
/// )
/// ```
///
/// It does NOT block taps, drags or hovers — only pointer signals — so children
/// stay fully interactive. A [Scrollable] child keeps working too: it sits
/// inside this widget, so it registers first and wins.
class AbsorbPointerSignal extends StatelessWidget {
  const AbsorbPointerSignal({
    required this.child,
    super.key,
    this.absorbing = true,
  });

  final Widget child;

  /// Set false to let signals through — useful for a panel that is only
  /// sometimes on screen, without rebuilding the subtree shape.
  final bool absorbing;

  @override
  Widget build(BuildContext context) {
    if (!absorbing) return child;
    return Listener(
      // Opaque, so the whole box claims the signal rather than only the parts
      // where a child happens to paint. A gap between two buttons in a panel is
      // still "over the panel" to the person using it.
      behavior: HitTestBehavior.opaque,
      onPointerSignal: (event) {
        // Registering IS the absorption: the resolver hands the event to the
        // first registrant, and doing nothing with it is exactly the point.
        GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
      },
      child: child,
    );
  }
}
