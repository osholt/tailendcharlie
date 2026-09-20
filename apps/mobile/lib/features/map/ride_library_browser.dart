import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;

import '../../domain/distance_unit.dart';
import '../../domain/ride_library_organisation.dart';
import '../../domain/imported_route.dart' show GeoPoint;
import '../../services/basemap_configuration.dart';
import '../../services/flutter_vector_style.dart';
import '../../services/measurement_formatter.dart';

class RideLibraryEntry {
  const RideLibraryEntry({
    required this.id,
    required this.title,
    required this.locationLabel,
    required this.distanceMeters,
    required this.paths,
    required this.open,
    this.rating,
    this.organisation = const RideLibraryOrganisation(),
  });
  final String id;
  final String title;
  final String locationLabel;
  final double distanceMeters;
  final List<List<GeoPoint>> paths;
  final int? rating;
  final RideLibraryOrganisation organisation;
  final VoidCallback open;
}

enum LibraryLength { all, short, medium, long }

bool libraryEntryMatches(
  RideLibraryEntry entry, {
  String query = '',
  LibraryLength length = LibraryLength.all,
  int minimumRating = 0,
  double lengthUnitMeters = 1000,
  LatLngBounds? area,
  String? folder,
  String? tag,
}) {
  if (folder != null && !entry.organisation.inFolder(folder)) return false;
  if (tag != null && !entry.organisation.tags.contains(tag)) return false;
  final text =
      '${entry.title} ${entry.locationLabel} ${entry.organisation.folder}'
          .toLowerCase();
  for (final term
      in query
          .trim()
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((term) => term.isNotEmpty)) {
    if (term.startsWith('#')) {
      if (!entry.organisation.tags.contains(term.substring(1))) return false;
    } else if (!text.contains(term) &&
        !entry.organisation.tags.any((tag) => tag.contains(term))) {
      return false;
    }
  }
  final distance = entry.distanceMeters / lengthUnitMeters;
  if (switch (length) {
    LibraryLength.all => false,
    LibraryLength.short => distance >= 50,
    LibraryLength.medium => distance < 50 || distance >= 150,
    LibraryLength.long => distance < 150,
  }) {
    return false;
  }
  if (minimumRating > 0 && (entry.rating ?? 0) < minimumRating) return false;
  return area == null ||
      entry.paths.any((path) => libraryPathIntersectsArea(path, area));
}

/// Segment clipping also finds a ride crossing a viewport with no fix inside it.
bool libraryPathIntersectsArea(List<GeoPoint> path, LatLngBounds area) {
  for (final point in path) {
    if (area.contains(LatLng(point.latitude, point.longitude))) return true;
  }
  for (var index = 1; index < path.length; index++) {
    final a = path[index - 1], b = path[index];
    final dx = b.longitude - a.longitude, dy = b.latitude - a.latitude;
    var low = 0.0, high = 1.0;
    var intersects = true;
    final p = [-dx, dx, -dy, dy];
    final q = [
      a.longitude - area.west,
      area.east - a.longitude,
      a.latitude - area.south,
      area.north - a.latitude,
    ];
    for (var edge = 0; edge < 4; edge++) {
      if (p[edge] == 0) {
        if (q[edge] < 0) intersects = false;
      } else {
        final ratio = q[edge] / p[edge];
        if (p[edge] < 0) {
          if (ratio > low) low = ratio;
        } else {
          if (ratio < high) high = ratio;
        }
      }
    }
    if (intersects && low <= high) return true;
  }
  return false;
}

class RideLibraryBrowser extends StatefulWidget {
  const RideLibraryBrowser({
    super.key,
    required this.entries,
    required this.distanceUnit,
    required this.basemap,
    required this.listBuilder,
    this.allowRating = false,
  });
  final List<RideLibraryEntry> entries;
  final DistanceUnit distanceUnit;
  final BasemapConfiguration basemap;
  final bool allowRating;
  final Widget Function(Set<String> ids, bool filtered) listBuilder;
  @override
  State<RideLibraryBrowser> createState() => _RideLibraryBrowserState();
}

class _RideLibraryBrowserState extends State<RideLibraryBrowser> {
  final _mapController = MapController();
  final LayerHitNotifier<String> _hits = ValueNotifier(null);
  final _searchController = TextEditingController();
  bool _map = false;
  LibraryLength _length = LibraryLength.all;
  int _rating = 0;
  LatLngBounds? _area;
  String? _selected;
  String? _folder;
  String? _tag;
  late Future<vmt.Style?> _style = _loadStyle();

  Future<vmt.Style?> _loadStyle() async {
    if (!widget.basemap.usesMapLibre) return null;
    try {
      return await readFlutterVectorStyle(widget.basemap);
    } on Object {
      return null;
    }
  }

  @override
  void didUpdateWidget(RideLibraryBrowser old) {
    super.didUpdateWidget(old);
    if (old.basemap.styleUrl != widget.basemap.styleUrl ||
        old.basemap.restrainedLightStyle !=
            widget.basemap.restrainedLightStyle) {
      _style = _loadStyle();
    }
  }

  @override
  void dispose() {
    _mapController.dispose();
    _hits.dispose();
    _searchController.dispose();
    super.dispose();
  }

  double get _unit =>
      widget.distanceUnit == DistanceUnit.miles ? 1609.344 : 1000;
  bool get _filtered =>
      _searchController.text.trim().isNotEmpty ||
      _length != LibraryLength.all ||
      _rating > 0 ||
      _area != null ||
      _folder != null ||
      _tag != null;
  List<RideLibraryEntry> get _visible => widget.entries
      .where(
        (entry) => libraryEntryMatches(
          entry,
          query: _searchController.text,
          length: _length,
          minimumRating: _rating,
          lengthUnitMeters: _unit,
          area: _area,
          folder: _folder,
          tag: _tag,
        ),
      )
      .toList(growable: false);

  void _clear() => setState(() {
    _searchController.clear();
    _length = LibraryLength.all;
    _rating = 0;
    _area = null;
    _folder = null;
    _tag = null;
  });

  List<String> get _folders {
    final result = <String>{};
    for (final entry in widget.entries) {
      final parts = entry.organisation.folder
          .split('/')
          .where((part) => part.isNotEmpty)
          .toList();
      for (var i = 1; i <= parts.length; i++) {
        result.add(parts.take(i).join('/'));
      }
    }
    return result.toList()..sort();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _visible;
    final unit = widget.distanceUnit == DistanceUnit.miles ? 'mi' : 'km';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('library-search'),
                  controller: _searchController,
                  decoration: const InputDecoration(
                    hintText: 'Name, place or #tag',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: const Key('library-view-toggle'),
                tooltip: _map ? 'Show list' : 'Show map',
                icon: Icon(_map ? Icons.view_list : Icons.map_outlined),
                onPressed: () {
                  FocusScope.of(context).unfocus();
                  setState(() => _map = !_map);
                },
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                if (_folders.isNotEmpty) ...[
                  PopupMenuButton<String>(
                    key: const Key('library-folder-filter'),
                    tooltip: 'Choose folder',
                    onSelected: (value) =>
                        setState(() => _folder = value == '*' ? null : value),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: '*',
                        child: Text('All folders'),
                      ),
                      const PopupMenuItem(value: '', child: Text('Unfiled')),
                      for (final folder in _folders)
                        PopupMenuItem(value: folder, child: Text(folder)),
                    ],
                    child: Chip(
                      avatar: const Icon(Icons.folder_outlined, size: 18),
                      label: Text(
                        _folder == null
                            ? 'Folder'
                            : _folder!.isEmpty
                            ? 'Unfiled'
                            : _folder!,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (widget.entries.any(
                  (entry) => entry.organisation.tags.isNotEmpty,
                )) ...[
                  PopupMenuButton<String>(
                    key: const Key('library-tag-filter'),
                    tooltip: 'Choose tag',
                    onSelected: (value) =>
                        setState(() => _tag = value.isEmpty ? null : value),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: '', child: Text('All tags')),
                      for (final tag in ({
                        for (final entry in widget.entries)
                          ...entry.organisation.tags,
                      }.toList()..sort()))
                        PopupMenuItem(value: tag, child: Text('#$tag')),
                    ],
                    child: Chip(
                      avatar: const Icon(Icons.tag, size: 18),
                      label: Text(_tag == null ? 'Tag' : '#$_tag'),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                PopupMenuButton<LibraryLength>(
                  key: const Key('library-length-filter'),
                  tooltip: 'Filter by length',
                  initialValue: _length,
                  onSelected: (value) => setState(() => _length = value),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: LibraryLength.all,
                      child: Text('Any length'),
                    ),
                    PopupMenuItem(
                      value: LibraryLength.short,
                      child: Text('Under 50 $unit'),
                    ),
                    PopupMenuItem(
                      value: LibraryLength.medium,
                      child: Text('50–150 $unit'),
                    ),
                    PopupMenuItem(
                      value: LibraryLength.long,
                      child: Text('150 $unit or more'),
                    ),
                  ],
                  child: Chip(
                    avatar: const Icon(Icons.route, size: 18),
                    label: Text(switch (_length) {
                      LibraryLength.all => 'Length',
                      LibraryLength.short => '<50 $unit',
                      LibraryLength.medium => '50–150 $unit',
                      LibraryLength.long => '150+ $unit',
                    }),
                  ),
                ),
                if (widget.allowRating) ...[
                  const SizedBox(width: 8),
                  PopupMenuButton<int>(
                    key: const Key('library-rating-filter'),
                    tooltip: 'Filter by rating',
                    initialValue: _rating,
                    onSelected: (value) => setState(() => _rating = value),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 0, child: Text('Any rating')),
                      for (final value in [3, 4, 5])
                        PopupMenuItem(
                          value: value,
                          child: Text('$value stars or more'),
                        ),
                    ],
                    child: Chip(
                      avatar: const Icon(Icons.star_outline, size: 18),
                      label: Text(_rating == 0 ? 'Rating' : '$_rating+ stars'),
                    ),
                  ),
                ],
                if (_map &&
                    widget.entries.any(
                      (entry) => entry.paths.any((path) => path.isNotEmpty),
                    )) ...[
                  const SizedBox(width: 8),
                  ActionChip(
                    key: const Key('library-area-filter'),
                    label: const Text('In this area'),
                    onPressed: () => setState(
                      () => _area = _mapController.camera.visibleBounds,
                    ),
                  ),
                ],
                if (_filtered) ...[
                  const SizedBox(width: 8),
                  ActionChip(
                    label: const Text('Clear filters'),
                    onPressed: _clear,
                  ),
                ],
                const SizedBox(width: 10),
                Text('${entries.length} shown'),
              ],
            ),
          ),
        ),
        Expanded(
          child: _map
              ? _buildMap(entries)
              : entries.isEmpty && _filtered
              ? const Center(child: Text('No rides match these filters.'))
              : widget.listBuilder(
                  entries.map((entry) => entry.id).toSet(),
                  _filtered,
                ),
        ),
      ],
    );
  }

  Widget _buildMap(List<RideLibraryEntry> entries) {
    final allPoints = widget.entries
        .expand((entry) => entry.paths)
        .expand((path) => path)
        .map((point) => LatLng(point.latitude, point.longitude))
        .toList(growable: false);
    if (allPoints.isEmpty) {
      return const Center(
        child: Text('No saved route geometry to show on the map.'),
      );
    }
    final selected = entries
        .where((entry) => entry.id == _selected)
        .firstOrNull;
    return FutureBuilder<vmt.Style?>(
      future: _style,
      builder: (context, snapshot) {
        final style = snapshot.data;
        return Stack(
          children: [
            FlutterMap(
              key: const Key('ride-library-map'),
              mapController: _mapController,
              options: MapOptions(
                initialCameraFit: CameraFit.bounds(
                  bounds: LatLngBounds.fromPoints(allPoints),
                  padding: const EdgeInsets.all(40),
                  maxZoom: 14,
                ),
                minZoom: 2,
                maxZoom: 18,
                backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
              ),
              children: [
                if (style != null)
                  vmt.VectorTileLayer(
                    tileProviders: style.providers,
                    theme: style.theme,
                    sprites: style.sprites,
                    maximumZoom: 16,
                    concurrency: 2,
                    fileCacheTtl: Duration.zero,
                    fileCacheMaximumSizeInBytes: 0,
                  ),
                GestureDetector(
                  onTap: () => _selectHits(entries),
                  child: PolylineLayer<String>(
                    hitNotifier: _hits,
                    minimumHitbox: 14,
                    polylines: [
                      for (final entry in entries)
                        for (final path in entry.paths)
                          if (path.length >= 2)
                            Polyline<String>(
                              hitValue: entry.id,
                              points: [
                                for (final point in path)
                                  LatLng(point.latitude, point.longitude),
                              ],
                              color: Color(entry.organisation.colourArgb),
                              strokeWidth: entry.id == _selected ? 6 : 3,
                              borderColor: Colors.black87,
                              borderStrokeWidth: 1,
                            ),
                    ],
                  ),
                ),
                MarkerLayer(
                  markers: [
                    for (final entry in entries)
                      if (entry.paths.any((path) => path.isNotEmpty))
                        Marker(
                          point: LatLng(
                            entry.paths
                                .firstWhere((path) => path.isNotEmpty)
                                .first
                                .latitude,
                            entry.paths
                                .firstWhere((path) => path.isNotEmpty)
                                .first
                                .longitude,
                          ),
                          width: 40,
                          height: 40,
                          child: IconButton(
                            key: ValueKey('library-marker-${entry.id}'),
                            tooltip: entry.title,
                            icon: Icon(
                              Icons.place,
                              color: Color(entry.organisation.colourArgb),
                            ),
                            onPressed: () =>
                                setState(() => _selected = entry.id),
                          ),
                        ),
                  ],
                ),
              ],
            ),
            if (style == null &&
                snapshot.connectionState == ConnectionState.done)
              const Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: IgnorePointer(
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: Text(
                        'Basemap unavailable. Saved routes are still selectable.',
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              right: 8,
              top: 56,
              child: IconButton.filledTonal(
                tooltip: 'Fit all rides',
                icon: const Icon(Icons.fit_screen),
                onPressed: () => _mapController.fitCamera(
                  CameraFit.bounds(
                    bounds: LatLngBounds.fromPoints(allPoints),
                    padding: const EdgeInsets.all(40),
                    maxZoom: 14,
                  ),
                ),
              ),
            ),
            if (selected != null)
              Positioned(
                left: 8,
                right: 8,
                bottom: 24,
                child: Card(
                  child: ListTile(
                    key: const Key('library-map-selection'),
                    title: Text(
                      selected.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${MeasurementFormatter(widget.distanceUnit).distance(selected.distanceMeters)}'
                      '${selected.rating == null ? '' : ' · ${selected.rating} stars'} · ${selected.locationLabel}',
                      maxLines: 2,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: selected.open,
                  ),
                ),
              ),
            Positioned(
              left: 6,
              right: 6,
              bottom: 2,
              child: IgnorePointer(
                child: Text(
                  widget.basemap.attribution,
                  style: TextStyle(
                    fontSize: 10,
                    backgroundColor: Theme.of(context).colorScheme.surface,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _selectHits(List<RideLibraryEntry> entries) async {
    final ids = _hits.value?.hitValues.toSet() ?? <String>{};
    final choices = entries
        .where((entry) => ids.contains(entry.id))
        .toList(growable: false);
    if (choices.isEmpty) return;
    if (choices.length == 1) {
      setState(() => _selected = choices.single.id);
      return;
    }
    final id = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Rides on this road')),
            for (final entry in choices)
              ListTile(
                title: Text(entry.title),
                subtitle: Text(entry.locationLabel),
                onTap: () => Navigator.pop(context, entry.id),
              ),
          ],
        ),
      ),
    );
    if (mounted && id != null) setState(() => _selected = id);
  }
}
