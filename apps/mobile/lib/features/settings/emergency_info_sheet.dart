import 'package:flutter/material.dart';

import '../../controllers/rider_profile_controller.dart';
import '../../services/rider_contact_share.dart';

/// Editor for in-case-of-emergency details, and for the rider's own number.
/// Stored in [RiderProfileController]'s SharedPreferences and kept off
/// ordinary ride events by default. It only leaves the device via an explicit
/// share action or the opt-in "share with the leader by default" setting below,
/// both driven from RideController - never as a side effect of anything else.
///
/// The two numbers on this sheet are different things and are kept visibly
/// apart: "your own number" is the rider, "emergency contact" is their next of
/// kin. Sharing one never shares the other, and the auto-share checkbox belongs
/// to the ICE block alone.
class EmergencyInfoSheet extends StatefulWidget {
  const EmergencyInfoSheet({super.key, required this.riderProfile});

  final RiderProfileController riderProfile;

  static Future<void> show(
    BuildContext context,
    RiderProfileController riderProfile,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => EmergencyInfoSheet(riderProfile: riderProfile),
  );

  @override
  State<EmergencyInfoSheet> createState() => _EmergencyInfoSheetState();
}

class _EmergencyInfoSheetState extends State<EmergencyInfoSheet> {
  late final _nameController = TextEditingController(
    text: widget.riderProfile.emergencyContactName,
  );
  late final _phoneController = TextEditingController(
    text: widget.riderProfile.emergencyContactPhone,
  );
  late final _notesController = TextEditingController(
    text: widget.riderProfile.medicalNotes,
  );
  late final _ownPhoneController = TextEditingController(
    text: widget.riderProfile.ownPhoneNumber,
  );
  late bool _shareWithLeaderByDefault =
      widget.riderProfile.shareIceWithLeaderByDefault;
  bool _saving = false;
  String? _ownPhoneError;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _notesController.dispose();
    _ownPhoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(
      22,
      4,
      22,
      28 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Emergency info',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text(
          'Kept on this device by default - not sent over the network unless '
          'you explicitly share it or trigger an emergency alert with '
          'sharing switched on below. Visible to anyone with this phone '
          'unlocked.',
          style: TextStyle(color: Color(0xFF98A3B1)),
        ),
        const SizedBox(height: 20),
        Text(
          'YOUR OWN NUMBER',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: const Color(0xFF8D98A7),
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('rider-own-phone'),
          controller: _ownPhoneController,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            labelText: 'Your phone number (optional)',
            errorText: _ownPhoneError,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Optional, and blank unless you type it - the app never reads it from '
          'your SIM or your contacts. Once a ride is running you can offer it '
          'to the ride leader and Tail End Charlie from the Ride page, so they '
          'can ring you if you stop. Nobody gets it until you send it, and it '
          'is cleared from their phone when the ride ends.',
          style: TextStyle(color: Color(0xFF98A3B1)),
        ),
        const Divider(height: 32),
        Text(
          'EMERGENCY CONTACT',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: const Color(0xFF8D98A7),
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Someone to ring about you - not your own number.',
          style: TextStyle(color: Color(0xFF98A3B1)),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('emergency-contact-name'),
          controller: _nameController,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Emergency contact name',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('emergency-contact-phone'),
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Emergency contact phone',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('emergency-medical-notes'),
          controller: _notesController,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Medical notes (optional)',
            hintText: 'Allergies, conditions, blood type, ...',
          ),
        ),
        const SizedBox(height: 4),
        CheckboxListTile(
          key: const Key('emergency-info-share-with-leader-default'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _shareWithLeaderByDefault,
          onChanged: (value) =>
              setState(() => _shareWithLeaderByDefault = value ?? false),
          title: const Text('Share automatically with the ride leader'),
          subtitle: const Text(
            'If you send an emergency-stop alert, this info goes straight '
            'to whoever is currently the leader - useful if you can\'t take '
            'a further step yourself. You can also share it with the whole '
            'group at any time from the Ride page.',
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('emergency-info-save'),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    ),
  );

  Future<void> _save() async {
    final ownPhone = _ownPhoneController.text.trim();
    if (ownPhone.isNotEmpty &&
        RiderContactShare.normalisePhoneNumber(ownPhone) == null) {
      setState(
        () => _ownPhoneError =
            'Enter a number the phone can dial - digits, and optionally a '
            'leading +.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _ownPhoneError = null;
    });
    await widget.riderProfile.saveEmergencyInfo(
      emergencyContactName: _nameController.text.trim(),
      emergencyContactPhone: _phoneController.text.trim(),
      medicalNotes: _notesController.text.trim(),
      shareWithLeaderByDefault: _shareWithLeaderByDefault,
    );
    // Separate call, separate field: an ICE payload is built only from the
    // arguments above, so a rider's own number can never travel as their next
    // of kin's.
    await widget.riderProfile.saveOwnPhoneNumber(ownPhone);
    if (mounted) Navigator.of(context).pop();
  }
}
