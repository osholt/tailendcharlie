import '../features/map/motorcycle_icon.dart';
import 'geo_point.dart';
import 'ride_role.dart';
import 'rider_color.dart';

class LocationSample {
  const LocationSample({
    required this.position,
    required this.recordedAt,
    required this.accuracyMeters,
    this.speedMetersPerSecond,
    this.headingDegrees,
  }) : assert(accuracyMeters >= 0),
       assert(speedMetersPerSecond == null || speedMetersPerSecond >= 0),
       assert(
         headingDegrees == null ||
             (headingDegrees >= 0 && headingDegrees < 360),
       );

  final GeoPoint position;
  final DateTime recordedAt;
  final double accuracyMeters;
  final double? speedMetersPerSecond;
  final double? headingDegrees;

  Duration ageAt(DateTime now) {
    final age = now.difference(recordedAt);
    return age.isNegative ? Duration.zero : age;
  }

  bool isStaleAt(DateTime now, Duration threshold) => ageAt(now) > threshold;

  Map<String, Object?> toJson() => {
    'position': position.toJson(),
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    'accuracyMeters': accuracyMeters,
    'speedMetersPerSecond': speedMetersPerSecond,
    'headingDegrees': headingDegrees,
  };

  factory LocationSample.fromJson(Map<String, Object?> json) => LocationSample(
    position: GeoPoint.fromJson(
      Map<String, Object?>.from(json['position']! as Map),
    ),
    recordedAt: DateTime.parse(json['recordedAt']! as String).toLocal(),
    accuracyMeters: (json['accuracyMeters']! as num).toDouble(),
    speedMetersPerSecond: (json['speedMetersPerSecond'] as num?)?.toDouble(),
    headingDegrees: (json['headingDegrees'] as num?)?.toDouble(),
  );
}

class RiderLocation {
  const RiderLocation({
    required this.riderId,
    required this.displayName,
    required this.role,
    required this.sample,
    required this.receivedAt,
    this.motorcycleStyle = motorcycleIconStyleDefault,
    this.riderSymbol = riderSymbolDefault,
    this.riderColor = riderColorDefault,
  });

  final String riderId;
  final String displayName;
  final RideRole role;
  final LocationSample sample;
  final DateTime receivedAt;
  final MotorcycleIconStyle motorcycleStyle;
  final RiderSymbol riderSymbol;
  final RiderColor riderColor;

  Map<String, Object?> toJson() => {
    'riderId': riderId,
    'displayName': displayName,
    'role': role.name,
    'sample': sample.toJson(),
    'receivedAt': receivedAt.toUtc().toIso8601String(),
    'motorcycleStyle': riderSymbol.wireValue(motorcycleStyle),
    'riderColor': riderColor.name,
  };

  factory RiderLocation.fromJson(Map<String, Object?> json) => RiderLocation(
    riderId: json['riderId']! as String,
    displayName: json['displayName']! as String,
    role: RideRole.values.byName(json['role']! as String),
    sample: LocationSample.fromJson(
      Map<String, Object?>.from(json['sample']! as Map),
    ),
    receivedAt: DateTime.parse(json['receivedAt']! as String).toLocal(),
    motorcycleStyle: motorcycleIconStyleFromName(
      json['motorcycleStyle'] as String?,
    ),
    riderSymbol: RiderSymbol.fromWireValue(json['motorcycleStyle'] as String?),
    riderColor: riderColorFromName(json['riderColor'] as String?),
  );
}

class RiderLocationEvidence {
  const RiderLocationEvidence({
    required this.location,
    required this.eventId,
    required this.eventCreatedAt,
    required this.authenticated,
  });

  final RiderLocation location;
  final String eventId;
  final DateTime eventCreatedAt;
  final bool authenticated;
}
