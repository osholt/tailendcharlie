import 'package:flutter/material.dart';

/// The way to a destination, in the one place a rider looks for it.
///
/// Free roam and a created-but-unstarted ride are the same map with different
/// capabilities, and they used to ask for a destination in different places:
/// free roam through a search field standing on the map, a created ride through
/// an `add_road` icon button in the app bar. Same intent, two affordances, two
/// positions — so a rider who had just used one had to find the other (#579).
///
/// The two do **not** do the same thing, and deliberately still do not. Free
/// roam's search creates or plans a ride around a destination; the ride's adds
/// a destination to the route already loaded. What they now share is where they
/// are and what they look like, so the difference is in the outcome rather than
/// in having to hunt for the control.
///
/// One widget rather than two matching ones, because two matching ones drift.
class DestinationSearchField extends StatelessWidget {
  const DestinationSearchField({
    super.key,
    required this.onTap,
    this.expanded = false,
  });

  final VoidCallback onTap;

  /// Grows to the full width of the bar while a search is open.
  ///
  /// The field is the way in, so opening one should look like the field
  /// growing into it rather than an unrelated sheet appearing over the top
  /// (#595). The host collapses its other actions at the same time; this only
  /// says how the field itself should read.
  final bool expanded;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xF21A2029),
    borderRadius: BorderRadius.circular(expanded ? 10 : 14),
    elevation: expanded ? 2 : 6,
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(Icons.search, color: Color(0xFFB7C0CC)),
            SizedBox(width: 10),
            // Words as well as the glass. A bare magnifying glass is the
            // failure #306 was raised over.
            Flexible(
              child: Text(
                'Where to?',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Color(0xFFB7C0CC),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
