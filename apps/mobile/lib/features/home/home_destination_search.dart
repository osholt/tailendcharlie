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
///
/// ## Saved places and history (#937)
///
/// > I would like for the search box to show a history of where I have searched
/// > before, and allow common destinations 'home', 'work' or other custom saved
/// > locations to be available too.
///
/// The empty search offers Home, Work and the rider's own places, then the
/// places they chose before. Typing filters those rows **locally**; it sends
/// nothing, so the rule above is untouched. Both lists stay on the phone
/// (`lib/services/place_memory.dart`).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../map/destination_search_field.dart';
import '../map/place_memory_panel.dart';
import '../map/place_search_sheet.dart';

import '../../domain/imported_route.dart' show GeoPoint;
import '../../domain/ride_plan.dart';
import '../../services/place_memory.dart';
import '../../services/road_routing.dart';

/// What a rider picked out of the search.
class DestinationChoice {
  const DestinationChoice({
    required this.label,
    required this.point,
    this.place,
  });

  final String label;
  final GeoPoint point;

  /// The place as the plan should name it, when the rider picked one they had
  /// named or chosen before ("Home" rather than the address it points at).
  /// Null for a search result, which the plan names from its address.
  final RidePlanPlace? place;
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
  /// Build a loop from the rider's current position.
  circularRide,

  /// Join somebody else's ride with their six-digit code.
  joinWithCode,

  /// Recall a route planned on the web planner, by its code.
  plannedRouteCode,

  /// Ride something already on the phone.
  storedRoute,

  /// The nearest sensible fuel station or charger for the rider's fuel (#951).
  fuelStop,
}

/// The search surface: a field, its results, and the other ways in.
class HomeDestinationSearchSheet extends StatefulWidget {
  const HomeDestinationSearchSheet({
    super.key,
    required this.searchService,
    this.hasPosition = true,
    this.currentPoint,
    this.memory,
    this.fuelSearchLabel,
  });

  final DestinationSearchService searchService;

  /// Where the rider is, when known, so it can be saved as a place of its own.
  /// Never sent anywhere.
  final GeoPoint? currentPoint;

  /// Injected by tests; otherwise the phone's own is opened.
  final PlaceMemory? memory;

  /// "Navigate to fuel" or "Navigate to charger", from the rider's fuel
  /// preference (#951). Null offers neither.
  final String? fuelSearchLabel;

  /// False when the app has no position yet. Said in the sheet, but it no
  /// longer stops anything: a destination can be chosen without a fix, and the
  /// plan's start row then waits for one or takes a place instead (#847).
  final bool hasPosition;

  static Future<HomeSearchOutcome?> show(
    BuildContext context, {
    required DestinationSearchService searchService,
    bool hasPosition = true,
    GeoPoint? currentPoint,
    PlaceMemory? memory,
    String? fuelSearchLabel,
  }) => showModalBottomSheet<HomeSearchOutcome>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: const Color(0xFF171D25),
    builder: (_) => HomeDestinationSearchSheet(
      searchService: searchService,
      hasPosition: hasPosition,
      currentPoint: currentPoint,
      memory: memory,
      fuelSearchLabel: fuelSearchLabel,
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
  PlaceMemory? _memory;
  PlaceMemoryActions? _actions;
  bool _ownsMemory = false;
  String _typed = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTyped);
    unawaited(_openMemory());
  }

  /// Filters the saved places and history as the rider types. Local only: the
  /// search itself still waits for the rider to submit it.
  void _onTyped() {
    if (_controller.text != _typed) setState(() => _typed = _controller.text);
  }

  Future<void> _openMemory() async {
    final injected = widget.memory;
    final memory = injected ?? await PlaceMemory.open();
    if (!mounted) {
      if (injected == null) memory.dispose();
      return;
    }
    setState(() {
      _ownsMemory = injected == null;
      _memory = memory;
      _actions = PlaceMemoryActions(memory: memory, pickPlace: _pickPlace);
    });
  }

  /// Where a saved place should point: the plan's own place search, without
  /// saved places, so choosing never nests.
  Future<RidePlanPlace?> _pickPlace(String title) async {
    final here = widget.currentPoint;
    final choice = await PlaceSearchSheet.show(
      context,
      searchService: widget.searchService,
      title: title,
      offerCurrentLocation: here != null,
      currentPoint: here,
      showPlaceMemory: false,
    );
    return switch (choice) {
      PlaceSearchPlace(:final place) => place,
      PlaceSearchCurrentLocation() when here != null => RidePlanPlace(
        point: here,
        label: currentLocationPlaceLabel,
      ),
      _ => null,
    };
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTyped)
      ..dispose();
    if (_ownsMemory) _memory?.dispose();
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

  /// A saved or recent place is chosen the way a result is, and goes on named
  /// the way the rider named it.
  void _chooseKnown(RidePlanPlace place) => Navigator.of(context).pop(
    HomeSearchDestination(
      choice: DestinationChoice(
        label: place.label,
        point: place.point,
        place: place,
      ),
    ),
  );

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
    // Remembered as the plan will name it. A search that was typed and never
    // chosen from is not a destination and is not kept.
    unawaited(
      _memory?.remember(
        RidePlanPlace.fromSearchResult(label: match.label, point: match.point),
      ),
    );
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
                'Your location is not known yet. Choose a destination anyway: '
                'the route starts from you once you are found, or from a start '
                'you choose.',
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
                      onTap: () => _choose(match),
                      trailing: _actions == null
                          ? null
                          : IconButton(
                              key: Key('home-search-save-${match.label}'),
                              tooltip: 'Save this place',
                              icon: const Icon(Icons.bookmark_add_outlined),
                              onPressed: () => unawaited(
                                _actions!.saveAs(
                                  context,
                                  RidePlanPlace.fromSearchResult(
                                    label: match.label,
                                    point: match.point,
                                  ),
                                ),
                              ),
                            ),
                    ),
                if (_actions case final actions?)
                  PlaceMemoryPanel(
                    actions: actions,
                    query: _typed,
                    keyPrefix: 'home-search',
                    onPickSaved: (saved) => _chooseKnown(saved.toPlanPlace()),
                    onPickRecent: (recent) {
                      unawaited(_memory?.remember(recent.toPlanPlace()));
                      _chooseKnown(recent.toPlanPlace());
                    },
                  ),
                const Divider(height: 12),
                // Searching for "petrol" would ask the geocoder for a place
                // called that. This asks the bundled station map instead, for
                // the rider's own fuel, ranked by distance and price (#951).
                if (widget.fuelSearchLabel case final label?)
                  ListTile(
                    key: const Key('home-search-fuel-stop'),
                    leading: Icon(
                      label == 'Navigate to charger'
                          ? Icons.ev_station_outlined
                          : Icons.local_gas_station_outlined,
                    ),
                    title: Text(label),
                    subtitle: const Text(
                      'Nearby, or ahead on the route you are riding',
                    ),
                    onTap: () => Navigator.of(context).pop(
                      const HomeSearchHandoff(HomeSearchHandoffKind.fuelStop),
                    ),
                  ),
                ListTile(
                  key: const Key('home-search-circular-ride'),
                  leading: const Icon(Icons.roundabout_right_outlined),
                  title: const Text('Create a circular ride'),
                  subtitle: const Text(
                    'Choose distance, direction, stops and road preferences',
                  ),
                  onTap: () => Navigator.of(context).pop(
                    const HomeSearchHandoff(HomeSearchHandoffKind.circularRide),
                  ),
                ),
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
