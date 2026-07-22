import 'package:flutter/material.dart';

import '../../controllers/rider_profile_controller.dart';
import '../../domain/rider_color.dart';
import '../map/motorcycle_icon.dart';

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
            onChanged: (_) {
              if (_nameError != null) setState(() => _nameError = null);
            },
            decoration: InputDecoration(
              labelText: 'Rider name',
              counterText: '',
              errorText: _nameError,
            ),
          ),
          const SizedBox(height: 18),
          const Text('Your bike', style: TextStyle(color: Color(0xFFABB5C1))),
          const SizedBox(height: 8),
          SizedBox(
            height: 68,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: MotorcycleIconStyle.values.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final style = MotorcycleIconStyle.values[index];
                final selected = style == _style;
                return Semantics(
                  button: true,
                  selected: selected,
                  label: '${style.label} motorcycle icon',
                  child: InkWell(
                    key: Key('profile-bike-${style.name}'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() => _style = style),
                    child: Container(
                      width: 56,
                      decoration: BoxDecoration(
                        color: selected
                            ? _color.color.withValues(alpha: 0.16)
                            : const Color(0xFF1D2530),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: selected ? _color.color : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Center(
                        child: RiderMarkerBadge(
                          style: style,
                          badgeColor: _color.color,
                          size: 34,
                          borderWidth: 0,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
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
                              ? Colors.white
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
      riderColor: _color,
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _replayOnboarding() async {
    await widget.riderProfile.replayOnboarding();
    if (mounted) Navigator.of(context).pop();
  }
}
