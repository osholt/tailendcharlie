import 'package:flutter/foundation.dart';

/// Where an installed build came from.
///
/// The value is stamped at build time by the workflow that produced the
/// artefact, so it describes the channel the binary was *built for* rather
/// than any track it was later promoted to.
enum DistributionTrack {
  /// A local `flutter run`/`flutter build` with no track stamped in.
  local('Local build'),

  /// A Mobile CI debug artefact.
  continuousIntegration('CI debug build'),

  /// Google Play internal testing.
  playInternal('Play internal testing'),

  /// Apple TestFlight.
  testFlight('TestFlight');

  const DistributionTrack(this.label);

  final String label;

  static DistributionTrack parse(String value) =>
      switch (value.trim().toLowerCase()) {
        'internal' || 'play-internal' || 'play_internal' => playInternal,
        'testflight' || 'test-flight' => testFlight,
        'ci' || 'continuous-integration' => continuousIntegration,
        _ => local,
      };
}

/// How stale the running tester build looks.
enum TesterUpdateState {
  /// No build date was stamped in, so staleness cannot be judged.
  unknown,

  /// The build is younger than the configured tester-build lifetime.
  current,

  /// The build is older than the configured tester-build lifetime, so a newer
  /// tester build has very likely been published since.
  newerBuildLikely,
}

/// The build's own identity, as reported to the relay and shown to testers.
///
/// Everything here comes from `--dart-define` values stamped in by the
/// workflow that built the artefact. The version and build defaults
/// deliberately match `RelayClientDescriptor.current()` so the identity a
/// tester reads in the app is the identity the relay receives;
/// `build_identity_test.dart` fails if the two ever drift apart.
@immutable
class BuildIdentity {
  const BuildIdentity({
    required this.appVersion,
    required this.appBuild,
    required this.track,
    required this.platform,
    this.builtAt,
    this.relayHost = '',
    this.updateUri,
    this.testerNotesUri,
    this.testerBuildLifetime = const Duration(days: 14),
  });

  factory BuildIdentity.fromEnvironment({TargetPlatform? platform}) {
    final resolvedPlatform = platform ?? defaultTargetPlatform;
    const overriddenUpdateUrl = String.fromEnvironment(
      'RIDE_RELAY_TESTER_UPDATE_URL',
    );
    return BuildIdentity(
      appVersion: const String.fromEnvironment(
        'RIDE_RELAY_APP_VERSION',
        defaultValue: '1.0.1',
      ),
      appBuild: const String.fromEnvironment(
        'RIDE_RELAY_APP_BUILD',
        defaultValue: '22',
      ),
      track: DistributionTrack.parse(
        const String.fromEnvironment('RIDE_RELAY_DISTRIBUTION_TRACK'),
      ),
      platform: resolvedPlatform,
      builtAt: _parseTimestamp(
        const String.fromEnvironment('RIDE_RELAY_BUILD_TIMESTAMP'),
      ),
      relayHost: _hostOf(
        const String.fromEnvironment('RIDE_RELAY_API_BASE_URL'),
      ),
      updateUri: overriddenUpdateUrl.trim().isEmpty
          ? defaultUpdateUriFor(resolvedPlatform)
          : _secureUri(overriddenUpdateUrl),
      testerNotesUri: _secureUri(
        const String.fromEnvironment(
          'RIDE_RELAY_TESTER_NOTES_URL',
          defaultValue: defaultTesterNotesUrl,
        ),
      ),
      testerBuildLifetime: Duration(
        days: const int.fromEnvironment(
          'RIDE_RELAY_TESTER_BUILD_LIFETIME_DAYS',
          defaultValue: 14,
        ).clamp(1, 365),
      ),
    );
  }

  /// Google Play's listing for the Android package. Testers who have accepted
  /// the internal-testing invitation see the internal release here; testers who
  /// have not see the public listing and must accept the invitation first.
  static const playListingUrl =
      'https://play.google.com/store/apps/details?id=app.tailendcharlie';

  /// TestFlight's own landing page. A build-specific TestFlight invitation link
  /// can only be issued from App Store Connect, so it is supplied per build
  /// through `RIDE_RELAY_TESTER_UPDATE_URL` when one exists.
  static const testFlightUrl = 'https://testflight.apple.com/';

  static const defaultTesterNotesUrl =
      'https://github.com/osholt/tailendcharlie/blob/main/docs/tester-release-notes.md';

  final String appVersion;
  final String appBuild;
  final DistributionTrack track;
  final TargetPlatform platform;

  /// When the artefact was built, stamped in by the release workflow.
  final DateTime? builtAt;

  /// Host of the configured relay endpoint, never a full URL: the base URL can
  /// carry a path, and a misconfigured one could carry credentials or a token,
  /// none of which belong on a screen a tester reads out or screenshots.
  final String relayHost;

  final Uri? updateUri;
  final Uri? testerNotesUri;

  /// How long a tester build is assumed to stay current before the app starts
  /// telling the tester to check for a newer one.
  final Duration testerBuildLifetime;

  static Uri? defaultUpdateUriFor(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.android => Uri.parse(playListingUrl),
        TargetPlatform.iOS => Uri.parse(testFlightUrl),
        _ => null,
      };

  /// `1.0.1 (build 42)` - the identity to quote in a bug report.
  String get versionLabel => '$appVersion (build $appBuild)';

  /// A single line a tester can copy into a bug report.
  String get bugReportLine =>
      'Tail End Charlie $appVersion+$appBuild · ${track.label} · '
      '${platform.name}';

  bool get hasRelayEndpoint => relayHost.isNotEmpty;

  /// Play internal testing and TestFlight never force an update, so a tester
  /// can sit on an old build indefinitely. Age is the only signal available
  /// without a store API, so the app reports staleness rather than claiming to
  /// know the newest published build number.
  TesterUpdateState updateStateAt(DateTime now) {
    final built = builtAt;
    if (built == null) return TesterUpdateState.unknown;
    final age = now.toUtc().difference(built.toUtc());
    if (age < testerBuildLifetime) return TesterUpdateState.current;
    return TesterUpdateState.newerBuildLikely;
  }

  /// Whole days since the artefact was built, or null when unstamped.
  int? ageInDaysAt(DateTime now) {
    final built = builtAt;
    if (built == null) return null;
    final days = now.toUtc().difference(built.toUtc()).inDays;
    return days < 0 ? 0 : days;
  }

  /// How a tester gets the newer build on this platform.
  String get updateInstruction => switch (platform) {
    TargetPlatform.android =>
      'Open Google Play, then Manage apps & device → Updates available. '
          'Play can take a few minutes to show a new internal-testing build.',
    TargetPlatform.iOS =>
      'Open TestFlight and pull to refresh, then choose Update for Tail End '
          'Charlie.',
    _ => 'Reinstall the build from the channel it was distributed on.',
  };

  static DateTime? _parseTimestamp(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return DateTime.tryParse(trimmed)?.toUtc();
  }

  static String _hostOf(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return '';
    return uri.host;
  }

  static Uri? _secureUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'https') return null;
    if (uri.userInfo.isNotEmpty) return null;
    return uri;
  }
}
