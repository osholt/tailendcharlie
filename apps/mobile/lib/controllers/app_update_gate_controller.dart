import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../internet/internet_relay_client.dart';

/// What the ride service has said about whether this build may still use it.
enum UpdateGatePhase {
  /// Not asked yet, or the relay could not be asked (offline, no endpoint, an
  /// outage). Never treated as a verdict.
  unknown,

  /// The relay accepts this build.
  current,

  /// The relay will not take this build any more (#37).
  updateRequired,
}

@immutable
class UpdateGateState {
  const UpdateGateState._(
    this.phase, {
    this.message,
    this.minimumBuild,
    this.clientBuild,
    this.relayUpdateUri,
  });

  const UpdateGateState.unknown() : this._(UpdateGatePhase.unknown);

  const UpdateGateState.current() : this._(UpdateGatePhase.current);

  const UpdateGateState.updateRequired({
    String? message,
    int? minimumBuild,
    int? clientBuild,
    Uri? relayUpdateUri,
  }) : this._(
         UpdateGatePhase.updateRequired,
         message: message,
         minimumBuild: minimumBuild,
         clientBuild: clientBuild,
         relayUpdateUri: relayUpdateUri,
       );

  final UpdateGatePhase phase;

  /// The relay's own sentence, shown beside the build numbers.
  final String? message;

  /// The relay's minimum build for this platform, when the refusal is about the
  /// build and not about a protocol or capability.
  final int? minimumBuild;
  final int? clientBuild;

  /// The update page the relay advertises, used only when this build has no
  /// track-aware destination of its own.
  final Uri? relayUpdateUri;

  bool get updateRequired => phase == UpdateGatePhase.updateRequired;
}

/// Asks the ride service once per launch whether this build is still supported,
/// so an old beta build is told to update with a link instead of failing later
/// at the first join or sync (#37).
///
/// What this decides, and what it must never decide:
///
/// * It only *informs*. The one thing an `updateRequired` verdict changes is
///   what the home map says and offers. It does not switch off anything on the
///   phone, and nothing here is consulted by the SOS control, the alert
///   controls, navigation, route or ride recording, the ride journal or the
///   Nearby transport. The relay refusing a sync is a limit on one transport,
///   and the app already keeps events durable and queued when it happens.
/// * It fails open. An unreachable relay, a timeout, a legacy relay with no
///   compatibility document, or an app that is *newer* than the relay all leave
///   the state as it was. Only a definite "update required" verdict from the
///   relay moves it, and a later failure to ask never takes it back.
class AppUpdateGateController extends ChangeNotifier {
  AppUpdateGateController({
    required Future<RelayCompatibilityResult> Function()? checkCompatibility,
    void Function()? closeProbe,
  }) : _probe = checkCompatibility,
       _onClose = closeProbe;

  /// Probes the configured relay, or nothing in a build with no relay endpoint.
  factory AppUpdateGateController.fromEnvironment() {
    final configuration = InternetRelayConfiguration.fromEnvironment();
    if (!configuration.isConfigured) {
      return AppUpdateGateController(checkCompatibility: null);
    }
    final client = HttpInternetRelayClient(
      configuration: configuration,
      client: http.Client(),
    );
    return AppUpdateGateController(
      checkCompatibility: client.checkCompatibility,
      closeProbe: client.close,
    );
  }

  final Future<RelayCompatibilityResult> Function()? _probe;
  final void Function()? _onClose;
  UpdateGateState _state = const UpdateGateState.unknown();
  Future<void>? _inFlight;
  bool _presented = false;
  bool _disposed = false;

  UpdateGateState get state => _state;
  bool get updateRequired => _state.updateRequired;

  /// Whether the full-screen explanation has already been offered this launch.
  /// It is offered once; the banner stays for as long as the verdict does.
  bool get presented => _presented;

  void markPresented() => _presented = true;

  /// Asks the relay. Safe to call repeatedly; a call during another shares it.
  Future<void> check() => _inFlight ??= _check().whenComplete(() {
    _inFlight = null;
  });

  Future<void> _check() async {
    final probe = _probe;
    if (probe == null) return;
    try {
      apply(await probe());
    } on Object {
      // No answer is not an answer. The relay's own refusal at the first join or
      // sync remains the gate that actually stops an incompatible client.
    }
  }

  /// Folds in a verdict, from this controller's own probe or from any other
  /// place that has just asked the relay.
  void apply(RelayCompatibilityResult result) {
    final next = switch (result.disposition) {
      RelayCompatibilityDisposition.updateRequired =>
        UpdateGateState.updateRequired(
          message: result.message,
          minimumBuild: result.minimumClientBuild,
          clientBuild: result.clientBuild,
          relayUpdateUri: result.updateUri,
        ),
      RelayCompatibilityDisposition.compatible ||
      RelayCompatibilityDisposition.legacyCompatible =>
        const UpdateGateState.current(),
      // The relay is the older side, or briefly unavailable: nothing about this
      // build has been decided either way.
      RelayCompatibilityDisposition.serverUpgradeRequired ||
      RelayCompatibilityDisposition.temporarilyUnavailable => _state,
    };
    if (_disposed || identical(next, _state)) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _onClose?.call();
    super.dispose();
  }
}
