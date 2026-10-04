/// Route character preferences, shared with the web planner.
///
/// These are deliberately *not* a second set of preferences. Every value,
/// label, threshold and provider option in this file is the Dart half of the
/// contract the web planner already implements in
/// `apps/website/planner-core.mjs`, and the contract itself is written down once
/// in `docs/route-twistiness.md`. A route planned on the desktop and a route
/// planned in the app must agree about what "avoid motorways" means, so the two
/// implementations are pinned to identical constants by tests on both sides
/// rather than left to drift.
///
/// Preferences belong to the route, not to the device: they travel with the
/// route record and through its GPX, so a route shared into a ride still says
/// what it was planned for.
library;

/// How much extra time a rider will accept in exchange for bends.
///
/// The API values are the web planner's `<select id="route-style">` values, and
/// the detour limits are `routeDetourLimit` in `planner-core.mjs`.
enum RouteStyle {
  quickest('quickest', 'Quickest route', 1),
  flowing('balanced', 'Flowing (up to 25% longer)', 1.25),
  twisty('twisty', 'Twisty (up to 50% longer)', 1.5),
  veryTwisty('very-twisty', 'Very twisty (up to 75% longer)', 1.75);

  const RouteStyle(this.apiValue, this.label, this.detourLimit);

  /// The value written to JSON, GPX and provider requests. It is the web
  /// planner's option value, which is why `flowing` serialises as `balanced`.
  final String apiValue;
  final String label;

  /// The most a chosen alternative may exceed the quickest route's duration.
  final double detourLimit;

  /// A rider asking for bends wants the provider to offer alternatives to
  /// score; the quickest route needs none.
  bool get prefersBends => this != RouteStyle.quickest;

  /// Valhalla `use_highways` for this style, or null when the style expresses
  /// no highway preference of its own. `motorcycleCostingOptions` in
  /// `planner-core.mjs` holds the same three numbers.
  double? get highwayPreference => switch (this) {
    RouteStyle.quickest => null,
    RouteStyle.flowing => 0.6,
    RouteStyle.twisty => 0.35,
    RouteStyle.veryTwisty => 0.15,
  };

  static RouteStyle? fromApiValue(Object? value) =>
      RouteStyle.values.where((style) => style.apiValue == value).firstOrNull;
}

/// What to do about byways open to all traffic and other unsurfaced roads.
///
/// A byway open to all traffic is a *legal* designation - OpenStreetMap records
/// it as `designation=byway_open_to_all_traffic` - and it says nothing at all
/// about what the surface is made of. Many BOATs are rutted, and some are
/// asphalt. So the preference is expressed against the surface tagging that
/// OpenStreetMap actually carries (`surface=*`, and `highway=track` for a way
/// mapped as a track), never inferred from the road's classification. That is
/// also why the option is named for the surface rather than for the legal
/// designation.
enum BywaySurfacePreference {
  /// The default. See `docs/route-twistiness.md` for the reasoning.
  avoidUnsurfaced('avoid-unsurfaced', 'Avoid unsurfaced byways'),

  /// For a trail rider who wants them: the road route may use ways
  /// OpenStreetMap tags as unsurfaced or as a track.
  allowUnsurfaced('allow-unsurfaced', 'Allow unsurfaced byways and tracks');

  const BywaySurfacePreference(this.apiValue, this.label);

  final String apiValue;
  final String label;

  bool get avoidsUnsurfaced => this == BywaySurfacePreference.avoidUnsurfaced;

  static BywaySurfacePreference? fromApiValue(Object? value) =>
      BywaySurfacePreference.values
          .where((preference) => preference.apiValue == value)
          .firstOrNull;
}

/// The route character a rider asked for.
class RoutePreferences {
  const RoutePreferences({
    this.style = RouteStyle.quickest,
    this.avoidMotorways = false,
    this.avoidMajorRoads = false,
    this.avoidTolls = false,
    this.avoidFerries = false,
    this.bywaySurface = BywaySurfacePreference.avoidUnsurfaced,
  });

  static const RoutePreferences defaults = RoutePreferences();

  final RouteStyle style;

  /// Excludes motorways outright, rather than merely making them expensive.
  final bool avoidMotorways;

  /// The quieter-road option: trunk and primary roads are heavily penalised but
  /// not excluded, because excluding them strands most UK routes.
  final bool avoidMajorRoads;
  final bool avoidTolls;
  final bool avoidFerries;
  final BywaySurfacePreference bywaySurface;

  bool get isDefault => this == defaults;

  /// Whether these preferences need Valhalla's motorcycle costing rather than
  /// the plain OSRM driving profile.
  ///
  /// This is the web planner's `requestRoadRoute` rule, extended for byways.
  /// The four avoidances are exclusions OSRM's driving profile cannot express.
  /// [BywaySurfacePreference.allowUnsurfaced] is on the list because only the
  /// motorcycle costing has a lever for *seeking* byways.
  ///
  /// The default - avoid unsurfaced byways - stays on OSRM, but **not** because
  /// OSRM avoids them. It does not. This comment used to say OSRM's car profile
  /// "does not route `highway=track` at all"; on 4 October 2026 the public OSRM
  /// server routed an untagged `highway=track` with gates, because it was
  /// shorter than the paved road beside it (#840). The default stays on OSRM so
  /// that every ordinary route does not go through the shared Valhalla
  /// instance, and the preference is enforced by *checking the route that comes
  /// back* and re-planning around what breaks it (`RouteVerifier`).
  bool get requiresMotorcycleCosting =>
      avoidMotorways ||
      avoidMajorRoads ||
      avoidTolls ||
      avoidFerries ||
      !bywaySurface.avoidsUnsurfaced;

  /// Valhalla `costing_options.motorcycle`.
  ///
  /// Identical to `motorcycleCostingOptions` in `planner-core.mjs`, including
  /// its numbers. `use_trails` and `exclude_unpaved` are documented Valhalla
  /// options derived from OpenStreetMap surface and track tagging, which is
  /// what makes the byway preference follow the tags instead of guessing from
  /// road class.
  ///
  /// Documented is not honoured. Measured against the public instance on
  /// 4 October 2026: `exclude_highways` and `use_highways` are honoured (with
  /// Avoid motorways on, Bristol to Stroud has no motorway edge), but
  /// `exclude_unpaved` and `use_trails: 0` are not - the same request routed
  /// over a `highway=track` that `auto` costing avoids (#840, #858). So these
  /// are a request, and the route that comes back is checked against the
  /// preferences rather than trusted (`RouteVerifier`).
  Map<String, Object?> valhallaMotorcycleCostingOptions() => {
    'use_highways': avoidMajorRoads ? 0.08 : style.highwayPreference ?? 1,
    'use_tolls': avoidTolls ? 0 : 0.5,
    'use_ferry': avoidFerries ? 0 : 0.5,
    'use_trails': bywaySurface.avoidsUnsurfaced ? 0 : 0.5,
    'exclude_highways': avoidMotorways,
    'exclude_tolls': avoidTolls,
    'exclude_ferries': avoidFerries,
    'exclude_unpaved': bywaySurface.avoidsUnsurfaced,
  };

  /// What the rider asked for, in the order of the web planner's status line.
  ///
  /// Worded as the request, never as an outcome. These used to read "motorways
  /// excluded" and "unsurfaced byways avoided", which stated a result nothing
  /// had established: a route up the M5 and a route over a gated track both
  /// went out under them (#858, #840). Whether a request was met is what
  /// `RouteVerification` says.
  List<String> get requestedNotes => [
    if (style.prefersBends)
      switch (style) {
        RouteStyle.flowing => 'Flowing-road bias',
        RouteStyle.twisty => 'Twisty-road bias',
        RouteStyle.veryTwisty => 'Very-twisty-road bias',
        RouteStyle.quickest => '',
      },
    if (avoidMotorways) 'avoid motorways',
    if (avoidMajorRoads) 'avoid major roads',
    if (avoidTolls) 'avoid toll roads',
    if (avoidFerries) 'avoid ferries',
    if (bywaySurface.avoidsUnsurfaced)
      'avoid unsurfaced byways'
    else
      'allow unsurfaced byways',
  ];

  /// The rider-facing summary of what was asked for. Never empty: the byway
  /// preference always says which way round it is, because "avoid them" and
  /// "allow them" are the difference between a Fireblade and a rutted BOAT.
  String get summary {
    final notes = requestedNotes;
    if (notes.isEmpty) return 'Quickest route.';
    final joined = notes.join(', ');
    return '${joined[0].toUpperCase()}${joined.substring(1)}.';
  }

  RoutePreferences copyWith({
    RouteStyle? style,
    bool? avoidMotorways,
    bool? avoidMajorRoads,
    bool? avoidTolls,
    bool? avoidFerries,
    BywaySurfacePreference? bywaySurface,
  }) => RoutePreferences(
    style: style ?? this.style,
    avoidMotorways: avoidMotorways ?? this.avoidMotorways,
    avoidMajorRoads: avoidMajorRoads ?? this.avoidMajorRoads,
    avoidTolls: avoidTolls ?? this.avoidTolls,
    avoidFerries: avoidFerries ?? this.avoidFerries,
    bywaySurface: bywaySurface ?? this.bywaySurface,
  );

  Map<String, Object?> toJson() => {
    'style': style.apiValue,
    'avoidMotorways': avoidMotorways,
    'avoidMajorRoads': avoidMajorRoads,
    'avoidTolls': avoidTolls,
    'avoidFerries': avoidFerries,
    'bywaySurface': bywaySurface.apiValue,
  };

  /// Reads preferences a route was planned with.
  ///
  /// An unrecognised or missing value falls back to the documented default
  /// rather than throwing: a route from an older build, or from another tool,
  /// still has to open. The byway default is the road-biased one, so a route
  /// that never recorded a preference is not silently sent down a green lane.
  factory RoutePreferences.fromJson(Map<String, Object?> json) =>
      RoutePreferences(
        style: RouteStyle.fromApiValue(json['style']) ?? RouteStyle.quickest,
        avoidMotorways: json['avoidMotorways'] == true,
        avoidMajorRoads: json['avoidMajorRoads'] == true,
        avoidTolls: json['avoidTolls'] == true,
        avoidFerries: json['avoidFerries'] == true,
        bywaySurface:
            BywaySurfacePreference.fromApiValue(json['bywaySurface']) ??
            BywaySurfacePreference.avoidUnsurfaced,
      );

  @override
  bool operator ==(Object other) =>
      other is RoutePreferences &&
      other.style == style &&
      other.avoidMotorways == avoidMotorways &&
      other.avoidMajorRoads == avoidMajorRoads &&
      other.avoidTolls == avoidTolls &&
      other.avoidFerries == avoidFerries &&
      other.bywaySurface == bywaySurface;

  @override
  int get hashCode => Object.hash(
    style,
    avoidMotorways,
    avoidMajorRoads,
    avoidTolls,
    avoidFerries,
    bywaySurface,
  );

  @override
  String toString() => 'RoutePreferences(${toJson()})';
}
