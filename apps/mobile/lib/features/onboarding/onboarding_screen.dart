import 'package:flutter/material.dart';

import '../../controllers/global_ride_heatmap_controller.dart';
import '../../controllers/rider_profile_controller.dart';
import '../../domain/rider_color.dart';
import '../../services/global_ride_heatmap.dart';
import '../map/motorcycle_icon.dart';
import '../map/rider_symbol_picker.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.riderProfile,
    this.globalRideHeatmap,
  });

  final RiderProfileController riderProfile;
  final GlobalRideHeatmapController? globalRideHeatmap;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _stepCount = 6;

  late final TextEditingController _nameController = TextEditingController(
    text: widget.riderProfile.displayName,
  );
  late MotorcycleIconStyle _motorcycleStyle =
      widget.riderProfile.motorcycleStyle;
  late RiderSymbol _riderSymbol = widget.riderProfile.riderSymbol;
  late RiderColor _riderColor = widget.riderProfile.riderColor;
  int _step = 0;
  bool _educationSkipped = false;
  bool _permissionsDeferred = false;
  late bool _shareGlobalHeatmap =
      widget.globalRideHeatmap?.consent != HeatmapContributionConsent.never;
  String? _nameError;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: false,
      title: const Text(
        'Set up Tail End Charlie',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 18),
          child: Center(
            child: Semantics(
              label: 'Onboarding step ${_step + 1} of $_stepCount',
              child: Text(
                '${_step + 1}/$_stepCount',
                style: const TextStyle(color: Color(0xFFABB5C1)),
              ),
            ),
          ),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            children: [
              LinearProgressIndicator(value: (_step + 1) / _stepCount),
              Expanded(
                child: SingleChildScrollView(
                  key: const Key('onboarding-scroll-view'),
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: KeyedSubtree(
                      key: ValueKey(_step),
                      child: _stepContent(context),
                    ),
                  ),
                ),
              ),
              if (_step < _stepCount - 1) _navigationBar(context),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _stepContent(BuildContext context) => switch (_step) {
    0 => _welcome(context),
    1 => _profile(context),
    2 => _rideWalkthrough(context),
    3 => _permissions(context),
    4 => _heatmapPrivacy(context),
    _ => _finish(context),
  };

  Widget _welcome(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Icon(
        Icons.flag_outlined,
        size: 64,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(height: 28),
      Text(
        'Keep the whole ride together',
        style: Theme.of(context).textTheme.displaySmall,
      ),
      const SizedBox(height: 16),
      const Text(
        'Tail End Charlie coordinates a private riding group with a shared '
        'roster, route and safety alerts. Ride events are kept on your phone '
        'first, then relayed by the internet or nearby devices when available.',
        style: TextStyle(color: Color(0xFFBCC5D0), height: 1.5, fontSize: 17),
      ),
      const SizedBox(height: 24),
      const _InfoCard(
        icon: Icons.person_off_outlined,
        title: 'No account required',
        body: 'No email, password or unnecessary personal details.',
      ),
      const SizedBox(height: 12),
      const _InfoCard(
        icon: Icons.cloud_off_outlined,
        title: 'Designed for patchy coverage',
        body: 'Losing a relay does not erase the ride journal on your phone.',
      ),
    ],
  );

  Widget _profile(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'How the group sees you',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 10),
      const Text(
        'Your saved name, symbol and colour are prefilled whenever you create or join a ride.',
        style: TextStyle(color: Color(0xFFABB5C1), height: 1.4),
      ),
      const SizedBox(height: 24),
      TextField(
        key: const Key('onboarding-name-field'),
        controller: _nameController,
        maxLength: 24,
        textCapitalization: TextCapitalization.words,
        onChanged: (_) => setState(() => _nameError = null),
        decoration: InputDecoration(
          labelText: 'Rider name',
          hintText: 'How the group will recognise you',
          counterText: '',
          errorText: _nameError,
        ),
      ),
      const SizedBox(height: 20),
      _profilePreview(),
      const SizedBox(height: 24),
      RiderSymbolPicker(
        displayName: _nameController.text,
        selectedSymbol: _riderSymbol,
        motorcycleStyle: _motorcycleStyle,
        badgeColor: _riderColor.color,
        keyPrefix: 'onboarding-symbol',
        bikeKeyPrefix: 'onboarding-bike',
        onSymbolChanged: (symbol) => setState(() => _riderSymbol = symbol),
        onMotorcycleStyleChanged: (style) =>
            setState(() => _motorcycleStyle = style),
      ),
      const SizedBox(height: 20),
      const Text('Your colour', style: TextStyle(color: Color(0xFFABB5C1))),
      const SizedBox(height: 10),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final color in RiderColor.values)
            Semantics(
              button: true,
              selected: color == _riderColor,
              label: '${color.label} rider colour',
              child: InkWell(
                key: Key('onboarding-colour-${color.name}'),
                customBorder: const CircleBorder(),
                onTap: () => setState(() => _riderColor = color),
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: color.color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: color == _riderColor
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
      const SizedBox(height: 14),
      const Text(
        'Lead and Tail End Charlie use reserved role colours during a ride.',
        style: TextStyle(color: Color(0xFF7F8A98), fontSize: 12),
      ),
    ],
  );

  Widget _profilePreview() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          RiderMarkerBadge(
            style: _motorcycleStyle,
            symbol: _riderSymbol,
            displayName: _nameController.text,
            badgeColor: _riderColor.color,
            size: 48,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _nameController.text.trim().isEmpty
                      ? 'Your rider name'
                      : _nameController.text.trim(),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${_riderSymbol.label(_nameController.text, _motorcycleStyle)} · ${_riderColor.label}',
                  style: const TextStyle(color: Color(0xFFABB5C1)),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _rideWalkthrough(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'One group, clear roles',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 14),
      const _InfoCard(
        icon: Icons.route_outlined,
        title: 'Lead',
        body:
            'Creates the private code, publishes the group route, starts, pauses and ends the ride.',
      ),
      const SizedBox(height: 10),
      const _InfoCard(
        icon: Icons.two_wheeler,
        title: 'Rider',
        body:
            'Follows the shared route and can send status, assistance and hazard markers.',
      ),
      const SizedBox(height: 10),
      const _InfoCard(
        icon: Icons.flag_outlined,
        title: 'Tail End Charlie',
        body:
            'Closes the group and helps identify riders who may have dropped back.',
      ),
      const SizedBox(height: 24),
      Text('The ride flow', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      const _NumberedStep(
        number: '1',
        text: 'Create or join with the private six-digit ride code.',
      ),
      const _NumberedStep(
        number: '2',
        text:
            'Check the pre-start roster. Tracking waits for the lead to tap Start ride.',
      ),
      const _NumberedStep(
        number: '3',
        text:
            'Use the map, roster and marker controls for route, SOS, assistance and hazards.',
      ),
      const _NumberedStep(
        number: '4',
        text:
            'Leave stops sharing for you; End ride is a lead-only group action.',
      ),
      const SizedBox(height: 14),
      const Text(
        'Treat the ride code like a private invitation. Only share it with riders you expect.',
        style: TextStyle(color: Color(0xFFFFC47A), height: 1.4),
      ),
    ],
  );

  Widget _permissions(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Connections and permissions',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 12),
      const Text(
        'Internet and nearby-device relays can overlap. “Active” means a rider was seen recently; “stale” means the last signed update is older. The roster shows the evidence it actually has.',
        style: TextStyle(color: Color(0xFFBCC5D0), height: 1.5),
      ),
      const SizedBox(height: 20),
      const _PermissionCard(
        icon: Icons.location_on_outlined,
        title: 'Location while using the app',
        body:
            'Requested when you start foreground ride tracking or ask the map to use your position.',
      ),
      const SizedBox(height: 10),
      const _PermissionCard(
        icon: Icons.bluetooth_outlined,
        title: 'Bluetooth and nearby devices',
        body:
            'Requested when an installed app starts the nearby relay for a live ride.',
      ),
      const SizedBox(height: 10),
      const _PermissionCard(
        icon: Icons.notifications_none,
        title: 'Notifications',
        body:
            'Requested when you join a live ride if encrypted push delivery is configured. Lock-screen alerts omit coordinates, invitation secrets and medical details.',
      ),
      const SizedBox(height: 18),
      OutlinedButton.icon(
        key: const Key('defer-onboarding-permissions'),
        onPressed: () => setState(() => _permissionsDeferred = true),
        icon: const Icon(Icons.schedule_outlined),
        label: const Text('Not now'),
      ),
      if (_permissionsDeferred) ...[
        const SizedBox(height: 14),
        Container(
          key: const Key('permission-degraded-path'),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF241E17),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF6F5739)),
          ),
          child: const Text(
            'You can still create or join a ride. Without location, your live position is unavailable; without nearby access, internet relay may still work. Retry from the feature, or restore blocked access in iOS or Android Settings.',
            style: TextStyle(color: Color(0xFFFFD39C), height: 1.4),
          ),
        ),
      ],
      const SizedBox(height: 18),
      const Text(
        'Background delivery is best-effort and depends on platform and device settings. Durable in-app alerts remain the source of truth and push is not an emergency-service substitute.',
        style: TextStyle(color: Color(0xFF98A3B1), height: 1.4),
      ),
    ],
  );

  Widget _heatmapPrivacy(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Help build better riding maps',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 12),
      const Text(
        'Your personal ride heatmap always stays on this phone. You can also '
        'contribute privacy-reduced road coverage to the global heatmap so '
        'riders can discover roads the community actually uses.',
        style: TextStyle(color: Color(0xFFBCC5D0), height: 1.5),
      ),
      const SizedBox(height: 20),
      Card(
        child: SwitchListTile.adaptive(
          key: const Key('onboarding-global-heatmap-contribution'),
          value: _shareGlobalHeatmap,
          onChanged: (value) => setState(() => _shareGlobalHeatmap = value),
          secondary: const Icon(Icons.local_fire_department_outlined),
          title: const Text('Contribute completed rides'),
          subtitle: const Text(
            'On by default. You can turn this off at any time in Settings.',
          ),
        ),
      ),
      const SizedBox(height: 18),
      const _InfoCard(
        icon: Icons.privacy_tip_outlined,
        title: 'Coverage, not ride histories',
        body:
            'The first and last 1 km are removed on your phone. The app sends unordered coarse cells with no ride name, route order, time, speed, rider identity or ride code.',
      ),
      const SizedBox(height: 12),
      const _InfoCard(
        icon: Icons.groups_outlined,
        title: 'Three contributors before anything appears',
        body:
            'A road remains hidden from the public global heatmap until at least three separate contribution credentials overlap there.',
      ),
      const SizedBox(height: 16),
      const Text(
        'Settings also lets you change the hidden distance, share existing '
        'saved rides in bulk, or stop contributing and remove data linked to '
        'this phone’s heatmap credential.',
        style: TextStyle(color: Color(0xFF98A3B1), height: 1.4),
      ),
    ],
  );

  Widget _finish(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Icon(
        Icons.check_circle_outline,
        size: 64,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(height: 24),
      Text(
        'You are ready to ride',
        style: Theme.of(context).textTheme.displaySmall,
      ),
      const SizedBox(height: 12),
      Text(
        '${_nameController.text.trim()}, you are set up. Go straight to the map, or start a ride now. You can edit your profile or replay this guide from Settings.',
        style: const TextStyle(color: Color(0xFFBCC5D0), height: 1.5),
      ),
      const SizedBox(height: 28),
      // The primary way out, because it is the one that commits to nothing.
      // #405 and #426 made the map the surface a rider lands on before any
      // decision — "I don't want the start screen at all" — and this screen
      // was still holding the old gate at the end of setup, insisting on a
      // ride before it would let anybody through (#598).
      FilledButton.icon(
        key: const Key('onboarding-free-roam'),
        onPressed: _saving ? null : () => _complete(null),
        icon: const Icon(Icons.map_outlined),
        label: const Text('Take me to the map'),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        key: const Key('onboarding-create-ride'),
        onPressed: _saving
            ? null
            : () => _complete(OnboardingRideChoice.create),
        icon: const Icon(Icons.add_road),
        label: const Text('Create a ride'),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        key: const Key('onboarding-join-ride'),
        onPressed: _saving ? null : () => _complete(OnboardingRideChoice.join),
        icon: const Icon(Icons.group_add_outlined),
        label: const Text('Join a ride'),
      ),
      if (_saving) ...[
        const SizedBox(height: 20),
        const Center(child: CircularProgressIndicator()),
      ],
    ],
  );

  Widget _navigationBar(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_step >= 1 && _step <= 3)
          TextButton(
            key: const Key('skip-onboarding-tour'),
            onPressed: _skipEducation,
            child: const Text('Skip tour'),
          ),
        Row(
          children: [
            if (_step > 0)
              TextButton.icon(
                onPressed: () => setState(() => _step -= 1),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back'),
              ),
            const Spacer(),
            FilledButton(
              key: const Key('onboarding-continue'),
              onPressed: _continue,
              child: const Text('Continue'),
            ),
          ],
        ),
      ],
    ),
  );

  void _continue() {
    if (_step == 1 && !_validateName()) return;
    setState(() => _step += 1);
  }

  void _skipEducation() {
    if (!_validateName()) {
      setState(() => _step = 1);
      return;
    }
    setState(() {
      _educationSkipped = true;
      // The product tour is skippable; the default-on data choice is not
      // hidden behind that shortcut.
      _step = 4;
    });
  }

  bool _validateName() {
    if (_nameController.text.trim().isNotEmpty) return true;
    setState(() => _nameError = 'Enter the name your group will recognise.');
    return false;
  }

  Future<void> _complete(OnboardingRideChoice? choice) async {
    if (!_validateName()) return;
    setState(() => _saving = true);
    await widget.globalRideHeatmap?.setConsent(
      _shareGlobalHeatmap
          ? HeatmapContributionConsent.always
          : HeatmapContributionConsent.never,
    );
    await widget.riderProfile.completeOnboarding(
      displayName: _nameController.text,
      motorcycleStyle: _motorcycleStyle,
      riderSymbol: _riderSymbol,
      riderColor: _riderColor,
      educationSkipped: _educationSkipped,
      rideChoice: choice,
    );
    if (mounted) setState(() => _saving = false);
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(color: Color(0xFFABB5C1), height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _PermissionCard extends _InfoCard {
  const _PermissionCard({
    required super.icon,
    required super.title,
    required super.body,
  });
}

class _NumberedStep extends StatelessWidget {
  const _NumberedStep({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Colors.black,
          child: Text(
            number,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
      ],
    ),
  );
}
