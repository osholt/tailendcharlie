/// Choosing one place on a plan: its start, a stop, or its destination (#847).
///
/// The same search as Home's Where to?, and under the same rule
/// (`docs/geocoder-decision.md`): results arrive when the search is submitted,
/// never as the rider types. Nominatim's usage policy forbids autocomplete
/// against the public instance, and a test fails if a keystroke ever searches.
library;

import 'package:flutter/material.dart';

import '../../domain/ride_plan.dart';
import '../../services/road_routing.dart';

/// What a rider picked.
sealed class PlaceSearchChoice {
  const PlaceSearchChoice();
}

/// "Your location": the start that follows the rider.
final class PlaceSearchCurrentLocation extends PlaceSearchChoice {
  const PlaceSearchCurrentLocation();
}

/// A searched place.
final class PlaceSearchPlace extends PlaceSearchChoice {
  const PlaceSearchPlace(this.place);

  final RidePlanPlace place;
}

class PlaceSearchSheet extends StatefulWidget {
  const PlaceSearchSheet({
    super.key,
    required this.searchService,
    required this.title,
    this.offerCurrentLocation = false,
    this.currentLocationKnown = true,
  });

  final DestinationSearchService searchService;
  final String title;

  /// Offers "Your location" above the results, for the start row. It is
  /// offered with or without a fix: choosing it means "from wherever I am when
  /// the route is planned", which the plan surface waits for and says so.
  final bool offerCurrentLocation;
  final bool currentLocationKnown;

  static Future<PlaceSearchChoice?> show(
    BuildContext context, {
    required DestinationSearchService searchService,
    required String title,
    bool offerCurrentLocation = false,
    bool currentLocationKnown = true,
  }) => showModalBottomSheet<PlaceSearchChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => PlaceSearchSheet(
      searchService: searchService,
      title: title,
      offerCurrentLocation: offerCurrentLocation,
      currentLocationKnown: currentLocationKnown,
    ),
  );

  @override
  State<PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<PlaceSearchSheet> {
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
        _error = results.isEmpty ? 'Nothing found for “$query”.' : null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is FormatException
            ? error.message
            : 'Could not search just now. Check your connection and try '
                  'again.',
      );
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              widget.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              key: const Key('place-search-field'),
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Town, postcode, or a place',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  key: const Key('place-search-submit'),
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
          if (_error case final message?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                message,
                key: const Key('place-search-error'),
                style: const TextStyle(color: Color(0xFFFF8A6B), fontSize: 13),
              ),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (widget.offerCurrentLocation)
                  ListTile(
                    key: const Key('place-search-current-location'),
                    leading: const Icon(Icons.my_location),
                    title: const Text('Your location'),
                    subtitle: widget.currentLocationKnown
                        ? null
                        : const Text('Used as soon as your location is found'),
                    onTap: () => Navigator.of(
                      context,
                    ).pop(const PlaceSearchCurrentLocation()),
                  ),
                if (results != null)
                  for (final match in results)
                    ListTile(
                      key: Key('place-search-result-${match.label}'),
                      leading: const Icon(Icons.place_outlined),
                      title: Text(match.label),
                      onTap: () => Navigator.of(context).pop(
                        PlaceSearchPlace(
                          RidePlanPlace.fromSearchResult(
                            label: match.label,
                            point: match.point,
                          ),
                        ),
                      ),
                    ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
