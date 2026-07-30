/// How a ride uses Tail End Charlie's group-coordination features.
enum RideCoordinationMode {
  /// One rider, with route recording and navigation but no join code or group
  /// controls.
  solo,

  /// The classic second-bike drop-off system: junction marker prompts, marker
  /// passes and Tail End Charlie statistics are enabled.
  secondBikeDropOff,

  /// Riders stay together as one group, without junction drop-off prompts.
  ///
  /// "Keep-together" describes the coordination policy without suggesting
  /// riders should follow at an unsafe close distance.
  keepTogether;

  bool get isGroup => this != RideCoordinationMode.solo;

  bool get usesSecondBikeDropOff =>
      this == RideCoordinationMode.secondBikeDropOff;

  String get label => switch (this) {
    RideCoordinationMode.solo => 'Solo ride',
    RideCoordinationMode.secondBikeDropOff => 'Second-bike drop-off',
    RideCoordinationMode.keepTogether => 'Keep-together group',
  };

  String get description => switch (this) {
    RideCoordinationMode.solo =>
      'Navigation and ride recording for just you. No join code or group '
          'controls; you can still share a private watcher link.',
    RideCoordinationMode.secondBikeDropOff =>
      'Use junction drop-offs, marker prompts and Tail End Charlie tracking.',
    RideCoordinationMode.keepTogether =>
      'Ride as one group without junction drop-offs or marker prompts.',
  };

  static RideCoordinationMode fromName(String? name) =>
      RideCoordinationMode.values.firstWhere(
        (mode) => mode.name == name,
        // Every ride created before this choice existed used this system.
        orElse: () => RideCoordinationMode.secondBikeDropOff,
      );
}
