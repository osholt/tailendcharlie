import 'package:flutter/material.dart';

/// The ride actions, as a bar standing on the map (#426).
///
/// ## What this replaces
///
/// #405 asked for the app to open on the map. #407 delivered a map *behind* a
/// full-screen panel: a brand mark, a heading, a paragraph, four buttons, two
/// links and a footer, over a gradient scrim covering the whole screen. From the
/// ride:
///
/// > This isn't really what I meant by map view to start the ride. It should be
/// > usable for free roam navigation rather than blocking the whole screen.
///
/// and then, when it was still there:
///
/// > To be clear I don't want the start screen at all. I want the selection of
/// > starting a ride to happen from the map view.
///
/// So the panel is gone rather than shrunk. The map is the surface — pannable,
/// zoomable, readable, with a position on it — and starting a ride is one bar at
/// the bottom of it.
///
/// ## Why a bar and not a sheet
///
/// A sheet has to be summoned, and the two things a rider does here are start a
/// ride and join one. Putting those behind a gesture to keep the map clean would
/// trade the reported problem for a worse one: the map was never the thing in the
/// way.
///
/// Everything that is *not* one of those two — the simulator, recording a route,
/// previous rides, the build identity — is behind [Icons.more_horiz], because each
/// is used occasionally and none is worth a permanent strip of map.
class HomeRideActions extends StatelessWidget {
  const HomeRideActions({
    super.key,
    required this.onCreate,
    required this.onJoin,
    required this.onMore,
    this.enabled = true,
  });

  final VoidCallback? onCreate;
  final VoidCallback? onJoin;
  final VoidCallback onMore;

  /// False while the controller is busy or a restoration is still being retried,
  /// which is the same gate the old panel used.
  final bool enabled;

  /// Height the map should keep clear at the bottom.
  ///
  /// A constant rather than a measurement because the map's own controls have to
  /// be placed above it, and a layout that measured this would need a frame to
  /// settle before the map knew where to put them.
  static const reservedHeight = 84.0;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('home-ride-actions'),
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
    decoration: const BoxDecoration(
      // Opaque behind the buttons only. The whole-screen gradient that used to
      // carry legibility is what made the map wallpaper.
      color: Color(0xF21A2029),
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      boxShadow: [
        BoxShadow(
          color: Color(0x66000000),
          blurRadius: 14,
          offset: Offset(0, -4),
        ),
      ],
    ),
    child: SafeArea(
      top: false,
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: FilledButton.icon(
              key: const Key('home-create-ride'),
              onPressed: enabled ? onCreate : null,
              icon: const Icon(Icons.add_road),
              label: const Text('Create a ride'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: OutlinedButton.icon(
              key: const Key('home-join-ride'),
              onPressed: enabled ? onJoin : null,
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('Join a ride'),
            ),
          ),
          const SizedBox(width: 4),
          // A word, not a bare icon. #306 was raised because the only way to
          // find a feature was an unlabelled icon, and moving the occasional
          // actions behind `more_horiz` alone would have reintroduced exactly
          // that — an overflow nobody can read is not reachable.
          TextButton(
            key: const Key('home-more-actions'),
            onPressed: onMore,
            child: const Text('More'),
          ),
        ],
      ),
    ),
  );
}
