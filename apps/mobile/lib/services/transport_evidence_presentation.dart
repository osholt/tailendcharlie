import '../relay/relay_engine.dart';
import 'ride_membership.dart' show formatRideClockTime;
import 'transport_evidence_ledger.dart';

/// Wording for the transport evidence (#855).
///
/// Pure functions of the ledger and the relay status, so the roster, the ride
/// dashboard, the ended-ride verdict and the diagnostics log all say the same
/// thing, and each sentence is checked by a unit test rather than by riding.
///
/// "Bluetooth" is the rider-facing name for the direct phone-to-phone link. The
/// SDK underneath may also use local Wi-Fi, which `docs/field-test-plan.md` rules
/// out by turning Wi-Fi off for the definitive check; this wording is evidence
/// that the direct link carried something, not a claim about which radio.

/// "just now", "12 s ago", "3 min ago", "2 h ago".
String formatEvidenceAge(Duration age) {
  final seconds = age.isNegative ? 0 : age.inSeconds;
  if (seconds < 2) return 'just now';
  if (seconds < 60) return '$seconds s ago';
  final minutes = age.inMinutes;
  if (minutes < 60) return '$minutes min ago';
  return '${age.inHours} h ago';
}

/// The compact per-rider line: `Bluetooth 12 s ago · Internet 8 s ago`, with
/// `Bluetooth: nothing yet` for a route that has delivered nothing from them.
///
/// Says when each route last delivered, never how good it is: a rider whose
/// Bluetooth line is fresh and whose internet line is old is being carried by
/// the direct link, and that is the contrast this exists to show.
String riderEvidenceLine(RiderTransportEvidence? evidence, DateTime now) {
  String part(EvidenceTransport transport) {
    final last = evidence?.countersFor(transport).lastReceivedAt;
    if (last == null) return '${transport.label}: nothing yet';
    return '${transport.label} ${formatEvidenceAge(now.difference(last))}';
  }

  return '${part(EvidenceTransport.bluetooth)} · '
      '${part(EvidenceTransport.internet)}';
}

/// The ride-level line about the direct link, from the relay's own status:
/// `Bluetooth: connected to 2 phones`, `Bluetooth: searching`,
/// `Bluetooth: unavailable: nearby-device permission is needed`.
String bluetoothLinkLine(RelayStatus? status) {
  if (status == null) return 'Bluetooth: not running on this phone';
  return switch (status.state) {
    RelayConnectionState.connected =>
      'Bluetooth: connected to ${_phones(status.peerIds.length)}',
    RelayConnectionState.searching => 'Bluetooth: searching for nearby phones',
    RelayConnectionState.starting => 'Bluetooth: starting',
    RelayConnectionState.backingOff =>
      'Bluetooth: reconnecting (${bluetoothReason(status.message)})',
    RelayConnectionState.unavailable =>
      'Bluetooth: unavailable: ${bluetoothReason(status.message)}',
    RelayConnectionState.failed =>
      'Bluetooth: unavailable: ${bluetoothReason(status.message)}',
    RelayConnectionState.stopped => 'Bluetooth: stopped',
  };
}

/// Why the direct link is not working, in a few words. A missing permission is
/// by far the commonest cause and is named as such; anything else is shown as the
/// platform reported it, cut short.
String bluetoothReason(String? message) {
  final text = message?.trim();
  if (text == null || text.isEmpty) return 'no reason reported';
  if (text.toLowerCase().contains('permission')) {
    return 'nearby-device permission is needed';
  }
  return text.length <= 80 ? text : '${text.substring(0, 79)}…';
}

String _phones(int count) => count == 1 ? '1 phone' : '$count phones';

/// What the ended-ride screen and the diagnostics log say about the direct link.
class BluetoothVerdictWording {
  const BluetoothVerdictWording({
    required this.headline,
    this.details = const [],
  });

  /// The sentence a rider reads first.
  final String headline;

  /// Anything that qualifies it: live positions, a reason, or the part of the
  /// ride that was not watched.
  final List<String> details;

  /// Headline and details as one paragraph, for the diagnostics log.
  String get plain => [headline, ...details].join(' ');
}

/// The plain-language answer to "did phone-to-phone sharing work on this ride?".
///
/// **Worked** means at least one authenticated update from another rider arrived
/// over the direct link. Everything that reaches the relay engine has already
/// passed its HMAC check, so "arrived" here is "arrived and was accepted as a
/// member's".
///
/// **Not worked** is stated as what was observed, and with the reason when one is
/// known: the permission was refused, the link could not start, or it never
/// found another phone. When this phone only began watching part-way through
/// (the ride screen was rebuilt), the absence is qualified: "nothing arrived" is
/// not a safe claim about a stretch nobody was watching.
///
/// This is diagnostic evidence, not a product claim. `docs/nearby-relay.md`
/// still forbids describing Nearby as a working mesh.
BluetoothVerdictWording bluetoothVerdictWording(
  BluetoothVerdict verdict, {
  RelayStatus? status,
  DateTime? rideStartedAt,
}) {
  if (verdict.worked) {
    final headline = verdict.viaBluetooth > 0
        ? 'Bluetooth peer-to-peer worked: '
              '${verdict.viaBluetooth} of ${verdict.updatesFromOthers} updates '
              'arrived over Bluetooth; ${verdict.bluetoothFirst} arrived over '
              'Bluetooth before the internet; ${verdict.bluetoothOnly} arrived '
              'only over Bluetooth.'
        : 'Bluetooth peer-to-peer worked: live positions from other riders '
              'arrived over Bluetooth, though no other ride update did.';
    return BluetoothVerdictWording(
      headline: headline,
      details: [
        if (verdict.bluetoothPresenceUpdates > 0 ||
            verdict.internetPresenceUpdates > 0)
          'Live positions: ${verdict.bluetoothPresenceUpdates} arrived over '
              'Bluetooth, ${verdict.internetPresenceUpdates} over the internet.',
      ],
    );
  }
  final started = rideStartedAt;
  final partial =
      started != null &&
      verdict.observingSince.isAfter(started.add(_unwatchedTolerance));
  return BluetoothVerdictWording(
    headline: 'Nothing arrived over Bluetooth on this ride.',
    details: [
      ?_absenceReason(verdict, status),
      if (partial)
        'This phone only began recording Bluetooth evidence at '
            '${formatRideClockTime(verdict.observingSince)}, so the ride before '
            'that is not covered.',
    ],
  );
}

/// A ride screen is built a moment after the ride begins, so a ledger that
/// started a little after the start is not a ledger that missed part of it.
const _unwatchedTolerance = Duration(minutes: 1);

String? _absenceReason(BluetoothVerdict verdict, RelayStatus? status) {
  if (status != null) {
    final reason = switch (status.state) {
      // A refused permission leaves the link retrying to start, so a link that
      // is backing off is as unavailable as one that has said so.
      RelayConnectionState.unavailable ||
      RelayConnectionState.failed ||
      RelayConnectionState.backingOff =>
        (status.message?.toLowerCase().contains('permission') ?? false)
            ? 'Nearby-device permission was not granted, so Bluetooth could '
                  'not start.'
            : 'Bluetooth was unavailable on this phone '
                  '(${bluetoothReason(status.message)}).',
      _ => null,
    };
    if (reason != null) return reason;
  }
  if (!verdict.everConnectedToPhone) {
    return 'This phone never connected to another phone over Bluetooth.';
  }
  return 'This phone did connect to another phone, but no ride update arrived '
      'over that link.';
}

/// How far ahead of the internet Bluetooth typically was, for the diagnostics
/// log. Null unless there are updates both routes delivered with Bluetooth first.
String? bluetoothLeadSentence(BluetoothVerdict verdict) {
  final median = verdict.medianLeadOverInternet;
  final longest = verdict.longestLeadOverInternet;
  if (median == null || longest == null) return null;
  return 'Where Bluetooth was ahead of the internet it led by a median of '
      '${_seconds(median)} (longest ${_seconds(longest)}) over '
      '${verdict.bluetoothFirst} updates.';
}

String _seconds(Duration duration) =>
    '${(duration.inMilliseconds / 1000).toStringAsFixed(1)} s';

/// The verdict as the diagnostics log records it at the end of the ride: the same
/// words the ended-ride screen shows, then how far ahead of the internet
/// Bluetooth was when it was ahead.
String transportVerdictLogText(
  BluetoothVerdict verdict, {
  RelayStatus? status,
  DateTime? rideStartedAt,
}) {
  final wording = bluetoothVerdictWording(
    verdict,
    status: status,
    rideStartedAt: rideStartedAt,
  );
  return [wording.plain, ?bluetoothLeadSentence(verdict)].join(' ');
}

/// One line for the ride dashboard's Bluetooth card: what has been received, as
/// opposed to whether the link is up.
String bluetoothReceivedLine(TransportTotals bluetooth) {
  final updates = bluetooth.events + bluetooth.presenceUpdates;
  if (updates == 0) return 'Nothing received over Bluetooth yet';
  final riders = bluetooth.ridersHeard == 1
      ? '1 rider'
      : '${bluetooth.ridersHeard} riders';
  return 'Received over Bluetooth: $updates updates from $riders';
}
