import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/build_identity.dart';

/// The build a tester is actually running, in one readable place.
///
/// Two taps from anywhere the settings button is shown: Settings, then
/// **About & build**. Everything on it is safe to read out or screenshot into
/// a bug report - the relay endpoint appears as a bare host, never as a URL
/// that could carry a path, credentials, or a token.
class AboutBuildSheet extends StatelessWidget {
  const AboutBuildSheet({
    super.key,
    required this.identity,
    this.lastRelaySync,
    this.now,
  });

  final BuildIdentity identity;

  /// Most recent successful relay sync in this app session, when the caller
  /// knows it. Null before a ride has synchronised.
  final DateTime? lastRelaySync;

  /// Injected in tests so staleness copy is deterministic.
  final DateTime? now;

  static Future<void> show(
    BuildContext context, {
    BuildIdentity? identity,
    DateTime? lastRelaySync,
  }) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => AboutBuildSheet(
      identity: identity ?? BuildIdentity.fromEnvironment(),
      lastRelaySync: lastRelaySync,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final resolvedNow = now ?? DateTime.now();
    final state = identity.updateStateAt(resolvedNow);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'About & build',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
          const Text(
            'Quote these details in every bug report so the fix lands against '
            'the right code.',
            style: TextStyle(color: Color(0xFF98A3B1)),
          ),
          const SizedBox(height: 18),
          _BuildDetail(
            key: const Key('about-app-version'),
            icon: Icons.tag,
            label: 'App version',
            value: identity.appVersion,
          ),
          _BuildDetail(
            key: const Key('about-app-build'),
            icon: Icons.confirmation_number_outlined,
            label: 'Build number',
            value: identity.appBuild,
          ),
          _BuildDetail(
            key: const Key('about-distribution-track'),
            icon: Icons.alt_route_outlined,
            label: 'Distribution track',
            value: identity.track.label,
          ),
          _BuildDetail(
            key: const Key('about-built-at'),
            icon: Icons.event_outlined,
            label: 'Built',
            value: _builtLabel(resolvedNow),
          ),
          _BuildDetail(
            key: const Key('about-relay-host'),
            icon: Icons.dns_outlined,
            label: 'Relay endpoint',
            value: identity.hasRelayEndpoint
                ? identity.relayHost
                : 'Not configured',
          ),
          _BuildDetail(
            key: const Key('about-last-relay-sync'),
            icon: Icons.cloud_done_outlined,
            label: 'Last relay sync',
            value: _lastSyncLabel(resolvedNow),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('copy-build-identity'),
            onPressed: () => unawaited(_copyIdentity(context)),
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Copy build details for a bug report'),
          ),
          const SizedBox(height: 22),
          Text(
            'TESTER UPDATES',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF8D98A7),
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          TesterUpdateNotice(
            identity: identity,
            state: state,
            ageInDays: identity.ageInDaysAt(resolvedNow),
          ),
          if (identity.updateUri case final updateUri?) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const Key('open-tester-update-channel'),
              onPressed: () => unawaited(_openUri(context, updateUri)),
              icon: const Icon(Icons.system_update_alt),
              label: Text(switch (identity.platform) {
                TargetPlatform.iOS => 'Open TestFlight',
                _ => 'Open Google Play listing',
              }),
            ),
          ],
          if (identity.testerNotesUri case final notesUri?) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('open-tester-release-notes'),
                onPressed: () => unawaited(_openUri(context, notesUri)),
                child: const Text("What changed in this build"),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _builtLabel(DateTime now) {
    final built = identity.builtAt;
    if (built == null) return 'Not stamped (local build)';
    final age = identity.ageInDaysAt(now) ?? 0;
    return '${_formatDate(built)} · ${_daysLabel(age)} old';
  }

  String _lastSyncLabel(DateTime now) {
    final sync = lastRelaySync;
    if (sync == null) return 'No successful sync yet';
    return '${_formatDateTime(sync)} · ${_agoLabel(now.difference(sync))}';
  }

  Future<void> _copyIdentity(BuildContext context) async {
    final resolvedNow = now ?? DateTime.now();
    final details = [
      identity.bugReportLine,
      'Built: ${_builtLabel(resolvedNow)}',
      'Relay: ${identity.hasRelayEndpoint ? identity.relayHost : 'not configured'}',
      'Last relay sync: ${_lastSyncLabel(resolvedNow)}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: details));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Build details copied to the clipboard.')),
    );
  }
}

/// Non-blocking "you may not be on the newest tester build" notice.
///
/// This never blocks the app. The hard, blocking gate for genuinely
/// incompatible builds stays with the relay's `updateRequired` phase.
class TesterUpdateNotice extends StatelessWidget {
  const TesterUpdateNotice({
    super.key,
    required this.identity,
    required this.state,
    this.ageInDays,
  });

  final BuildIdentity identity;
  final TesterUpdateState state;
  final int? ageInDays;

  @override
  Widget build(BuildContext context) {
    final (icon, color, headline) = switch (state) {
      TesterUpdateState.newerBuildLikely => (
        Icons.system_update_alt,
        const Color(0xFFFFC857),
        'A newer tester build is probably available',
      ),
      TesterUpdateState.current => (
        Icons.verified_outlined,
        const Color(0xFF6ED89A),
        'This is a current tester build',
      ),
      TesterUpdateState.unknown => (
        Icons.help_outline,
        const Color(0xFF8D98A7),
        'Build age unknown',
      ),
    };
    return Container(
      key: const Key('tester-update-notice'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(headline, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  _detail(),
                  style: const TextStyle(color: Color(0xFF98A3B1)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _detail() => switch (state) {
    TesterUpdateState.newerBuildLikely =>
      'This build is ${_daysLabel(ageInDays ?? 0)} old and tester builds are '
          'published more often than that. ${identity.updateInstruction}',
    TesterUpdateState.current =>
      'Built ${_daysLabel(ageInDays ?? 0)} ago. Tester channels never force an '
          'update, so check anyway before reporting a bug. '
          '${identity.updateInstruction}',
    TesterUpdateState.unknown =>
      'No build date was stamped into this artefact, so the app cannot judge '
          'whether it is current. ${identity.updateInstruction}',
  };
}

/// Home-screen affordance that makes a stale tester build impossible to miss
/// and turns updating into one obvious tap.
///
/// Renders nothing unless the build looks stale, so it never nags a tester who
/// is already current and never appears on a local development build (which
/// carries no build timestamp).
class TesterUpdateBanner extends StatelessWidget {
  const TesterUpdateBanner({super.key, required this.identity, this.now});

  final BuildIdentity identity;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final resolvedNow = now ?? DateTime.now();
    if (identity.updateStateAt(resolvedNow) !=
        TesterUpdateState.newerBuildLikely) {
      return const SizedBox.shrink();
    }
    final updateUri = identity.updateUri;
    return Card(
      key: const Key('tester-update-banner'),
      color: const Color(0xFF2A2418),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.system_update_alt,
                  color: Color(0xFFFFC857),
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'A newer tester build is probably available',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'You are on ${identity.versionLabel}, built '
              '${_daysLabel(identity.ageInDaysAt(resolvedNow) ?? 0)} ago. '
              '${identity.updateInstruction}',
              style: const TextStyle(color: Color(0xFFD8CFBB)),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const Key('tester-update-banner-details'),
                  onPressed: () => unawaited(
                    AboutBuildSheet.show(context, identity: identity),
                  ),
                  child: const Text('Build details'),
                ),
                if (updateUri != null)
                  FilledButton(
                    key: const Key('tester-update-banner-open-channel'),
                    onPressed: () => unawaited(_openUri(context, updateUri)),
                    child: Text(switch (identity.platform) {
                      TargetPlatform.iOS => 'Open TestFlight',
                      _ => 'Open Google Play',
                    }),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BuildDetail extends StatelessWidget {
  const _BuildDetail({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF8D98A7)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label, style: const TextStyle(color: Color(0xFF98A3B1))),
        ),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

Future<void> _openUri(BuildContext context, Uri uri) async {
  final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (opened || !context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('Could not open ${uri.host}.')));
}

String _daysLabel(int days) => switch (days) {
  0 => 'less than a day',
  1 => '1 day',
  _ => '$days days',
};

String _agoLabel(Duration elapsed) {
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes} min ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours} h ago';
  return '${_daysLabel(elapsed.inDays)} ago';
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/${local.year}';
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  return '${_formatDate(local)} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}
