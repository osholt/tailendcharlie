/// Searching for somewhere to ride to, from the map (#431).
///
/// ## The shape asked for
///
/// > I like the way waze deal with it. Just make a search magnifying glass and
/// > text field you can start searching from that then shows you the options for
/// > solo and group ride, entering a code to recall a planned ride etc.
///
/// So: the destination comes first and the ride is arranged around it. That
/// reverses what the app did — a form asking for scope, coordination mode, display
/// name and an optional route code before it would let a rider anywhere near a
/// map.
///
/// The display name is not asked for at all any more. It is already known from
/// onboarding, and asking again on every ride was the specific complaint in #431.
///
/// ## One thing is not Waze, on purpose
///
/// Waze shows results as you type. Nominatim — the geocoder this app already uses
/// for its destination planning — **forbids that**: its usage policy caps clients
/// at roughly one request a second and says outright that autocomplete must not be
/// implemented against the public API.
///
/// So results arrive when the search is submitted, not per keystroke. It is one
/// extra tap and it is the difference between using a free public service within
/// its terms and abusing it. A live-as-you-type field would need a geocoder we run
/// ourselves, which is a provider decision of the kind `docs/traffic-provider-
/// decision.md` exists to record, and it is not made here.
library;

import 'package:flutter/material.dart';

import '../map/destination_search_field.dart';

import '../../domain/imported_route.dart' show GeoPoint;
import '../../services/road_routing.dart';

/// What a rider picked out of the search.
class DestinationChoice {
  const DestinationChoice({required this.label, required this.point});

  final String label;
  final GeoPoint point;
}

/// The search control standing on the home map.
///
/// Looks like a field and behaves like a button: tapping it opens the search
/// surface rather than raising a keyboard under the map. The map is the thing
/// behind it and pushing it around with a keyboard would undo #426.
class HomeSearchBar extends StatelessWidget {
  const HomeSearchBar({super.key, required this.onTap, this.expanded = false});

  final VoidCallback onTap;

  /// True while the search is open, so the field grows into it (#595).
  final bool expanded;

  /// Shares [DestinationSearchField] with the ride map rather than matching it
  /// by eye, so the two surfaces cannot drift apart (#579).
  @override
  Widget build(BuildContext context) => DestinationSearchField(
    key: const Key('home-search-bar'),
    onTap: onTap,
    expanded: expanded,
  );
}

/// What the search surface returned.
sealed class HomeSearchOutcome {
  const HomeSearchOutcome();
}

/// A place was chosen. That is the whole answer — there is no ride to arrange
/// around it until a rider asks for one (#600).
class HomeSearchDestination extends HomeSearchOutcome {
  const HomeSearchDestination({required this.choice});

  final DestinationChoice choice;
}

/// The rider wants one of the code-driven ways in instead.
class HomeSearchHandoff extends HomeSearchOutcome {
  const HomeSearchHandoff(this.kind);

  final HomeSearchHandoffKind kind;
}

enum HomeSearchHandoffKind {
  /// Join somebody else's ride with their six-digit code.
  joinWithCode,

  /// Recall a route planned on the web planner, by its code.
  plannedRouteCode,

  /// Ride something already on the phone.
  storedRoute,
}

/// The search surface: a field, its results, and the other ways in.
class HomeDestinationSearchSheet extends StatefulWidget {
  const HomeDestinationSearchSheet({
    super.key,
    required this.searchService,
    this.hasPosition = true,
  });

  final DestinationSearchService searchService;

  /// False when the app has no position yet, which makes routing from "here"
  /// impossible. Said in the sheet rather than discovered as a failure after the
  /// rider has chosen solo or group.
  final bool hasPosition;

  static Future<HomeSearchOutcome?> show(
    BuildContext context, {
    required DestinationSearchService searchService,
    bool hasPosition = true,
  }) => showModalBottomSheet<HomeSearchOutcome>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: const Color(0xFF171D25),
    builder: (_) => HomeDestinationSearchSheet(
      searchService: searchService,
      hasPosition: hasPosition,
    ),
  );

  @override
  State<HomeDestinationSearchSheet> createState() =>
      _HomeDestinationSearchSheetState();
}

class _HomeDestinationSearchSheetState
    extends State<HomeDestinationSearchSheet> {
  final _controller = TextEditingController();
  List<DestinationMatch>? _results;
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await widget.searchService.search(query);
      if (!mounted) return;
      setState(() {
        _results = results;
        // Said rather than shown as an empty list: "nothing found" and "not
        // searched yet" look identical otherwise.
        _error = results.isEmpty ? 'Nothing found for “$query”.' : null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _readable(error));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// A rider does not need to read a FormatException.
  static String _readable(Object error) => error is FormatException
      ? error.message
      : 'Could not search just now. Check your connection and try again.';

  /// Picking a place is the whole decision.
  ///
  /// This used to open a second sheet asking solo or group before it would let
  /// a rider anywhere near a route. Solo is the assumption now — a rider who
  /// wants to get somewhere on their own should never be asked about a ride —
  /// and riding with others is offered afterwards, once there is a route to
  /// bring along (#600).
  void _choose(DestinationMatch match) {
    Navigator.of(context).pop(
      HomeSearchDestination(
        choice: DestinationChoice(label: match.label, point: match.point),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: TextField(
              key: const Key('home-search-field'),
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Town, postcode, or a place',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  key: const Key('home-search-submit'),
                  tooltip: 'Search',
                  onPressed: _searching ? null : _search,
                  icon: _searching
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward),
                ),
              ),
            ),
          ),
          if (!widget.hasPosition)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                key: Key('home-search-needs-position'),
                'Tap “Show my location” on the map first — a route has to start '
                'somewhere.',
                style: TextStyle(color: Color(0xFFFFB59A), fontSize: 13),
              ),
            ),
          if (_error case final message?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                key: const Key('home-search-error'),
                message,
                style: const TextStyle(color: Color(0xFFFF8A6B), fontSize: 13),
              ),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (results != null)
                  for (final match in results)
                    ListTile(
                      key: Key('home-search-result-${match.label}'),
                      leading: const Icon(Icons.place_outlined),
                      title: Text(match.label),
                      enabled: widget.hasPosition,
                      onTap: () => _choose(match),
                    ),
                const Divider(height: 12),
                // The code-driven ways in, named in words beside the search
                // rather than behind it. #431 asked for these specifically.
                ListTile(
                  key: const Key('home-search-planned-code'),
                  leading: const Icon(Icons.route_outlined),
                  title: const Text('Recall a planned route'),
                  subtitle: const Text('With a code from the web planner'),
                  onTap: () => Navigator.of(context).pop(
                    const HomeSearchHandoff(
                      HomeSearchHandoffKind.plannedRouteCode,
                    ),
                  ),
                ),
                ListTile(
                  key: const Key('home-search-join-code'),
                  leading: const Icon(Icons.group_add_outlined),
                  title: const Text('Join a ride with a code'),
                  subtitle: const Text('Six digits from whoever is leading'),
                  onTap: () => Navigator.of(context).pop(
                    const HomeSearchHandoff(HomeSearchHandoffKind.joinWithCode),
                  ),
                ),
                ListTile(
                  key: const Key('home-search-stored-route'),
                  leading: const Icon(Icons.bookmark_outline),
                  title: const Text('A route already on this phone'),
                  subtitle: const Text('Previous rides and recorded routes'),
                  onTap: () => Navigator.of(context).pop(
                    const HomeSearchHandoff(HomeSearchHandoffKind.storedRoute),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
