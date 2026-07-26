import 'package:flutter/foundation.dart';

import '../internet/internet_relay_client.dart';

/// Where an installed build came from.
///
/// The value is stamped at build time by the workflow that produced the
/// artefact, and names the track the build is *destined for* - the track a
/// tester can install it from once the workflow finishes. A build uploaded to
/// `internal` and promoted to `alpha` in the same run is stamped `alpha`,
/// because `alpha` is where its testers get it; promotion never rebuilds, so
/// stamping the upload track instead would tell every closed tester they are
/// on a track they cannot see.
enum DistributionTrack {
  /// A local `flutter run`/`flutter build` with no track stamped in.
  local('Local build'),

  /// A Mobile CI debug artefact.
  continuousIntegration('CI debug build'),

  /// Google Play internal testing.
  playInternal('Play internal testing'),

  /// Google Play closed testing, `alpha` track - where the tester group is.
  playClosedAlpha('Play closed testing (alpha)'),

  /// Google Play closed testing, `beta` track.
  playClosedBeta('Play closed testing (beta)'),

  /// Apple TestFlight.
  testFlight('TestFlight');

  const DistributionTrack(this.label);

  final String label;

  /// True for the Play tracks a tester reaches through the closed-testing
  /// opt-in page rather than the public store listing.
  bool get isPlayClosedTesting =>
      this == playClosedAlpha || this == playClosedBeta;

  static DistributionTrack parse(String value) => switch (value
      .trim()
      .toLowerCase()) {
    'internal' || 'play-internal' || 'play_internal' => playInternal,
    'alpha' ||
    'closed-alpha' ||
    'closed_alpha' ||
    'play-alpha' => playClosedAlpha,
    'beta' || 'closed-beta' || 'closed_beta' || 'play-beta' => playClosedBeta,
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
    // Read the version through the relay descriptor rather than re-reading the
    // dart-defines here. Two independent reads with two different fallbacks is
    // exactly how the About screen and the relay headers came to disagree, and
    // an unstamped build must report `unknown` on both rather than a
    // plausible-looking constant.
    final declared = RelayClientDescriptor.current();
    final track = DistributionTrack.parse(declared.distributionTrack);
    return BuildIdentity(
      appVersion: declared.appVersion,
      appBuild: declared.appBuild,
      track: track,
      platform: resolvedPlatform,
      builtAt: _parseTimestamp(
        const String.fromEnvironment('RIDE_RELAY_BUILD_TIMESTAMP'),
      ),
      relayHost: _hostOf(
        const String.fromEnvironment('RIDE_RELAY_API_BASE_URL'),
      ),
      updateUri: overriddenUpdateUrl.trim().isEmpty
          ? defaultUpdateUriFor(resolvedPlatform, track)
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

  /// The closed-testing opt-in page for the Android package.
  ///
  /// A closed (`alpha`/`beta`) tester who has not opted in on the device's
  /// Google account is not offered the app by [playListingUrl] at all, so the
  /// store listing is the wrong destination for a closed-track build. This page
  /// both enrols the account and links straight through to the install/update.
  static const playClosedTestingOptInUrl =
      'https://play.google.com/apps/testing/app.tailendcharlie';

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

  /// Where the update action should send a tester on this platform and track.
  ///
  /// Track-aware on Android: a closed-track build points at the opt-in page,
  /// everything else at the store listing.
  static Uri? defaultUpdateUriFor(
    TargetPlatform platform,
    DistributionTrack track,
  ) => switch (platform) {
    TargetPlatform.android => Uri.parse(
      track.isPlayClosedTesting ? playClosedTestingOptInUrl : playListingUrl,
    ),
    TargetPlatform.iOS => Uri.parse(testFlightUrl),
    _ => null,
  };

  /// `1.0.1 (build 42)` - the identity to quote in a bug report.
  /// False when this build channel did not stamp its version in, so the app
  /// says so instead of quoting a constant that does not identify the artefact.
  bool get reportsVersion =>
      appVersion != RelayClientDescriptor.unknownVersion &&
      appBuild != RelayClientDescriptor.unknownVersion;

  String get versionLabel => reportsVersion
      ? '$appVersion (build $appBuild)'
      : 'This build does not report its version';

  /// A single line a tester can copy into a bug report.
  String get bugReportLine =>
      'Tail End Charlie ${reportsVersion ? '$appVersion+$appBuild' : 'unstamped build (version not reported)'} · '
      '${track.label} · ${platform.name}';

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

  /// How a tester gets the newer build on this platform and track.
  String get updateInstruction => switch (platform) {
    TargetPlatform.android when track.isPlayClosedTesting =>
      'Open the closed-testing opt-in page with the Google account you test '
          'with, then follow "Download it on Google Play" and choose Update. '
          'Play can take a few minutes to offer a new closed-testing build.',
    TargetPlatform.android =>
      'Open Google Play, then Manage apps & device → Updates available. '
          'Play can take a few minutes to show a new internal-testing build.',
    TargetPlatform.iOS =>
      'Open TestFlight and pull to refresh, then choose Update for Tail End '
          'Charlie.',
    _ => 'Reinstall the build from the channel it was distributed on.',
  };

  /// Label for the button that opens [updateUri]. Shared by the About sheet and
  /// the home-screen banner so a tester is never sent to the closed-testing
  /// opt-in page by a button that says "Google Play listing".
  String get updateActionLabel => switch (platform) {
    TargetPlatform.iOS => 'Open TestFlight',
    TargetPlatform.android when track.isPlayClosedTesting =>
      'Open closed testing page',
    _ => 'Open Google Play listing',
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
