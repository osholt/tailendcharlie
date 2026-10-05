import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/ride_role.dart';

/// Whether a rider holding [role] sees the group mini-map when they have not
/// said either way (#850).
///
/// The leader and the Tail End Charlie are the two riders whose job is to know
/// where the rest of the group is, so the overview earns its place on their
/// screen. Everyone else is following, and the overview there is a surface
/// between them and the road ahead that they did not ask for - which is what the
/// Android rider on the 4 October ride reported. A rider with no role yet (no
/// ride, or one not joined) is treated as a follower.
bool miniMapVisibleByDefault(RideRole? role) =>
    role == RideRole.lead || role == RideRole.tailEndCharlie;

/// Whether the group mini-map is drawn: the rider's own choice when they have
/// made one, and otherwise what their role calls for.
///
/// A pure function of those two inputs, so the default can follow the role as it
/// changes - a rider handed the lead partway through a ride gets the overview
/// then, with nothing to restart - while an explicit choice, on or off, stays
/// theirs whatever role they hold (#850).
bool miniMapVisible({required RideRole? role, required bool? explicitChoice}) =>
    explicitChoice ?? miniMapVisibleByDefault(role);

/// Remembers, per device, whether the rider has chosen to show or hide the group
/// mini-map (#850).
///
/// It stores the *choice*, not the outcome. With no choice stored the answer
/// comes from the rider's role at the moment of asking ([visibleFor]), which is
/// what lets the default follow the role live; storing the resolved default
/// instead would freeze whatever role the rider happened to hold the first time
/// they opened Settings.
class MiniMapDisplayController extends ChangeNotifier {
  MiniMapDisplayController._(this._preferences, this._explicitChoice);

  static const preferenceKey = 'mini_map_display_choice_v1';

  final SharedPreferences? _preferences;
  bool? _explicitChoice;

  static Future<MiniMapDisplayController> load() async {
    final preferences = await SharedPreferences.getInstance();
    return MiniMapDisplayController._(
      preferences,
      preferences.getBool(preferenceKey),
    );
  }

  factory MiniMapDisplayController.inMemory({bool? explicitChoice}) =>
      MiniMapDisplayController._(null, explicitChoice);

  /// What the rider chose, or null when they have not (and the role decides).
  bool? get explicitChoice => _explicitChoice;

  bool get hasExplicitChoice => _explicitChoice != null;

  /// Whether the mini-map is drawn for a rider holding [role].
  bool visibleFor(RideRole? role) =>
      miniMapVisible(role: role, explicitChoice: _explicitChoice);

  /// Records an explicit choice, which then outranks the role.
  Future<void> setVisible(bool value) async {
    if (_explicitChoice == value) return;
    _explicitChoice = value;
    notifyListeners();
    await _preferences?.setBool(preferenceKey, value);
  }

  /// Forgets the choice, so the role decides again.
  Future<void> useRoleDefault() async {
    if (_explicitChoice == null) return;
    _explicitChoice = null;
    notifyListeners();
    await _preferences?.remove(preferenceKey);
  }
}
