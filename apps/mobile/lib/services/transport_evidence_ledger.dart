import 'package:meta/meta.dart';

/// The two ways a ride update reaches this phone (#855).
///
/// The question behind the type is the one the 4 October ride could not answer:
/// when a rider's position showed up, was that the phone signal or was it real
/// phone-to-phone sharing? The ride service is always listening, so a good signal
/// hides the direct link completely. Recording **which path delivered each
/// update, and which delivered it first**, is what pulls the two apart.
enum EvidenceTransport {
  /// The direct phone-to-phone link (Google Nearby Connections). Called
  /// "Bluetooth" on screen because that is what a rider recognises. The SDK
  /// chooses its own radio, which is why the field test in
  /// `docs/field-test-plan.md` isolates it rather than trusting this label.
  bluetooth,

  /// The ride service, reached over mobile data or Wi-Fi.
  internet;

  EvidenceTransport get other => switch (this) {
    EvidenceTransport.bluetooth => EvidenceTransport.internet,
    EvidenceTransport.internet => EvidenceTransport.bluetooth,
  };

  /// Wording for a person. Capitalised because it starts a sentence on screen.
  String get label => switch (this) {
    EvidenceTransport.bluetooth => 'Bluetooth',
    EvidenceTransport.internet => 'Internet',
  };
}

/// What one transport has delivered from one rider.
@immutable
class TransportCounters {
  const TransportCounters({
    this.events = 0,
    this.firstDelivered = 0,
    this.presenceUpdates = 0,
    this.lastEventAt,
    this.lastPresenceAt,
  });

  static const empty = TransportCounters();

  /// Distinct durable ride events (positions, hazards, role changes ...) this
  /// transport delivered. A redelivery over the same transport is not counted
  /// twice.
  final int events;

  /// Of [events], how many this transport delivered **before the other one did**
  /// (or the other never did).
  final int firstDelivered;

  /// Live-position (presence) updates that were newer than the previous one on
  /// this transport. Presence is replace-only, so the internet poll handing back
  /// the same position every four seconds is not a new update.
  final int presenceUpdates;

  final DateTime? lastEventAt;
  final DateTime? lastPresenceAt;

  /// The most recent time anything from this rider arrived this way.
  DateTime? get lastReceivedAt => _later(lastEventAt, lastPresenceAt);

  bool get isEmpty => events == 0 && presenceUpdates == 0;

  static DateTime? _later(DateTime? first, DateTime? second) {
    if (first == null) return second;
    if (second == null) return first;
    return first.isAfter(second) ? first : second;
  }
}

/// One remote rider's evidence on both transports.
///
/// Keyed by the rider's opaque id and carrying counts and times only. Never a
/// name, a position or a payload: the ledger exists to be shown on screen and
/// summarised into a log that leaves the phone, so what it holds is limited to
/// what may be shared.
@immutable
class RiderTransportEvidence {
  const RiderTransportEvidence({
    required this.riderId,
    required this.bluetooth,
    required this.internet,
  });

  final String riderId;
  final TransportCounters bluetooth;
  final TransportCounters internet;

  TransportCounters countersFor(EvidenceTransport transport) =>
      switch (transport) {
        EvidenceTransport.bluetooth => bluetooth,
        EvidenceTransport.internet => internet,
      };
}

/// A transport's totals across every remote rider.
@immutable
class TransportTotals {
  const TransportTotals({
    required this.events,
    required this.firstDelivered,
    required this.presenceUpdates,
    required this.ridersHeard,
    required this.oldestLastReceivedAge,
  });

  static const empty = TransportTotals(
    events: 0,
    firstDelivered: 0,
    presenceUpdates: 0,
    ridersHeard: 0,
    oldestLastReceivedAge: null,
  );

  final int events;
  final int firstDelivered;
  final int presenceUpdates;

  /// How many remote riders this transport has delivered anything from.
  final int ridersHeard;

  /// How long ago the **least recently heard** rider was last heard on this
  /// transport. The worst case across the group, because "somebody has gone
  /// quiet" is what a reader is looking for. Null when nobody has been heard.
  final Duration? oldestLastReceivedAge;
}

/// Both transports' totals at one moment.
@immutable
class TransportEvidenceSummary {
  const TransportEvidenceSummary({
    required this.at,
    required this.bluetooth,
    required this.internet,
  });

  final DateTime at;
  final TransportTotals bluetooth;
  final TransportTotals internet;

  TransportTotals totalsFor(EvidenceTransport transport) => switch (transport) {
    EvidenceTransport.bluetooth => bluetooth,
    EvidenceTransport.internet => internet,
  };
}

/// What the ride showed about the direct phone-to-phone link.
@immutable
class BluetoothVerdict {
  const BluetoothVerdict({
    required this.updatesFromOthers,
    required this.viaBluetooth,
    required this.bluetoothFirst,
    required this.bluetoothOnly,
    required this.bluetoothPresenceUpdates,
    required this.internetPresenceUpdates,
    required this.observingSince,
    required this.everConnectedToPhone,
    required this.medianLeadOverInternet,
    required this.longestLeadOverInternet,
  });

  /// Distinct durable updates authored by other riders that reached this phone
  /// by any route.
  final int updatesFromOthers;

  /// Of those, how many Bluetooth delivered (before, after or alone).
  final int viaBluetooth;

  /// Updates Bluetooth delivered **before the internet did**, where the internet
  /// did deliver them eventually.
  final int bluetoothFirst;

  /// Updates the internet never delivered at all while this phone was watching.
  /// Only counted once an update has been waiting longer than
  /// [TransportEvidenceLedger.bluetoothOnlySettleAfter], so an update the
  /// internet is simply about to deliver is not claimed for Bluetooth.
  final int bluetoothOnly;

  final int bluetoothPresenceUpdates;
  final int internetPresenceUpdates;

  /// When this ledger began to watch. Later than the ride's start when the ride
  /// screen was rebuilt mid-ride, in which case a count of zero describes only
  /// the part that was watched.
  final DateTime observingSince;

  /// Whether this phone ever saw another phone on the direct link.
  final bool everConnectedToPhone;

  /// How far ahead of the internet Bluetooth typically was, over the updates
  /// both delivered with Bluetooth first. Null when there were none.
  final Duration? medianLeadOverInternet;
  final Duration? longestLeadOverInternet;

  /// The test the on-screen verdict turns on: at least one authenticated update
  /// from another rider came in over the direct link. A live position counts, as
  /// it is the thing a rider actually sees move.
  bool get worked => viaBluetooth > 0 || bluetoothPresenceUpdates > 0;
}

/// Which path delivered each update from the other riders, and how the two
/// compare (#855).
///
/// ## What it records
///
/// - per remote rider and per transport: durable events received, live-position
///   (presence) updates received, and when something last arrived;
/// - per durable event id: which transport delivered it first, how far ahead it
///   was when both did, and the ones only Bluetooth ever delivered.
///
/// ## What it deliberately does not
///
/// Names, positions and payloads. A rider is an opaque id; an event is an id and
/// an arrival time. That is what lets the same object feed an on-screen roster
/// line and a diagnostics file that leaves the phone.
///
/// ## Why the hooks sit before de-duplication
///
/// An update that arrives over both routes is stored once, and every layer that
/// de-duplicates then discards the second arrival unseen. That is exactly the
/// arrival this exists to count: the first route to deliver looks like the only
/// one, so whichever path is quicker hides the other completely. Callers must
/// therefore report an arrival **before** the journal or queue has a chance to
/// drop it as a duplicate.
///
/// ## Bounds
///
/// Event ids are held in a bounded window ([maximumTrackedEvents]); totals are
/// cumulative and never shrink. An update whose second delivery arrives after its
/// id has left the window is counted as a new one, which can only overstate the
/// totals slightly on a very long ride.
///
/// Pure Dart, with an injectable clock, so every case is driven by a unit test.
class TransportEvidenceLedger {
  TransportEvidenceLedger({
    required this.localRiderId,
    DateTime Function()? clock,
    this.maximumTrackedEvents = defaultMaximumTrackedEvents,
    this.bluetoothOnlySettleAfter = const Duration(seconds: 30),
  }) : _clock = clock ?? DateTime.now,
       observingSince = (clock ?? DateTime.now)();

  static const defaultMaximumTrackedEvents = 8192;

  /// How many lead-time samples are kept for the median.
  static const _maximumLeadSamples = 512;

  /// This phone's own rider. Their updates are never counted: an echo of what
  /// this phone itself sent proves nothing about anybody else.
  final String localRiderId;

  final DateTime Function() _clock;
  final int maximumTrackedEvents;

  /// How long an update delivered only by Bluetooth must have been waiting
  /// before it is claimed as "only Bluetooth". The internet polls every few
  /// seconds, so an update that is a few seconds old and not there yet is just
  /// early.
  final Duration bluetoothOnlySettleAfter;

  /// When this ledger started to watch.
  final DateTime observingSince;

  final Map<String, _RiderCounters> _riders = {};

  /// Insertion-ordered, so the oldest id is the first key.
  final Map<String, _EventTrace> _events = {};
  final List<Duration> _bluetoothLeads = [];

  int _distinctEvents = 0;
  int _viaBluetooth = 0;
  int _bluetoothFirst = 0;
  int _bluetoothOnlyUnsettled = 0;
  int _maximumBluetoothPeers = 0;

  /// Whether this phone has ever seen another phone on the direct link.
  bool get bluetoothEverConnected => _maximumBluetoothPeers > 0;

  /// Reports how many phones the direct link currently has. Only the high-water
  /// mark is kept: what matters afterwards is whether the link ever connected.
  void observeBluetoothPeers(int peerCount) {
    if (peerCount > _maximumBluetoothPeers) _maximumBluetoothPeers = peerCount;
  }

  /// A durable ride event authored by [authorId] arrived over [transport].
  ///
  /// Call this **before** de-duplication. A second delivery of an event already
  /// held is the valuable case, so [eventId] being known already is normal and
  /// is not an error.
  void recordEvent({
    required EvidenceTransport transport,
    required String eventId,
    required String authorId,
    DateTime? at,
  }) {
    if (eventId.isEmpty || authorId.isEmpty || authorId == localRiderId) return;
    final now = at ?? _clock();
    final existing = _events[eventId];
    if (existing == null) {
      _events[eventId] = _EventTrace(
        authorId: authorId,
        first: transport,
        firstAt: now,
      );
      _distinctEvents += 1;
      _riders
          .putIfAbsent(authorId, _RiderCounters.new)
          .of(transport)
          .deliverEvent(now, first: true);
      if (transport == EvidenceTransport.bluetooth) {
        _viaBluetooth += 1;
        _bluetoothOnlyUnsettled += 1;
      }
      _evictBeyondWindow();
      return;
    }
    // Seen on this route already, or already seen on both: a redelivery, and
    // nothing new to learn.
    if (existing.first == transport || existing.secondAt != null) return;

    existing.secondAt = now;
    _riders
        .putIfAbsent(existing.authorId, _RiderCounters.new)
        .of(transport)
        .deliverEvent(now, first: false);
    final lead = now.difference(existing.firstAt);
    if (transport == EvidenceTransport.internet) {
      // Bluetooth had it first and the internet has now caught up.
      _bluetoothOnlyUnsettled -= 1;
      _bluetoothFirst += 1;
      _keepLead(_bluetoothLeads, lead);
    } else {
      _viaBluetooth += 1;
    }
  }

  /// A live position from [riderId] arrived over [transport] and was newer than
  /// the previous one on that route.
  void recordPresence({
    required EvidenceTransport transport,
    required String riderId,
    DateTime? at,
  }) {
    if (riderId.isEmpty || riderId == localRiderId) return;
    _riders
        .putIfAbsent(riderId, _RiderCounters.new)
        .of(transport)
        .deliverPresence(at ?? _clock());
  }

  /// What each remote rider has delivered on each transport. Empty until
  /// something has arrived.
  Map<String, RiderTransportEvidence> get riders => {
    for (final entry in _riders.entries)
      entry.key: entry.value.snapshot(entry.key),
  };

  RiderTransportEvidence? evidenceFor(String riderId) =>
      _riders[riderId]?.snapshot(riderId);

  /// Both transports' totals, with the oldest last-heard age across riders.
  TransportEvidenceSummary summary({DateTime? now}) {
    final at = now ?? _clock();
    return TransportEvidenceSummary(
      at: at,
      bluetooth: _totals(EvidenceTransport.bluetooth, at),
      internet: _totals(EvidenceTransport.internet, at),
    );
  }

  /// What the ride showed about the direct link, as of [now].
  BluetoothVerdict verdict({DateTime? now}) {
    final at = now ?? _clock();
    final totals = summary(now: at);
    var waiting = 0;
    for (final trace in _events.values) {
      if (trace.first == EvidenceTransport.bluetooth &&
          trace.secondAt == null &&
          at.difference(trace.firstAt) < bluetoothOnlySettleAfter) {
        waiting += 1;
      }
    }
    return BluetoothVerdict(
      updatesFromOthers: _distinctEvents,
      viaBluetooth: _viaBluetooth,
      bluetoothFirst: _bluetoothFirst,
      bluetoothOnly: _bluetoothOnlyUnsettled - waiting,
      bluetoothPresenceUpdates: totals.bluetooth.presenceUpdates,
      internetPresenceUpdates: totals.internet.presenceUpdates,
      observingSince: observingSince,
      everConnectedToPhone: bluetoothEverConnected,
      medianLeadOverInternet: _median(_bluetoothLeads),
      longestLeadOverInternet: _longest(_bluetoothLeads),
    );
  }

  TransportTotals _totals(EvidenceTransport transport, DateTime at) {
    var events = 0;
    var first = 0;
    var presence = 0;
    var heard = 0;
    Duration? oldest;
    for (final rider in _riders.values) {
      final counters = rider.of(transport);
      events += counters.events;
      first += counters.firstDelivered;
      presence += counters.presenceUpdates;
      final last = counters.snapshot().lastReceivedAt;
      if (last == null) continue;
      heard += 1;
      final age = at.difference(last);
      final bounded = age.isNegative ? Duration.zero : age;
      if (oldest == null || bounded > oldest) oldest = bounded;
    }
    return TransportTotals(
      events: events,
      firstDelivered: first,
      presenceUpdates: presence,
      ridersHeard: heard,
      oldestLastReceivedAge: oldest,
    );
  }

  void _evictBeyondWindow() {
    while (_events.length > maximumTrackedEvents) {
      _events.remove(_events.keys.first);
    }
  }

  static void _keepLead(List<Duration> leads, Duration lead) {
    if (leads.length >= _maximumLeadSamples) leads.removeAt(0);
    leads.add(lead.isNegative ? Duration.zero : lead);
  }

  static Duration? _median(List<Duration> leads) {
    if (leads.isEmpty) return null;
    final sorted = [...leads]..sort();
    return sorted[sorted.length ~/ 2];
  }

  static Duration? _longest(List<Duration> leads) {
    if (leads.isEmpty) return null;
    return leads.reduce((longest, lead) => lead > longest ? lead : longest);
  }
}

class _EventTrace {
  _EventTrace({
    required this.authorId,
    required this.first,
    required this.firstAt,
  });

  final String authorId;
  final EvidenceTransport first;
  final DateTime firstAt;

  /// When the other transport delivered the same event, if it ever has.
  DateTime? secondAt;
}

class _RiderCounters {
  final bluetooth = _TransportCounters();
  final internet = _TransportCounters();

  _TransportCounters of(EvidenceTransport transport) => switch (transport) {
    EvidenceTransport.bluetooth => bluetooth,
    EvidenceTransport.internet => internet,
  };

  RiderTransportEvidence snapshot(String riderId) => RiderTransportEvidence(
    riderId: riderId,
    bluetooth: bluetooth.snapshot(),
    internet: internet.snapshot(),
  );
}

class _TransportCounters {
  int events = 0;
  int firstDelivered = 0;
  int presenceUpdates = 0;
  DateTime? lastEventAt;
  DateTime? lastPresenceAt;

  void deliverEvent(DateTime at, {required bool first}) {
    events += 1;
    if (first) firstDelivered += 1;
    if (lastEventAt == null || at.isAfter(lastEventAt!)) lastEventAt = at;
  }

  void deliverPresence(DateTime at) {
    presenceUpdates += 1;
    if (lastPresenceAt == null || at.isAfter(lastPresenceAt!)) {
      lastPresenceAt = at;
    }
  }

  TransportCounters snapshot() => TransportCounters(
    events: events,
    firstDelivered: firstDelivered,
    presenceUpdates: presenceUpdates,
    lastEventAt: lastEventAt,
    lastPresenceAt: lastPresenceAt,
  );
}

/// Names other phones "phone A", "phone B" ... in the order this phone first met
/// them, so a log can say which phone dropped out without saying who it was.
///
/// The Nearby SDK's endpoint ids are random and are not stable across a
/// reconnection, so a label identifies a *connection*, not a handset: phone C
/// may be phone A again after it dropped out and came back. That is a limit of
/// what the SDK reports, and the diagnostics header says so.
class PeerAnonymiser {
  final Map<String, String> _labels = {};

  /// The label for [rawId], allocating the next one on first sight.
  String labelFor(String rawId) =>
      _labels.putIfAbsent(rawId, () => 'phone ${_letters(_labels.length)}');

  /// Every raw id seen so far. Exposed so a caller can scrub them out of free
  /// text, never so one can be printed.
  Iterable<String> get knownIds => _labels.keys;

  int get count => _labels.length;

  /// A, B ... Z, AA, AB ... — a ride never needs the second form, but a label
  /// must not collide when the 27th phone turns up.
  static String _letters(int index) {
    final letter = String.fromCharCode(0x41 + index % 26);
    return index < 26 ? letter : '${_letters(index ~/ 26 - 1)}$letter';
  }
}
