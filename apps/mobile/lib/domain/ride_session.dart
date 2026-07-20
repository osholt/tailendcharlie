import 'dart:convert';
import 'dart:math';

import '../features/map/motorcycle_icon.dart';
import 'ride_role.dart';
import 'rider_color.dart';

class RideSession {
  static const minimumSimulationRiderCount = 4;
  static const maximumSimulationRiderCount = 30;
  static const defaultSimulationRiderCount = 5;

  const RideSession({
    required this.rideId,
    required this.rideCode,
    required this.inviteSecret,
    required this.joinToken,
    required this.localRiderId,
    required this.displayName,
    required this.role,
    required this.joinedAt,
    this.isSimulation = false,
    this.simulationRiderCount = defaultSimulationRiderCount,
    this.motorcycleStyle = motorcycleIconStyleDefault,
    this.riderColor = riderColorDefault,
    this.rideName,
  }) : assert(
         !isSimulation ||
             (simulationRiderCount >= minimumSimulationRiderCount &&
                 simulationRiderCount <= maximumSimulationRiderCount),
       );

  final String rideId;
  final String rideCode;
  final String inviteSecret;

  /// A high-entropy credential paired with [rideCode] on the internet relay.
  /// The six-digit code alone is brute-forceable over the public internet;
  /// resolving the invite secret from the relay requires this too. Only
  /// carried in the "Share" text and a smart-paste, never displayed on its
  /// own - the six digits remain what a rider reads or types.
  final String joinToken;
  final String localRiderId;
  final String displayName;
  final RideRole role;
  final DateTime joinedAt;
  final bool isSimulation;
  final int simulationRiderCount;
  final MotorcycleIconStyle motorcycleStyle;
  final RiderColor riderColor;

  /// Optional, leader-chosen at creation. Never required: rides are always
  /// identifiable by their six-digit code even with no name set.
  final String? rideName;

  RideSession copyWith({
    RideRole? role,
    String? rideCode,
    int? simulationRiderCount,
  }) => RideSession(
    rideId: rideId,
    rideCode: rideCode ?? this.rideCode,
    inviteSecret: inviteSecret,
    joinToken: joinToken,
    localRiderId: localRiderId,
    displayName: displayName,
    role: role ?? this.role,
    joinedAt: joinedAt,
    isSimulation: isSimulation,
    simulationRiderCount: simulationRiderCount ?? this.simulationRiderCount,
    motorcycleStyle: motorcycleStyle,
    riderColor: riderColor,
    rideName: rideName,
  );

  Map<String, Object?> toJson() => {
    'rideId': rideId,
    'rideCode': rideCode,
    'inviteSecret': inviteSecret,
    'joinToken': joinToken,
    'localRiderId': localRiderId,
    'displayName': displayName,
    'role': role.name,
    'joinedAt': joinedAt.toUtc().toIso8601String(),
    if (isSimulation) 'isSimulation': true,
    if (isSimulation) 'simulationRiderCount': simulationRiderCount,
    'motorcycleStyle': motorcycleStyle.name,
    'riderColor': riderColor.name,
    if (rideName != null) 'rideName': rideName,
  };

  factory RideSession.fromJson(Map<String, Object?> json) => RideSession(
    rideId: json['rideId']! as String,
    rideCode: json['rideCode']! as String,
    inviteSecret: json['inviteSecret']! as String,
    joinToken: _joinTokenOrFallback(json['joinToken']),
    localRiderId: json['localRiderId']! as String,
    displayName: json['displayName']! as String,
    role: RideRole.values.byName(json['role']! as String),
    joinedAt: DateTime.parse(json['joinedAt']! as String).toLocal(),
    isSimulation: json['isSimulation'] as bool? ?? false,
    simulationRiderCount: _simulationRiderCount(json['simulationRiderCount']),
    motorcycleStyle: motorcycleIconStyleFromName(
      json['motorcycleStyle'] as String?,
    ),
    riderColor: riderColorFromName(json['riderColor'] as String?),
    rideName: json['rideName'] as String?,
  );

  static int _simulationRiderCount(Object? value) {
    if (value is! int) return defaultSimulationRiderCount;
    return value
        .clamp(minimumSimulationRiderCount, maximumSimulationRiderCount)
        .toInt();
  }

  /// A ride session persisted before the join token existed has none stored.
  /// Generating a fresh one keeps old local sessions loadable; a lead in
  /// that state simply re-publishes its ride code with the new token.
  static String _joinTokenOrFallback(Object? value) {
    if (value is String && value.length >= 16) return value;
    return base64Url
        .encode(List<int>.generate(20, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
  }
}
