import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart';

/// When the map speaks unprompted.
enum MapSemanticsAnnouncements {
  /// Never. The value is still readable on demand; nothing interrupts.
  never,

  /// Only after an assistive-technology or keyboard action — Apple's exact
  /// model, and the default.
  ///
  /// Apple arms a pending flag inside `accessibilityScaleBy:` and consumes it
  /// in `cameraDidChangeAnimated:`, so a swipe-to-zoom gets feedback and a
  /// two-finger pan gets none. That restraint is the whole design: without it a
  /// user has no confirmation their swipe did anything; with it on every camera
  /// change, TalkBack and VoiceOver are flooded and each utterance interrupts
  /// the last.
  accessibilityActions,

  /// After every camera settle. Almost always too much; offered because a
  /// kiosk or a guided tour is the case where it is not.
  always,
}

/// Speaks a message through whichever mechanism the platform actually supports.
///
/// **The platform split is real and encapsulated here so app authors never
/// write it.** Android has no announcement channel at all any more:
/// `AccessibilityBridge` sets `NO_ANNOUNCE` unconditionally because Android 16
/// deprecated `announceForAccessibility`/`TYPE_ANNOUNCEMENT` outright — *"these
/// can create inconsistent user experiences for users of TalkBack"* — and its
/// documented replacement is a live region, which Flutter lowers to
/// `TYPE_WINDOW_CONTENT_CHANGED`.
///
/// **Nothing may be announced that cannot also be read.** An announcement is
/// transient and cannot be reviewed at all on a refreshable braille display, so
/// every announced fact must also appear in the map's `value` or in
/// `MapLibreFeatureList`. Speech is a courtesy layer over a readable one, never
/// the only copy.
abstract final class MapLibreSemanticsAnnouncer {
  /// True where the platform has a real announcement channel.
  static bool isSupported(BuildContext context) =>
      MediaQuery.supportsAnnounceOf(context);

  /// Speaks [message], or returns false if this platform cannot and the caller
  /// must fall back to mutating a live region's **label**.
  ///
  /// The label, specifically: on Android and on web a live region fires only on
  /// a changed *label*, so putting the summary in a node's `value` and marking
  /// it live announces nothing at all — a naive implementation that looks
  /// entirely correct and is silent.
  static bool announce(
    BuildContext context,
    String message, {
    Assertiveness assertiveness = Assertiveness.polite,
  }) {
    if (!isSupported(context)) return false;
    // Never `SemanticsService.announce`, which is deprecated as incompatible
    // with multiple windows.
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
      assertiveness: assertiveness,
    );
    return true;
  }

  /// A short pulse confirming an assistive-technology or keyboard camera step.
  ///
  /// Non-visual and non-auditory, so it serves deaf-blind and cognitive-load
  /// users at the same time — and it fills the gap the announcement model
  /// leaves, where a user has no feedback that their swipe did anything.
  static void confirmStep() => HapticFeedback.selectionClick();

  /// A heavier pulse for a step that was **refused** — the camera is already at
  /// its minimum or maximum zoom, or against its bounds.
  ///
  /// Distinct from [confirmStep] on purpose: "nothing happened because you are
  /// at the edge" and "nothing happened because it is broken" are the same
  /// silence otherwise, and the first is the one a user can act on.
  static void refuseStep() => HapticFeedback.heavyImpact();
}
