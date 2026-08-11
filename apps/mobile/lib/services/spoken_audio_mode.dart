/// What the app is allowed to say out loud (#415).
///
/// One switch was not enough. A rider off route does not want turn-by-turn for a
/// route they are not on, and a rider who has silenced the chatter still wants to
/// be told about a speed camera — so "spoken guidance on or off" cannot express
/// what is actually wanted.
///
/// The distinction is **navigation against safety**, and it is drawn here rather
/// than at each call site so it cannot drift: a new thing to say has to declare
/// which class it belongs to, and the answer is in one place where it can be
/// argued with.
enum SpokenAudioMode {
  /// Everything: turns, distances, and warnings.
  everything,

  /// Warnings only. Turn-by-turn is silent; a camera, a hazard or a group
  /// safety alert is not.
  ///
  /// This is the mode #415 was asked for, and the one #430's camera warning has
  /// to survive.
  alertsOnly,

  /// Nothing at all, including warnings. A rider who chooses this has chosen it.
  silent,
}

/// The class a thing to say belongs to.
enum SpokenAudioClass {
  /// Turn-by-turn: where to go. Useful, and never urgent.
  navigation,

  /// Something the rider needs to know about the road or the group, whether or
  /// not they asked for directions. A camera, a hazard, a rider in trouble.
  safety,
}

/// Whether [audioClass] may be spoken in [mode].
///
/// Deliberately total over both enums rather than a chain of ifs, so adding a
/// mode or a class is a compile error at this one function instead of a silent
/// omission somewhere else.
bool spokenAudioAllows(SpokenAudioMode mode, SpokenAudioClass audioClass) =>
    switch ((mode, audioClass)) {
      (SpokenAudioMode.everything, _) => true,
      (SpokenAudioMode.silent, _) => false,
      (SpokenAudioMode.alertsOnly, SpokenAudioClass.safety) => true,
      (SpokenAudioMode.alertsOnly, SpokenAudioClass.navigation) => false,
    };

/// The mode a rider lands in when they go off route, unless they have chosen
/// silence.
///
/// Turn-by-turn for a route the rider is not on is worse than nothing: it names
/// junctions that are not coming. Warnings still apply, because a camera does not
/// care whether the rider is on the planned route.
///
/// A rider who chose [SpokenAudioMode.silent] stays there. The mapped speed limit
/// follows the same rule for a rider who turned it off, and for the same reason:
/// an explicit choice outranks an automatic one.
SpokenAudioMode spokenAudioModeOffRoute(SpokenAudioMode chosen) =>
    switch (chosen) {
      SpokenAudioMode.silent => SpokenAudioMode.silent,
      _ => SpokenAudioMode.alertsOnly,
    };

/// What the control on the map says it will do next, so a rider pressing it by
/// feel knows what they are getting.
String spokenAudioModeLabel(SpokenAudioMode mode) => switch (mode) {
  SpokenAudioMode.everything => 'Voice on',
  SpokenAudioMode.alertsOnly => 'Alerts only',
  SpokenAudioMode.silent => 'Muted',
};

/// The order the map control cycles through.
///
/// Everything → alerts only → muted → everything. Three states on one control
/// because a mounted phone in gloves has room for one, and the order goes from
/// most to least talkative so a rider who wants quiet presses in one direction.
SpokenAudioMode nextSpokenAudioMode(SpokenAudioMode mode) => switch (mode) {
  SpokenAudioMode.everything => SpokenAudioMode.alertsOnly,
  SpokenAudioMode.alertsOnly => SpokenAudioMode.silent,
  SpokenAudioMode.silent => SpokenAudioMode.everything,
};
