import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/map_style_mode_controller.dart';
import '../../controllers/ride_code_preference_controller.dart';
import '../../controllers/ride_controller.dart';
import '../../controllers/rider_profile_controller.dart';
import '../../controllers/shared_route_controller.dart';
import '../../domain/join_invite.dart';
import '../../domain/recorded_route_store.dart';
import '../../domain/rider_color.dart';
import '../map/motorcycle_icon.dart';
import '../ride/route_recorder_screen.dart';
import '../settings/emergency_info_sheet.dart';
import '../settings/unit_settings_sheet.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.distanceUnits,
    required this.mapStyleMode,
    required this.rideCodePreference,
    required this.riderProfile,
    required this.sharedRoutes,
    required this.recordedRoutes,
  });

  final RideController controller;
  final DistanceUnitController distanceUnits;
  final MapStyleModeController mapStyleMode;
  final RideCodePreferenceController rideCodePreference;
  final RiderProfileController riderProfile;
  final SharedRouteController sharedRoutes;
  final RecordedRouteStore recordedRoutes;

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
                      if (sharedRoutes.pending case final file?) ...[
                        _PendingSharedRouteBanner(
                          fileName: file.name,
                          onDismiss: sharedRoutes.clearPending,
                        ),
                        const SizedBox(height: 20),
                      ],
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
                      TextButton.icon(
                        key: const Key('record-a-route-button'),
                        onPressed: () =>
                            RouteRecorderScreen.show(context, recordedRoutes),
                        icon: const Icon(Icons.fiber_manual_record_outlined),
                        label: const Text('Record a route'),
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
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Emergency info',
                    onPressed: () =>
                        EmergencyInfoSheet.show(context, riderProfile),
                    icon: const Icon(Icons.medical_information_outlined),
                  ),
                  IconButton(
                    tooltip: 'Settings',
                    onPressed: () => UnitSettingsSheet.show(
                      context,
                      distanceUnits,
                      mapStyleMode,
                    ),
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
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
        rideCodePreference: rideCodePreference,
        riderProfile: riderProfile,
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
        const Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              'TAIL END CHARLIE',
              maxLines: 1,
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
            ),
          ),
        ),
      ],
    );
  }
}

/// A GPX file opened from another app (Files, Mail, a route planner's share
/// sheet) has nowhere to go yet - there is no ride to attach a route to until
/// one exists. Surfaces that instead of silently discarding it.
class _PendingSharedRouteBanner extends StatelessWidget {
  const _PendingSharedRouteBanner({
    required this.fileName,
    required this.onDismiss,
  });

  final String fileName;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
    decoration: BoxDecoration(
      color: const Color(0xFF1D2530),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFF3B4654)),
    ),
    child: Row(
      children: [
        const Icon(Icons.map_outlined, color: Color(0xFFFFB15C)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Text(
                'Start or join a ride, then reopen it to use this route.',
                style: TextStyle(color: Color(0xFFABB5C1), fontSize: 12),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Dismiss',
          onPressed: onDismiss,
          icon: const Icon(Icons.close, size: 20),
        ),
      ],
    ),
  );
}

class _RideForm extends StatefulWidget {
  const _RideForm({
    required this.controller,
    required this.rideCodePreference,
    required this.riderProfile,
    required this.creating,
    required this.onComplete,
  });

  final RideController controller;
  final RideCodePreferenceController rideCodePreference;
  final RiderProfileController riderProfile;
  final bool creating;
  final VoidCallback onComplete;

  @override
  State<_RideForm> createState() => _RideFormState();
}

class _RideFormState extends State<_RideForm> with WidgetsBindingObserver {
  late final _nameController = TextEditingController(
    text: widget.riderProfile.displayName,
  );
  late final _codeController = TextEditingController(
    text: widget.creating ? null : widget.rideCodePreference.savedCode,
  );
  final _rideNameController = TextEditingController();
  final _codeFocusNode = FocusNode();
  final _codeFieldKey = GlobalKey();
  late MotorcycleIconStyle _selectedStyle = widget.riderProfile.motorcycleStyle;
  late RiderColor _selectedColor = widget.riderProfile.riderColor;

  /// Set once a created ride's code needs sharing before handing off to the
  /// map - the moment a leader most needs it, with people waiting nearby.
  bool _showShareStep = false;

  /// Captured when pasted text includes a join token alongside the six
  /// digits - see [parseJoinInvite]. Typing the code by hand leaves this
  /// null, which still works but only via the rate-limited fallback.
  String? _pastedJoinToken;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _codeFocusNode.addListener(_keepCodeFieldVisible);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _codeFocusNode.removeListener(_keepCodeFieldVisible);
    _codeFocusNode.dispose();
    _nameController.dispose();
    _codeController.dispose();
    _rideNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_showShareStep) {
      return _ShareCodeStep(
        controller: widget.controller,
        onContinue: _finishCreating,
      );
    }
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.controller,
        widget.rideCodePreference,
      ]),
      builder: (context, _) => AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          key: const Key('ride-form-scroll-view'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
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
              if (widget.creating) ...[
                TextField(
                  controller: _rideNameController,
                  maxLength: 32,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Ride name (optional)',
                    hintText: 'e.g. Sunday coast run',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const Key('rider-name-field'),
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
              const SizedBox(height: 16),
              const Text(
                'Your bike',
                style: TextStyle(color: Color(0xFFABB5C1)),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 68,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: MotorcycleIconStyle.values.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final style = MotorcycleIconStyle.values[index];
                    final selected = style == _selectedStyle;
                    return Tooltip(
                      message: style.label,
                      child: InkWell(
                        key: Key('bike-style-${style.name}'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setState(() => _selectedStyle = style),
                        child: Container(
                          width: 56,
                          decoration: BoxDecoration(
                            color: selected
                                ? _selectedColor.color.withValues(alpha: 0.16)
                                : const Color(0xFF1D2530),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: selected
                                  ? _selectedColor.color
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: Center(
                            child: RiderMarkerBadge(
                              style: style,
                              badgeColor: _selectedColor.color,
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
              const SizedBox(height: 16),
              const Text(
                'Your colour',
                style: TextStyle(color: Color(0xFFABB5C1)),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: RiderColor.values.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final riderColor = RiderColor.values[index];
                    final selected = riderColor == _selectedColor;
                    return Tooltip(
                      message: riderColor.label,
                      child: InkWell(
                        key: Key('rider-colour-${riderColor.name}'),
                        customBorder: const CircleBorder(),
                        onTap: () =>
                            setState(() => _selectedColor = riderColor),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: riderColor.color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected
                                  ? Colors.white
                                  : Colors.transparent,
                              width: 2.5,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Lead and Tail End Charlie always show in their own reserved colours, whatever you pick here.',
                  style: TextStyle(color: Color(0xFF7F8A98), fontSize: 12),
                ),
              ),
              if (!widget.creating) ...[
                const SizedBox(height: 12),
                KeyedSubtree(
                  key: _codeFieldKey,
                  child: TextField(
                    key: const Key('ride-code-field'),
                    controller: _codeController,
                    focusNode: _codeFocusNode,
                    scrollPadding: const EdgeInsets.only(bottom: 112),
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (!widget.controller.busy) _submit();
                    },
                    autocorrect: false,
                    maxLength: 6,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Six-digit ride code',
                      hintText: '123456',
                      helperText: widget.rideCodePreference.savedCode == null
                          ? null
                          : 'Saved from your last successful join',
                      counterText: '',
                      suffixIcon: IconButton(
                        tooltip: 'Paste ride code',
                        onPressed: _pasteRideCode,
                        icon: const Icon(Icons.content_paste),
                      ),
                    ),
                  ),
                ),
                CheckboxListTile(
                  key: const Key('keep-ride-code'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: widget.rideCodePreference.keepCode,
                  onChanged: (value) {
                    if (value != null) {
                      widget.rideCodePreference.setKeepCode(value);
                    }
                  },
                  title: const Text('Keep this code for next time'),
                  subtitle: const Text(
                    'Only the six-digit code is saved. Invitation secrets are not.',
                  ),
                ),
                if (widget.rideCodePreference.savedCode != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('forget-saved-ride-code'),
                      onPressed: _forgetSavedCode,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Forget saved code'),
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
      ),
    );
  }

  Future<void> _submit() async {
    final name = _nameController.text;
    if (widget.creating) {
      await widget.controller.createRide(
        name,
        motorcycleStyle: _selectedStyle,
        riderColor: _selectedColor,
        rideName: _rideNameController.text,
      );
    } else {
      final code = _codeController.text.trim();
      await widget.controller.joinRide(
        code,
        name,
        motorcycleStyle: _selectedStyle,
        riderColor: _selectedColor,
        joinToken: _pastedJoinToken,
      );
      if (widget.controller.hasActiveRide) {
        await widget.rideCodePreference.rememberSuccessfulJoin(code);
      } else if (widget.controller.errorMessage?.startsWith(
            'That ride code is not active.',
          ) ??
          false) {
        await widget.rideCodePreference.clearIfInactive(code);
      }
    }
    if (widget.controller.hasActiveRide && mounted) {
      await widget.riderProfile.save(
        displayName: name.trim(),
        motorcycleStyle: _selectedStyle,
        riderColor: _selectedColor,
      );
      if (widget.creating) {
        setState(() => _showShareStep = true);
      } else {
        widget.onComplete();
      }
    }
  }

  void _finishCreating() => widget.onComplete();

  @override
  void didChangeMetrics() {
    if (!_codeFocusNode.hasFocus) return;
    Future<void>.delayed(const Duration(milliseconds: 220), () {
      if (mounted) _keepCodeFieldVisible();
    });
  }

  void _keepCodeFieldVisible() {
    if (!_codeFocusNode.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final fieldContext = _codeFieldKey.currentContext;
      if (!mounted || fieldContext == null) return;
      Scrollable.ensureVisible(
        fieldContext,
        alignment: 0.55,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _forgetSavedCode() async {
    final savedCode = widget.rideCodePreference.savedCode;
    await widget.rideCodePreference.clear();
    if (_codeController.text == savedCode) _codeController.clear();
  }

  Future<void> _pasteRideCode() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    final invite = parseJoinInvite(text);
    final code = invite.code ?? text;
    _pastedJoinToken = invite.token;
    _codeController.text = code;
    _codeController.selection = TextSelection.collapsed(offset: code.length);
  }
}

/// Shown immediately after creating a ride - the moment a leader most needs
/// the code, with riders waiting nearby, rather than requiring a trip
/// through the ride menu to "Ride details" to find it.
class _ShareCodeStep extends StatelessWidget {
  const _ShareCodeStep({required this.controller, required this.onContinue});

  final RideController controller;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final session = controller.session;
    final code = session?.rideCode ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF6ED89A), size: 40),
          const SizedBox(height: 16),
          Text(
            session?.rideName ?? 'Ride created',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Share this code so the group can join.',
            style: TextStyle(color: Color(0xFFABB5C1)),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              color: const Color(0xFF111720),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF2A3441)),
            ),
            child: Center(
              child: Text(
                code,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 34,
                  letterSpacing: 6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: code)),
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => SharePlus.instance.share(
                    ShareParams(
                      text: controller.rideCodeShareText,
                      subject: 'Join my Tail End Charlie group',
                    ),
                  ),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          TextButton(
            onPressed: onContinue,
            child: const Text('Continue to ride'),
          ),
        ],
      ),
    );
  }
}
