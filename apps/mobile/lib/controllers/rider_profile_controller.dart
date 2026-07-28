import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../domain/rider_color.dart';
import '../features/map/motorcycle_icon.dart';
import '../services/rider_contact_share.dart';

/// Remembers how a rider last presented themselves - name, bike, colour -
/// so the create/join ride form starts pre-filled instead of blank every
/// time. Deliberately separate from RideSession, which is scoped to one
/// ride: this is a standalone device preference, like DistanceUnitController.
class RiderProfileController extends ChangeNotifier {
  RiderProfileController._(
    this._preferences,
    this._installationId,
    this._displayName,
    this._motorcycleStyle,
    this._riderColor,
    this._emergencyContactName,
    this._emergencyContactPhone,
    this._medicalNotes,
    this._shareIceWithLeaderByDefault,
    this._ownPhoneNumber,
    this._onboardingCompleted,
    this._onboardingEducationSkipped,
  );

  static const _nameKey = 'rider_profile_display_name';
  static const _installationIdKey = 'rider_profile_installation_id';
  static const _styleKey = 'rider_profile_motorcycle_style';
  static const _colorKey = 'rider_profile_colour';
  static const _emergencyContactNameKey = 'rider_profile_ice_contact_name';
  static const _emergencyContactPhoneKey = 'rider_profile_ice_contact_phone';
  static const _medicalNotesKey = 'rider_profile_ice_medical_notes';
  static const _shareIceWithLeaderByDefaultKey =
      'rider_profile_ice_share_with_leader_default';

  /// Deliberately a separate key from [_emergencyContactPhoneKey]. One is the
  /// rider's own number, the other is their next of kin's, and conflating them
  /// would put the wrong person on the end of an emergency call.
  static const _ownPhoneNumberKey = 'rider_profile_own_phone_number';
  static const _onboardingCompletedKey = 'rider_profile_onboarding_completed';
  static const _onboardingEducationSkippedKey =
      'rider_profile_onboarding_education_skipped';

  final SharedPreferences _preferences;
  final String _installationId;
  String _displayName;
  MotorcycleIconStyle _motorcycleStyle;
  RiderColor _riderColor;
  String _emergencyContactName;
  String _emergencyContactPhone;
  String _medicalNotes;
  bool _shareIceWithLeaderByDefault;
  String _ownPhoneNumber;
  bool _onboardingCompleted;
  bool _onboardingEducationSkipped;
  OnboardingRideChoice? _pendingRideChoice;

  String get installationId => _installationId;
  String get displayName => _displayName;
  MotorcycleIconStyle get motorcycleStyle => _motorcycleStyle;
  RiderColor get riderColor => _riderColor;
  bool get onboardingCompleted => _onboardingCompleted;
  bool get needsOnboarding => !_onboardingCompleted;
  bool get onboardingEducationSkipped => _onboardingEducationSkipped;

  // In-case-of-emergency details. Kept device-local by default: not read by
  // RideSession/RideEvent, so ordinary ride events never carry it. It only
  // ever leaves the device through an explicit share action, or the opt-in
  // auto-share-with-leader setting below - both driven from RideController,
  // never automatically.
  String get emergencyContactName => _emergencyContactName;
  String get emergencyContactPhone => _emergencyContactPhone;
  String get medicalNotes => _medicalNotes;
  bool get hasEmergencyInfo =>
      _emergencyContactName.isNotEmpty ||
      _emergencyContactPhone.isNotEmpty ||
      _medicalNotes.isNotEmpty;

  /// If true, triggering an emergency-stop alert also shares this rider's
  /// ICE info with whoever currently holds the lead role, without a further
  /// explicit step - so it still happens if the rider can't act again.
  bool get shareIceWithLeaderByDefault => _shareIceWithLeaderByDefault;

  /// This rider's **own** phone number (issue #188). Emphatically not
  /// [emergencyContactPhone], which is their next of kin: the person to ring
  /// *about* them rather than the person to ring.
  ///
  /// Optional throughout, and empty until the rider types it. It is never
  /// inferred from the device (no SIM, no telephony subscription lookup) and
  /// never read from the contacts book, so an app that has been given nothing
  /// holds nothing. Like the ICE fields it is not read by RideSession or
  /// RideEvent, so no ordinary ride event can carry it; it leaves the device
  /// only through the explicit share action in RideController.
  String get ownPhoneNumber => _ownPhoneNumber;
  bool get hasOwnPhoneNumber => _ownPhoneNumber.isNotEmpty;

  static Future<RiderProfileController> load() async {
    final preferences = await SharedPreferences.getInstance();
    var installationId = preferences.getString(_installationIdKey);
    if (installationId == null || installationId.isEmpty) {
      installationId = const Uuid().v7();
      await preferences.setString(_installationIdKey, installationId);
    }
    final displayName = preferences.getString(_nameKey) ?? '';
    final onboardingCompleted =
        preferences.getBool(_onboardingCompletedKey) ?? displayName.isNotEmpty;
    if (!preferences.containsKey(_onboardingCompletedKey) &&
        onboardingCompleted) {
      await preferences.setBool(_onboardingCompletedKey, true);
    }
    return RiderProfileController._(
      preferences,
      installationId,
      displayName,
      motorcycleIconStyleFromName(preferences.getString(_styleKey)),
      riderColorFromName(preferences.getString(_colorKey)),
      preferences.getString(_emergencyContactNameKey) ?? '',
      preferences.getString(_emergencyContactPhoneKey) ?? '',
      preferences.getString(_medicalNotesKey) ?? '',
      preferences.getBool(_shareIceWithLeaderByDefaultKey) ?? false,
      preferences.getString(_ownPhoneNumberKey) ?? '',
      onboardingCompleted,
      preferences.getBool(_onboardingEducationSkippedKey) ?? false,
    );
  }

  Future<void> save({
    required String displayName,
    required MotorcycleIconStyle motorcycleStyle,
    required RiderColor riderColor,
  }) async {
    _displayName = displayName;
    _motorcycleStyle = motorcycleStyle;
    _riderColor = riderColor;
    await Future.wait([
      _preferences.setString(_nameKey, displayName),
      _preferences.setString(_styleKey, motorcycleStyle.name),
      _preferences.setString(_colorKey, riderColor.name),
    ]);
    notifyListeners();
  }

  Future<void> completeOnboarding({
    required String displayName,
    required MotorcycleIconStyle motorcycleStyle,
    required RiderColor riderColor,
    required bool educationSkipped,
    required OnboardingRideChoice rideChoice,
  }) async {
    final normalizedName = displayName.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(displayName, 'displayName', 'is required');
    }
    _displayName = normalizedName;
    _motorcycleStyle = motorcycleStyle;
    _riderColor = riderColor;
    _onboardingCompleted = true;
    _onboardingEducationSkipped = educationSkipped;
    _pendingRideChoice = rideChoice;
    await Future.wait([
      _preferences.setString(_nameKey, normalizedName),
      _preferences.setString(_styleKey, motorcycleStyle.name),
      _preferences.setString(_colorKey, riderColor.name),
      _preferences.setBool(_onboardingCompletedKey, true),
      _preferences.setBool(_onboardingEducationSkippedKey, educationSkipped),
    ]);
    notifyListeners();
  }

  Future<void> replayOnboarding() async {
    _onboardingCompleted = false;
    _pendingRideChoice = null;
    await _preferences.setBool(_onboardingCompletedKey, false);
    notifyListeners();
  }

  OnboardingRideChoice? takePendingRideChoice() {
    final choice = _pendingRideChoice;
    _pendingRideChoice = null;
    return choice;
  }

  Future<void> saveEmergencyInfo({
    required String emergencyContactName,
    required String emergencyContactPhone,
    required String medicalNotes,
    required bool shareWithLeaderByDefault,
  }) async {
    _emergencyContactName = emergencyContactName;
    _emergencyContactPhone = emergencyContactPhone;
    _medicalNotes = medicalNotes;
    _shareIceWithLeaderByDefault = shareWithLeaderByDefault;
    await Future.wait([
      _preferences.setString(_emergencyContactNameKey, emergencyContactName),
      _preferences.setString(_emergencyContactPhoneKey, emergencyContactPhone),
      _preferences.setString(_medicalNotesKey, medicalNotes),
      _preferences.setBool(
        _shareIceWithLeaderByDefaultKey,
        shareWithLeaderByDefault,
      ),
    ]);
    notifyListeners();
  }

  /// Saves this rider's own number, or clears it when [ownPhoneNumber] is empty.
  ///
  /// A separate call from [saveEmergencyInfo] on purpose: the ICE payload
  /// builder takes its arguments from that method, so there is no code path in
  /// which a rider's own number can be picked up and relayed as their next of
  /// kin's. Rejects anything that is not a plain dialable number rather than
  /// storing something that would later be handed to `tel:`.
  Future<void> saveOwnPhoneNumber(String ownPhoneNumber) async {
    final trimmed = ownPhoneNumber.trim();
    if (trimmed.isEmpty) {
      _ownPhoneNumber = '';
      await _preferences.remove(_ownPhoneNumberKey);
      notifyListeners();
      return;
    }
    final normalised = RiderContactShare.normalisePhoneNumber(trimmed);
    if (normalised == null) {
      throw ArgumentError.value(
        ownPhoneNumber,
        'ownPhoneNumber',
        'is not a phone number this app can dial',
      );
    }
    _ownPhoneNumber = normalised;
    await _preferences.setString(_ownPhoneNumberKey, normalised);
    notifyListeners();
  }
}

enum OnboardingRideChoice { create, join }
