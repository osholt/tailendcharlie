import 'package:flutter/material.dart';

import '../../controllers/rider_profile_controller.dart';
import '../../domain/rider_color.dart';
import '../map/motorcycle_icon.dart';
import '../map/rider_symbol_picker.dart';

class RiderProfileSheet extends StatefulWidget {
  const RiderProfileSheet({
    super.key,
    required this.riderProfile,
    required this.currentRideActive,
  });

  final RiderProfileController riderProfile;
  final bool currentRideActive;

  static Future<void> show(
    BuildContext context,
    RiderProfileController riderProfile, {
    bool currentRideActive = false,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => RiderProfileSheet(
      riderProfile: riderProfile,
      currentRideActive: currentRideActive,
    ),
  );

  @override
  State<RiderProfileSheet> createState() => _RiderProfileSheetState();
}

class _RiderProfileSheetState extends State<RiderProfileSheet> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.riderProfile.displayName,
  );
  late MotorcycleIconStyle _style = widget.riderProfile.motorcycleStyle;
  late RiderSymbol _symbol = widget.riderProfile.riderSymbol;
  late RiderColor _color = widget.riderProfile.riderColor;
  String? _nameError;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedPadding(
    duration: const Duration(milliseconds: 180),
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Rider profile',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            widget.currentRideActive
                ? 'Changes are saved for your next ride. Your current ride keeps the identity you joined with so the roster stays consistent.'
                : 'This identity is prefilled for your next ride.',
            style: const TextStyle(color: Color(0xFFABB5C1), height: 1.4),
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('profile-name-field'),
            controller: _nameController,
            maxLength: 24,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() => _nameError = null),
            decoration: InputDecoration(
              labelText: 'Rider name',
              counterText: '',
              errorText: _nameError,
            ),
          ),
          const SizedBox(height: 18),
          RiderSymbolPicker(
            displayName: _nameController.text,
            selectedSymbol: _symbol,
            motorcycleStyle: _style,
            badgeColor: _color.color,
            keyPrefix: 'profile-symbol',
            bikeKeyPrefix: 'profile-bike',
            onSymbolChanged: (symbol) => setState(() => _symbol = symbol),
            onMotorcycleStyleChanged: (style) => setState(() => _style = style),
          ),
          const SizedBox(height: 18),
          const Text('Your colour', style: TextStyle(color: Color(0xFFABB5C1))),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final color in RiderColor.values)
                Semantics(
                  button: true,
                  selected: color == _color,
                  label: '${color.label} rider colour',
                  child: InkWell(
                    key: Key('profile-colour-${color.name}'),
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _color = color),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: color.color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color == _color
                              ? riderBadgeStrokeColor(color.color)
                              : Colors.transparent,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('save-rider-profile'),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save profile'),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            key: const Key('replay-onboarding'),
            onPressed: _saving ? null : _replayOnboarding,
            icon: const Icon(Icons.replay_outlined),
            label: Text(
              widget.currentRideActive
                  ? 'Replay guide after this ride'
                  : 'Replay setup guide',
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Enter the name your group will recognise.');
      return;
    }
    setState(() => _saving = true);
    await widget.riderProfile.save(
      displayName: name,
      motorcycleStyle: _style,
      riderSymbol: _symbol,
      riderColor: _color,
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _replayOnboarding() async {
    await widget.riderProfile.replayOnboarding();
    if (mounted) Navigator.of(context).pop();
  }
}
