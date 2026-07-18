import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/ride_controller.dart';
import '../settings/unit_settings_sheet.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.distanceUnits,
  });

  final RideController controller;
  final DistanceUnitController distanceUnits;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 36),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _BrandMark(),
                      const SizedBox(height: 56),
                      Text(
                        'Ready to ride?',
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Create a group or join with a six-digit ride code. You will go '
                        'straight to the navigation map.',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: const Color(0xFFB7C0CC),
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 40),
                      FilledButton.icon(
                        onPressed: controller.busy
                            ? null
                            : () => _showRideSheet(context, creating: true),
                        icon: const Icon(Icons.add_road),
                        label: const Text('Create a ride'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: controller.busy
                            ? null
                            : () => _showRideSheet(context, creating: false),
                        icon: const Icon(Icons.group_add_outlined),
                        label: const Text('Join a ride'),
                      ),
                      const SizedBox(height: 12),
                      TextButton.icon(
                        key: const Key('start-ride-simulator'),
                        onPressed: controller.busy
                            ? null
                            : controller.createSimulationRide,
                        icon: const Icon(Icons.science_outlined),
                        label: const Text('Try a simulated ride'),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'No account required · the simulator never shares location',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF7F8A98),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 8,
              child: IconButton(
                tooltip: 'Settings',
                onPressed: () => UnitSettingsSheet.show(context, distanceUnits),
                icon: const Icon(Icons.settings_outlined),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRideSheet(
    BuildContext context, {
    required bool creating,
  }) async {
    controller.clearError();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF171D25),
      builder: (sheetContext) => _RideForm(
        controller: controller,
        creating: creating,
        onComplete: () => Navigator.of(sheetContext).pop(),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(13),
          ),
          child: const Icon(Icons.flag_outlined, color: Colors.black),
        ),
        const SizedBox(width: 13),
        const Text(
          'TAIL END CHARLIE',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
        ),
      ],
    );
  }
}

class _RideForm extends StatefulWidget {
  const _RideForm({
    required this.controller,
    required this.creating,
    required this.onComplete,
  });

  final RideController controller;
  final bool creating;
  final VoidCallback onComplete;

  @override
  State<_RideForm> createState() => _RideFormState();
}

class _RideFormState extends State<_RideForm> {
  final _nameController = TextEditingController();
  final _codeController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          22,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.creating ? 'Create a private ride' : 'Join your group',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              widget.creating
                  ? 'You will become the ride lead and get a six-digit code to share.'
                  : 'Enter the six-digit code shared by the ride lead. You need a connection once to join, then the app keeps using the secure relay.',
              style: const TextStyle(color: Color(0xFFABB5C1)),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nameController,
              autofocus: true,
              maxLength: 24,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Rider name',
                hintText: 'How the group will recognise you',
                counterText: '',
              ),
            ),
            if (!widget.creating) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                autocorrect: false,
                maxLength: 6,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                decoration: InputDecoration(
                  labelText: 'Six-digit ride code',
                  hintText: '123456',
                  counterText: '',
                  suffixIcon: IconButton(
                    tooltip: 'Paste ride code',
                    onPressed: _pasteRideCode,
                    icon: const Icon(Icons.content_paste),
                  ),
                ),
              ),
            ],
            if (widget.controller.errorMessage case final String message) ...[
              const SizedBox(height: 12),
              Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 22),
            FilledButton(
              onPressed: widget.controller.busy ? null : _submit,
              child: widget.controller.busy
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(widget.creating ? 'Create ride' : 'Join ride'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (widget.creating) {
      await widget.controller.createRide(_nameController.text);
    } else {
      await widget.controller.joinRide(
        _codeController.text,
        _nameController.text,
      );
    }
    if (widget.controller.hasActiveRide && mounted) {
      widget.onComplete();
    }
  }

  Future<void> _pasteRideCode() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    _codeController.text = text;
    _codeController.selection = TextSelection.collapsed(offset: text.length);
  }
}
