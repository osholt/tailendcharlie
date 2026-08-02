import '../domain/distance_unit.dart';
import 'leader_ride_status.dart';
import 'measurement_formatter.dart';
import 'tec_gap_trend.dart';

/// The back-marker, projected for a vehicle screen.
///
/// The app is named after this role, and until now the CarPlay snapshot said
/// nothing about it: a leader plugged into a head unit could see five riders
/// listed and still have no idea whether anyone was watching the back. This is
/// the one place that decides what a car screen is told about the TEC.
///
/// Two rules carry over from the phone and matter *more* here, because a rider
/// reading a head unit is moving and will not study it:
///
/// * The four availability states are never conflated. "Nobody is TEC" is a
///   different safety situation from "the TEC has not reported yet", which is
///   different again from "their last fix is too old to trust". See
///   [TecAvailability].
/// * A gap that cannot be trusted is withheld rather than shown, and the trend
///   is carried as a word and a shape rather than a colour (#181, #107, #143).
class CarPlayTecStatus {
  const CarPlayTecStatus({
    required this.availability,
    this.riderId,
    this.name,
    this.distanceMeters,
    this.estimatedTime,
    this.locationAge,
    this.trend = TecGapTrend.unknown,
    this.distanceUnit = DistanceUnit.miles,
  });

  /// Nobody is Tail End Charlie, and no surface should imply otherwise.
  static const CarPlayTecStatus absent = CarPlayTecStatus(
    availability: TecAvailability.none,
  );

  final TecAvailability availability;
  final String? riderId;

  /// Null while the TEC has never reported a position - nothing is known about
  /// them beyond the fact that they hold the role.
  final String? name;

  /// The leader's gap to the TEC. Only ever set for a leader whose own fix and
  /// the TEC's are both current: [LeaderRideStatus] withholds it otherwise, and
  /// a rider who is not the leader has no gap to report at all.
  final double? distanceMeters;
  final Duration? estimatedTime;
  final Duration? locationAge;
  final TecGapTrend trend;
  final DistanceUnit distanceUnit;

  /// Builds the projection from the two models that already own these facts.
  ///
  /// [target] is the role-independent resolution every TEC surface shares, so
  /// *any* rider's head unit can say who the back-marker is and whether their
  /// position is believable. [leaderStatus] is leader-only and adds the gap and
  /// the trend on top; passing null simply means this device has no gap to
  /// show, never that there is no TEC.
  factory CarPlayTecStatus.from({
    required TecTarget target,
    required DateTime now,
    LeaderRideStatus? leaderStatus,
    TecGapTrend trend = TecGapTrend.unknown,
    DistanceUnit distanceUnit = DistanceUnit.miles,
  }) {
    if (target.availability == TecAvailability.none) {
      return CarPlayTecStatus(
        availability: TecAvailability.none,
        distanceUnit: distanceUnit,
      );
    }
    // The leader's status is only allowed to contribute when it is describing
    // the same rider. A stale status left over from a previous back-marker
    // would otherwise attach the old rider's gap to the new one's name.
    final describesSameRider =
        leaderStatus != null && leaderStatus.tecRiderId == target.riderId;
    final location = target.location;
    return CarPlayTecStatus(
      availability: target.availability,
      riderId: target.riderId,
      name:
          location?.displayName ??
          (describesSameRider ? leaderStatus.tecName : null),
      distanceMeters: describesSameRider
          ? leaderStatus.distanceToTecMeters
          : null,
      estimatedTime: describesSameRider
          ? leaderStatus.estimatedTimeToTec
          : null,
      locationAge: location?.sample.ageAt(now),
      trend: describesSameRider ? trend : TecGapTrend.unknown,
      distanceUnit: distanceUnit,
    );
  }

  bool get hasRegisteredTec => availability != TecAvailability.none;

  /// The label a rider reads at a glance while moving. Short enough to survive
  /// a CarPlay list row and the map banner without truncating.
  String get headline => switch (availability) {
    TecAvailability.none => 'No TEC',
    TecAvailability.awaitingLocation => 'TEC · waiting',
    TecAvailability.stale => 'TEC · ${_ageLabel(locationAge)}',
    TecAvailability.tracking => _trackingHeadline,
  };

  /// The fuller line, for the ride-status list where there is room for it.
  /// Deliberately the same wording as the phone's TEC card, so a rider is not
  /// learning two vocabularies for one fact.
  String get detail => switch (availability) {
    TecAvailability.none => 'Nobody is covering the back',
    TecAvailability.awaitingLocation => '$_displayName · waiting for location',
    TecAvailability.stale =>
      '$_displayName · last update ${_ageLabel(locationAge)}',
    TecAvailability.tracking => _trackingDetail,
  };

  String get _displayName => name ?? 'Tail End Charlie';

  String get _trackingHeadline {
    final distance = distanceMeters;
    if (distance == null) return 'TEC · reporting';
    final gap = MeasurementFormatter(distanceUnit).distance(distance);
    return trend == TecGapTrend.unknown
        ? 'TEC · $gap'
        : 'TEC · $gap ${trend.arrow}';
  }

  String get _trackingDetail {
    final distance = distanceMeters;
    final eta = estimatedTime;
    // A leaderless device, or a leader without a fix of its own, knows the TEC
    // is reporting but has no gap to state. Saying so is the honest option;
    // inventing a zero or a dash is not.
    if (distance == null || eta == null) {
      return '$_displayName · position current';
    }
    final gap = MeasurementFormatter(distanceUnit).distance(distance);
    final trendSuffix = trend == TecGapTrend.unknown
        ? ''
        : ' · ${trend.arrow} ${trend.label}';
    return '$_displayName · $gap · about ${_durationLabel(eta)}$trendSuffix';
  }

  /// The payload the native CarPlay scene reads. `state` is the discriminator
  /// Swift branches on; the strings are pre-formatted here so the wording and
  /// the rider's chosen units live in one place rather than being reinvented
  /// in Swift.
  Map<String, Object?> toSnapshot() => {
    'state': availability.name,
    'riderId': riderId,
    'name': name,
    'headline': headline,
    'detail': detail,
    'distanceMeters': distanceMeters,
    'etaSeconds': estimatedTime?.inSeconds,
    'locationAgeSeconds': locationAge?.inSeconds,
    'trend': trend.name,
    'trendLabel': trend == TecGapTrend.unknown ? null : trend.label,
  };
}

/// Matches the phone's wording exactly - see `_durationLabel` in
/// `ride_map_feature.dart`.
String _durationLabel(Duration duration) {
  final minutes = (duration.inSeconds / 60).ceil();
  if (minutes <= 1) return '<1 min';
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  return remainder == 0 ? '$hours hr' : '$hours hr $remainder min';
}

/// Matches the phone's wording exactly - see `_ageLabel` in
/// `ride_map_feature.dart`.
String _ageLabel(Duration? age) {
  if (age == null || age.inSeconds < 30) return 'just now';
  if (age.inMinutes < 1) return '${age.inSeconds}s ago';
  return '${age.inMinutes} min ago';
}
