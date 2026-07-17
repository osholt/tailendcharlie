import 'ride_role.dart';

class RideSession {
  const RideSession({
    required this.rideId,
    required this.rideCode,
    required this.inviteSecret,
    required this.localRiderId,
    required this.displayName,
    required this.role,
    required this.joinedAt,
    this.isSimulation = false,
  });

  final String rideId;
  final String rideCode;
  final String inviteSecret;
  final String localRiderId;
  final String displayName;
  final RideRole role;
  final DateTime joinedAt;
  final bool isSimulation;

  RideSession copyWith({RideRole? role}) => RideSession(
    rideId: rideId,
    rideCode: rideCode,
    inviteSecret: inviteSecret,
    localRiderId: localRiderId,
    displayName: displayName,
    role: role ?? this.role,
    joinedAt: joinedAt,
    isSimulation: isSimulation,
  );

  Map<String, Object?> toJson() => {
    'rideId': rideId,
    'rideCode': rideCode,
    'inviteSecret': inviteSecret,
    'localRiderId': localRiderId,
    'displayName': displayName,
    'role': role.name,
    'joinedAt': joinedAt.toUtc().toIso8601String(),
    if (isSimulation) 'isSimulation': true,
  };

  factory RideSession.fromJson(Map<String, Object?> json) => RideSession(
    rideId: json['rideId']! as String,
    rideCode: json['rideCode']! as String,
    inviteSecret: json['inviteSecret']! as String,
    localRiderId: json['localRiderId']! as String,
    displayName: json['displayName']! as String,
    role: RideRole.values.byName(json['role']! as String),
    joinedAt: DateTime.parse(json['joinedAt']! as String).toLocal(),
    isSimulation: json['isSimulation'] as bool? ?? false,
  );
}
