import 'motorcycle_discovery.dart';

/// What a discovery road says about itself, in words a rider can trust.
///
/// This is the whole of the wording for #160, kept out of the widget so every
/// provenance state and every absent field can be tested directly. Three rules
/// run through all of it:
///
/// 1. **A road with no mapped limit reads as not known**, distinctly from a
///    mapped one, and never as an unrestricted road or a guess. That is #145's
///    honesty rule applied to a second surface.
/// 2. **Absence of a record is not absence of the thing.** One candidate in
///    2,245 matches an OpenStreetMap `enforcement=average_speed` relation, yet
///    the A57 Snake Pass has published camera proposals OpenStreetMap does not
///    record. So the copy says *not recorded in OpenStreetMap*, never "none".
/// 3. **An unreviewed entry never reads like a verified one.**
///
/// There is deliberately no "police checks likely" field. It is not in
/// OpenStreetMap, it must not be synthesised from road class, and the only
/// credible source is accumulated rider reports (#112, #135). Until those exist
/// it is omitted rather than invented.
class DiscoveryRoadFacts {
  DiscoveryRoadFacts._({
    required this.speedLimit,
    required this.speedLimitProvenance,
    required this.speedLimitIsKnown,
    required this.enforcement,
    required this.fixedCameras,
    required this.enforcementCaveat,
    required this.busyPeriods,
    required this.description,
    required this.researchLabel,
    required this.researchDetail,
    required this.isVerified,
    required this.sourceVerificationLabel,
    required this.sourceVerificationDetail,
    required this.sourceIsFetched,
    required this.evidenceSources,
  });

  /// Wording used wherever a fact could exist but OpenStreetMap does not carry
  /// it. Stated once so the app and the website cannot phrase it differently.
  /// Never "none": the field describes the map, not the road.
  static const notRecorded = 'not recorded in OpenStreetMap';

  /// Why "not recorded" must not be read as "not there".
  ///
  /// One candidate in 2,245 matches an OpenStreetMap average-speed relation,
  /// while the A57 Snake Pass has published camera proposals OpenStreetMap does
  /// not hold. Getting this wrong tells a rider a road is clear when it is not.
  static const enforcementRecordCaveat =
      'OpenStreetMap does not hold every camera, so this is not evidence that '
      'the road is unenforced.';

  /// The limit line. Either a limit, or the fact that there is not one.
  final String speedLimit;

  /// Where that limit came from, always shown alongside it rather than hidden.
  final String speedLimitProvenance;

  /// Whether [speedLimit] is a limit at all. The two cases must not be styled
  /// the same.
  final bool speedLimitIsKnown;

  final String enforcement;
  final String fixedCameras;

  /// A researched caveat that contradicts the OpenStreetMap record, when there
  /// is one. This is what stops "no average speed check recorded" being read as
  /// "no cameras here".
  final String? enforcementCaveat;

  final String busyPeriods;
  final String? description;

  /// Short badge text: `Researched` or `Not yet reviewed`.
  final String researchLabel;
  final String researchDetail;
  final bool isVerified;
  final String sourceVerificationLabel;
  final String sourceVerificationDetail;
  final bool sourceIsFetched;
  final List<String> evidenceSources;

  factory DiscoveryRoadFacts.of(MotorcycleDiscoveryFeature feature) {
    final limit = feature.speedLimit;
    final check = feature.averageSpeedCheck;
    final cameras = feature.fixedSpeedCameras;
    return DiscoveryRoadFacts._(
      speedLimit: limit.isKnown
          ? _limitWithRange(limit)
          : 'Speed limit not known',
      speedLimitProvenance: switch (limit.provenance) {
        DiscoverySpeedLimitProvenance.tagged =>
          'Recorded in OpenStreetMap for this road.',
        DiscoverySpeedLimitProvenance.inferredFromMaxspeedType =>
          'Implied by a national speed limit tag in OpenStreetMap, not a '
              'posted value for this road.',
        // The catalogue's own note is used when it has one, because it can be
        // more specific than anything generic said here.
        DiscoverySpeedLimitProvenance.unknown =>
          limit.note ?? 'A speed limit for this road is $notRecorded.',
        DiscoverySpeedLimitProvenance.absent =>
          'A speed limit for this road is $notRecorded.',
      },
      speedLimitIsKnown: limit.isKnown,
      enforcement: switch (check) {
        // A relation actually covers the road.
        DiscoveryAverageSpeedCheck(present: true) =>
          check.description ??
              'Average speed check: recorded in OpenStreetMap'
                  '${check.enforcedLimit == null ? '' : ' at ${check.enforcedLimit}'}.',
        // We looked and found no relation. Not the absence of a camera.
        DiscoveryAverageSpeedCheck(recorded: true) =>
          'Average speed check: $notRecorded for this road.',
        // We never looked, which is a weaker statement still.
        _ => 'Average speed check: not checked for this road.',
      },
      fixedCameras: switch (cameras) {
        null => 'Fixed speed cameras: not checked for this road.',
        0 => 'Fixed speed cameras: $notRecorded near this road.',
        1 => 'Fixed speed cameras: 1 recorded in OpenStreetMap near this road.',
        final count =>
          'Fixed speed cameras: $count recorded in OpenStreetMap near this '
              'road.',
      },
      enforcementCaveat: feature.enforcementNote,
      busyPeriods:
          feature.busyPeriods ?? 'Busy periods have not been researched.',
      description: feature.riderNote,
      researchLabel: feature.researchStatus.isVerified
          ? 'Researched'
          : 'Not yet reviewed',
      researchDetail: switch ((
        feature.researchStatus,
        feature.sourceVerification,
      )) {
        (
          DiscoveryResearchStatus.researched,
          DiscoverySourceVerification.fetched,
        ) =>
          'Checked against the cited sources below.',
        (
          DiscoveryResearchStatus.researched,
          DiscoverySourceVerification.listingOnly,
        ) =>
          'Reviewed, but the cited source was available only as a listing.',
        (DiscoveryResearchStatus.researched, _) =>
          'Reviewed, but the catalogue does not record how the cited source '
              'was checked.',
        _ =>
          'Generated from OpenStreetMap and not yet checked by a person. '
              'Treat every field here with less confidence than a reviewed '
              'entry.',
      },
      isVerified: feature.researchStatus.isVerified,
      sourceVerificationLabel: switch (feature.sourceVerification) {
        DiscoverySourceVerification.fetched => 'Source checked',
        DiscoverySourceVerification.listingOnly => 'Listing evidence only',
        DiscoverySourceVerification.unstated => 'Source check not recorded',
      },
      sourceVerificationDetail: switch (feature.sourceVerification) {
        DiscoverySourceVerification.fetched =>
          'The cited page was retrieved and the claim was checked against it.',
        DiscoverySourceVerification.listingOnly =>
          'The cited listing confirms that the road appears there; it does '
              'not verify the road’s riding quality.',
        DiscoverySourceVerification.unstated =>
          'The catalogue does not record how the source was checked. Treat '
              'this claim cautiously.',
      },
      sourceIsFetched: feature.sourceVerification.isFetched,
      evidenceSources: feature.evidenceSources,
    );
  }

  /// Whether an average-speed relation actually covers this road.
  bool get hasRecordedEnforcement =>
      enforcement.contains('recorded in OpenStreetMap') &&
      !enforcement.contains(notRecorded);

  /// Every enforcement line, in reading order.
  ///
  /// The caveat is always last, and is present whenever nothing was found, so
  /// "not recorded" can never be the final word a rider reads.
  List<String> get enforcementLines => [
    enforcement,
    fixedCameras,
    ?enforcementCaveat,
    if (!hasRecordedEnforcement) enforcementRecordCaveat,
  ];

  static String _limitWithRange(DiscoverySpeedLimit limit) {
    final value = limit.value!;
    if (!limit.mixed) return value;
    if (limit.range.length == 2) {
      return '$value · varies from ${limit.range.first} to ${limit.range.last}';
    }
    return '$value · varies along this road';
  }
}
