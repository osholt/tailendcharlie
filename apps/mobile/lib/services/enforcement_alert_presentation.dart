/// How an enforcement warning is shown: announce briefly, then hold (#446).
///
/// ## Three goes at this, and why the third is different in kind
///
/// #107 asked for a warning unmissable through a tinted visor, and got a
/// full-screen takeover. Armed a mile out, that took the map away for the whole
/// approach.
///
/// #418 unpinned it from the screen and bounded it by its content — and the
/// content was a 76px icon, a 44px title and a 68px distance stacked up, which on
/// a real phone still came to over 80% of the screen. Shrunk again, it reached
/// about a third of a landscape screen. Each round traded a little size for the
/// same argument, because *panel* was the wrong shape.
///
/// The third answer separates the two jobs the panel was doing badly at once:
///
/// - **Announcing** that a camera is ahead. That is an event. It needs to be loud,
///   it needs to be brief, and once it has been read it is finished.
/// - **Reminding** the rider they are still on the approach. That is a state. It
///   has to persist for as long as a mile, so it cannot occupy space.
///
/// So: a bubble for [enforcementBubbleLife], then a border for the rest of the
/// approach. The border is the persistent state and the bubble is the
/// announcement; the bubble stays clear of the rider marker and navigation
/// controls.
///
/// A fixed life rather than one tied to distance, as asked for. It also removes
/// the dismiss logic: nothing has to decide when the announcement has been read,
/// because ten seconds is long enough to read it and short enough not to matter.
library;

/// How long the bubble is shown before it gives way to the border alone.
///
/// Ten seconds, fixed, and not a function of distance: an announcement that
/// lingers for the mile it takes to reach the camera is a panel again.
const enforcementBubbleLife = Duration(seconds: 10);

/// The border that holds for the rest of the approach.
///
/// Wide enough to read as an alarm rather than a highlight. It is doing the work
/// the full screen used to, and it is the whole of the warning after ten seconds,
/// so it is not a decoration.
const enforcementBorderWidth = 7.0;

/// Keeps the complete stroke inside the drawable viewport.
///
/// A rounded display clips its extreme corners before Flutter's rectangular
/// viewport does. Drawing against that rectangle made the red arc disappear
/// under the physical mask even though the straight edges were visible.
const enforcementBorderInset = 7.0;

/// Curves the persistent alarm inside rounded phone screens.
///
/// The stroke is painted inside the viewport, while this radius keeps its
/// corners visible on phones whose display mask removes the square corners.
const enforcementBorderRadius = 40.0;

/// The bubble never grows past this, whatever the screen.
///
/// A notification, not a banner: on a landscape phone a full-width surface reads
/// as a takeover even when it is short.
const enforcementBubbleMaxWidth = 360.0;

/// How much the speed sign and the rider's own speed grow on an approach.
///
/// The limit is the one number that matters at a camera, and the reported problem
/// was not that it was absent but that the change was not noticeable. Half again
/// is the smallest step that reads as deliberate at a glance.
const enforcementEmphasisScale = 1.5;

/// What is on screen for an enforcement warning.
enum EnforcementAlertStage {
  /// The bubble, and the border behind it.
  announcing,

  /// The border alone, for the rest of the approach.
  holding,

  /// Nothing: no warning armed, or the rider dismissed it.
  none,
}

/// The stage for a warning armed [sinceArmed] ago.
///
/// [armed] is false once the detector stops returning the hazard, which it does
/// when the hazard is behind the rider — so passing the camera ends both the
/// bubble and the border without anything having to decide it here.
EnforcementAlertStage enforcementAlertStage({
  required bool armed,
  required bool dismissed,
  required Duration sinceArmed,
}) {
  if (!armed || dismissed) return EnforcementAlertStage.none;
  return sinceArmed < enforcementBubbleLife
      ? EnforcementAlertStage.announcing
      : EnforcementAlertStage.holding;
}

/// Whether the speed sign and the rider's own speed are enlarged.
///
/// Deliberately **not** a function of the bubble's ten seconds. The emphasis is
/// there for the whole approach, because the rider will look down *after* the
/// announcement rather than during it — and a sign that shrank again ten seconds
/// before the camera would be emphasis exactly where it was least useful.
bool enforcementEmphasisApplies({
  required bool armed,
  required bool dismissed,
}) => armed && !dismissed;
