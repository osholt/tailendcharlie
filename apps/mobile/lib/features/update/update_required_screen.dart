import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../controllers/app_update_gate_controller.dart';
import '../../services/build_identity.dart';
import '../settings/about_build_sheet.dart';

const _warning = Color(0xFFFFC857);

/// Whether the full-screen "update required" explanation may be opened now.
///
/// Never over a ride (an active ride, or one being restored): a rider who is out
/// on the road does not get an interstitial, and the in-ride status card carries
/// the same message and link. Never twice in one launch, and never unless the
/// relay has actually refused this build.
bool shouldOfferUpdateScreen({
  required AppUpdateGateController gate,
  required bool hasActiveRide,
  required bool restoring,
}) => gate.updateRequired && !gate.presented && !hasActiveRide && !restoring;

/// Tells a rider on a build the ride service no longer supports to update, with
/// the right store or TestFlight link for *this* build (#37).
///
/// It is a screen the rider can always leave. Nothing about it is modal in the
/// safety sense: it is never opened over a ride in progress, it has a plain
/// "Continue without updating" and an ordinary back gesture, and it says in
/// words what the gate does and does not touch. The gate only stops sharing
/// through the ride service; SOS, the alert controls, navigation, recording and
/// the local ride journal are not consulted by it at all.
class UpdateRequiredScreen extends StatelessWidget {
  const UpdateRequiredScreen({
    super.key,
    required this.identity,
    required this.state,
    this.openUri = _launchExternally,
  });

  final BuildIdentity identity;
  final UpdateGateState state;

  /// Opens the update page. Injected so a test does not launch a browser.
  final Future<bool> Function(Uri uri) openUri;

  /// Opens the screen full-height over whatever is below it.
  static Future<void> show(
    BuildContext context, {
    required BuildIdentity identity,
    required UpdateGateState state,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => UpdateRequiredScreen(identity: identity, state: state),
    ),
  );

  Uri? get _destination => identity.updateDestination(state.relayUpdateUri);

  /// "You have build 98. The ride service now needs build 103 or newer." when
  /// both numbers are known, otherwise just what this build says it is.
  String get _versionLine {
    final minimum = state.minimumBuild;
    final build = state.clientBuild;
    if (minimum != null && build != null) {
      return 'You have build $build. The ride service now needs build $minimum '
          'or newer.';
    }
    return identity.reportsVersion
        ? 'You have ${identity.versionLabel}.'
        : identity.versionLabel;
  }

  @override
  Widget build(BuildContext context) {
    final destination = _destination;
    final theme = Theme.of(context);
    return Scaffold(
      key: const Key('update-required-screen'),
      appBar: AppBar(
        title: const Text('Update required'),
        leading: IconButton(
          key: const Key('update-required-close'),
          tooltip: 'Continue without updating',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            const Icon(Icons.system_update_alt, size: 40, color: _warning),
            const SizedBox(height: 14),
            Text(
              'This version of Tail End Charlie is out of date',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            Text(
              state.message ??
                  'The ride service no longer supports this version, so '
                      'joining rides and syncing with your group is off until '
                      'you update.',
            ),
            const SizedBox(height: 8),
            Text(
              _versionLine,
              key: const Key('update-required-version'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 18),
            if (destination != null)
              FilledButton.icon(
                key: const Key('update-required-open'),
                onPressed: () => unawaited(_open(context, destination)),
                icon: const Icon(Icons.open_in_new),
                label: Text(identity.updateActionLabel),
              ),
            const SizedBox(height: 10),
            Text(
              identity.updateInstruction,
              key: const Key('update-required-instruction'),
              style: const TextStyle(color: Color(0xFF98A3B1)),
            ),
            const SizedBox(height: 22),
            const _StillWorksCard(),
            const SizedBox(height: 22),
            OutlinedButton(
              key: const Key('update-required-continue'),
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Continue without updating'),
            ),
            Align(
              alignment: Alignment.center,
              child: TextButton(
                key: const Key('update-required-build-details'),
                onPressed: () => unawaited(
                  AboutBuildSheet.show(context, identity: identity),
                ),
                child: const Text('Build details'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, Uri uri) async {
    final opened = await openUri(uri);
    if (opened || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Could not open ${uri.host}.')));
  }
}

Future<bool> _launchExternally(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// The honest scope of the gate, in the rider's words.
class _StillWorksCard extends StatelessWidget {
  const _StillWorksCard();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('update-required-scope'),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xFF2E3A48)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Not switched off', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        const Text(
          'SOS and the alert buttons, navigation, recording your route, and a '
          'ride you are already in all stay on this phone and keep working. '
          'What you record or send is kept on this phone.',
        ),
        const SizedBox(height: 12),
        Text(
          'Paused until you update',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        const Text(
          'Joining a ride by code, and syncing with your group through the ride '
          'service. SOS and alerts will not reach riders through the ride '
          'service while it is paused.',
        ),
      ],
    ),
  );
}

/// The home-map notice that carries the verdict until the rider has updated.
class UpdateRequiredBanner extends StatelessWidget {
  const UpdateRequiredBanner({
    super.key,
    required this.gate,
    required this.identity,
    this.openUri = _launchExternally,
  });

  final AppUpdateGateController gate;
  final BuildIdentity identity;
  final Future<bool> Function(Uri uri) openUri;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: gate,
    builder: (context, _) {
      final state = gate.state;
      if (!state.updateRequired) return const SizedBox.shrink();
      final destination = identity.updateDestination(state.relayUpdateUri);
      return Card(
        key: const Key('update-required-banner'),
        color: const Color(0xFF2A1F1F),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.system_update_alt, color: _warning),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Update required',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'The ride service no longer supports this version, so joining '
                'and syncing rides is paused. SOS and everything else on this '
                'phone keeps working.',
                style: TextStyle(color: Color(0xFFE0D2D2)),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('update-required-banner-details'),
                    onPressed: () => unawaited(
                      UpdateRequiredScreen.show(
                        context,
                        identity: identity,
                        state: state,
                      ),
                    ),
                    child: const Text('Details'),
                  ),
                  if (destination != null)
                    FilledButton(
                      key: const Key('update-required-banner-open'),
                      onPressed: () => unawaited(openUri(destination)),
                      child: Text(identity.updateActionLabel),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
