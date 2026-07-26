import '../domain/geo_point.dart';
import '../domain/quick_message.dart';
import '../domain/ride_event.dart';
import 'geo_calculations.dart';
import 'ride_event_authenticator.dart';
import 'ride_lifecycle.dart';

/// One rider's acknowledgement of another rider's quick message.
class QuickMessageAcknowledgement {
  const QuickMessageAcknowledgement({
    required this.riderId,
    required this.displayName,
    required this.acknowledgedAt,
  });

  final String riderId;
  final String displayName;
  final DateTime acknowledgedAt;
}

/// A quick message as the phone receiving it has to present it: who raised it,
/// what they raised, when, and whether anybody has said they have seen it.
///
/// The send path has always worked; nothing rendered the result anywhere except
/// one row in the dashboard event log, on a tab the rider was not looking at
/// (#151). This is the model every receive surface reads, so the map card, the
/// interrupt and the sender's own receipt cannot disagree.
class ReceivedQuickMessage {
  const ReceivedQuickMessage({
    required this.eventId,
    required this.senderRiderId,
    required this.senderDisplayName,
    required this.label,
    required this.priority,
    required this.raisedAt,
    required this.raisedFromLocalRider,
    this.message,
    this.raisedAtPosition,
    this.addressedToLocalRider = false,
    this.acknowledgements = const [],
  });

  /// The journal event this came from — the identity an acknowledgement names.
  final String eventId;
  final String senderRiderId;
  final String senderDisplayName;

  /// The kind, or null when a newer build raised a kind this one has never
  /// heard of. [label] is always present, so an unknown kind is still shown
  /// with the words the sender chose rather than dropped.
  final QuickMessage? message;

  /// What the sender called it. Their own words, always relayed.
  final String label;
  final EventPriority priority;
  final DateTime raisedAt;

  /// Where the sender was when they raised it, when they relayed one.
  ///
  /// Deliberately the raised-at fix rather than a live one: a rider who has
  /// stopped for fuel is not moving, and this position survives their location
  /// events ageing out of the 30-minute retention band.
  final GeoPoint? raisedAtPosition;

  /// True when this phone raised it, so its own surfaces show a receipt rather
  /// than an alert.
  final bool raisedFromLocalRider;

  /// True when the sender addressed it to this rider specifically (the leader
  /// and TEC recipient list the map's SOS and issue controls build), rather
  /// than to the whole group.
  final bool addressedToLocalRider;

  final List<QuickMessageAcknowledgement> acknowledgements;

  bool get isAcknowledged => acknowledgements.isNotEmpty;

  /// Whether this may take the screen over.
  ///
  /// Only the critical band does. "Need fuel" must not blank the map at 60 mph,
  /// which is the whole reason [QuickMessage.priority] exists.
  bool get interrupts => priority == EventPriority.critical;

  /// Whether this warrants the alert palette without interrupting: a mechanical
  /// problem or a blocked route is not an emergency, and is not routine either.
  bool get isPressing => priority == EventPriority.important;

  QuickMessageAcknowledgement? get firstAcknowledgement =>
      acknowledgements.isEmpty ? null : acknowledgements.first;

  /// The sentence a rider reads: "Bill needs fuel".
  ///
  /// Falls back to the sender's own label for a kind this build does not know.
  String get headline =>
      message?.sentenceFor(senderDisplayName) ?? '$senderDisplayName: $label';

  bool acknowledgedBy(String riderId) =>
      acknowledgements.any((entry) => entry.riderId == riderId);

  ReceivedQuickMessage withAcknowledgements(
    List<QuickMessageAcknowledgement> entries,
  ) => ReceivedQuickMessage(
    eventId: eventId,
    senderRiderId: senderRiderId,
    senderDisplayName: senderDisplayName,
    label: label,
    priority: priority,
    raisedAt: raisedAt,
    raisedFromLocalRider: raisedFromLocalRider,
    message: message,
    raisedAtPosition: raisedAtPosition,
    addressedToLocalRider: addressedToLocalRider,
    acknowledgements: List.unmodifiable(entries),
  );
}

/// Where the rider who raised a quick message is, relative to the rider reading
/// it.
///
/// Two forms, because only one of them is ever honest: along the loaded route
/// when both riders are demonstrably on it, and a straight line with a compass
/// bearing when they are not. A distance along a route neither rider is on is a
/// number that means nothing.
class QuickMessageOrigin {
  const QuickMessageOrigin({
    required this.distanceMeters,
    required this.alongRoute,
    this.senderIsBehind,
    this.bearingDegrees,
    this.positionIsLive = false,
  });

  final double distanceMeters;

  /// True when [distanceMeters] was measured along the loaded route rather than
  /// as a straight line.
  final bool alongRoute;

  /// Whether the sender is behind the reader along the route. Null when
  /// [alongRoute] is false — off the route there is no "back".
  final bool? senderIsBehind;

  /// Degrees clockwise from true north towards the sender. Set whenever
  /// [alongRoute] is false, so the reader knows which way to look.
  final double? bearingDegrees;

  /// True when this was measured from the sender's live position rather than
  /// the fix they relayed with the message.
  final bool positionIsLive;

  /// The eight-point compass label for [bearingDegrees].
  ///
  /// Eight points, not sixteen: a rider glancing at a phone on a mount needs
  /// "NE", and "NNE" costs reading time for precision a straight-line bearing
  /// does not have anyway.
  String? get compassLabel {
    final bearing = bearingDegrees;
    if (bearing == null) return null;
    const points = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return points[(((bearing % 360) + 22.5) ~/ 45) % 8];
  }

  /// Resolves the honest form for one pair of positions.
  ///
  /// [maximumOnRouteDistanceMeters] mirrors
  /// `LeaderRideStatusCalculator.maximumOnRouteDistanceMeters`, so "on the
  /// route" means the same thing here as it does in the TEC gap.
  static QuickMessageOrigin? between({
    required GeoPoint? readerPosition,
    required GeoPoint? senderPosition,
    List<GeoPoint> route = const [],
    bool positionIsLive = false,
    double maximumOnRouteDistanceMeters = 250,
  }) {
    if (readerPosition == null || senderPosition == null) return null;
    if (route.length >= 2) {
      final reader = GeoCalculations.projectOntoPolyline(readerPosition, route);
      final sender = GeoCalculations.projectOntoPolyline(senderPosition, route);
      if (reader.distanceFromRouteMeters <= maximumOnRouteDistanceMeters &&
          sender.distanceFromRouteMeters <= maximumOnRouteDistanceMeters) {
        final delta =
            sender.distanceAlongRouteMeters - reader.distanceAlongRouteMeters;
        return QuickMessageOrigin(
          distanceMeters: delta.abs(),
          alongRoute: true,
          senderIsBehind: delta < 0,
          positionIsLive: positionIsLive,
        );
      }
    }
    return QuickMessageOrigin(
      distanceMeters: GeoCalculations.distanceMeters(
        readerPosition,
        senderPosition,
      ),
      alongRoute: false,
      bearingDegrees: GeoCalculations.bearingDegrees(
        readerPosition,
        senderPosition,
      ),
      positionIsLive: positionIsLive,
    );
  }
}

/// A received quick message together with where its sender is — everything the
/// ride surfaces need to present one, and nothing they have to work out.
class RideQuickMessageAlert {
  const RideQuickMessageAlert({required this.message, this.origin});

  final ReceivedQuickMessage message;

  /// Null when the sender has never reported a position and did not relay one:
  /// a surface says so rather than showing a zero or an empty gap, the rule
  /// #88 anchored for the TEC surfaces.
  final QuickMessageOrigin? origin;
}

/// Rebuilds the quick messages this phone should be presenting, from the
/// journal.
///
/// Every rule lives here so the map card, the critical interrupt, the sender's
/// receipt and any later companion surface cannot disagree:
///
/// * signature-verified for this ride, like every other relayed fact;
/// * addressed to the local rider, or group-visible — a message with a
///   recipient list this rider is not on is not theirs to see;
/// * inside its own expiry;
/// * retired by a later "Resolved" from the same rider, and by that rider
///   leaving the ride;
/// * acknowledgements folded onto the message they name.
///
/// ### Why an acknowledgement is itself a `statusMessage`
///
/// It carries `acknowledgesQuickMessageEventId`, exactly as `iceInfoViewed`
/// carries `sharedEventId`. A new `RideEventType` would have needed the relay's
/// own event-type allowlist and a capability to negotiate, so acknowledgement
/// would have silently not relayed until a server deploy reached production. A
/// `statusMessage` is already allowlisted, already capped at two hours'
/// retention and already carries `recipientRiderIds`, so this works on the relay
/// that is running today. An older build shows it in the event log as its label
/// and otherwise ignores it.
class ReceivedQuickMessageReducer {
  const ReceivedQuickMessageReducer();

  /// The payload key that makes a `statusMessage` an acknowledgement of another
  /// one rather than a new message.
  static const acknowledgesKey = 'acknowledgesQuickMessageEventId';

  List<ReceivedQuickMessage> fromEvents({
    required String rideId,
    required String inviteSecret,
    required Iterable<RideEvent> events,
    required String localRiderId,
    required DateTime now,
    Map<String, String> displayNames = const {},
    Iterable<String> departedRiderIds = const [],
    bool rideEnded = false,
  }) {
    if (rideEnded) return const [];
    final ordered =
        events
            .where(
              (event) =>
                  event.rideId == rideId &&
                  event.type == RideEventType.statusMessage &&
                  RideEventAuthenticator.verify(event, inviteSecret),
            )
            .toList(growable: false)
          ..sort(RideLifecycleReducer.compareEvents);
    final departed = departedRiderIds.toSet();
    final messages = <String, ReceivedQuickMessage>{};
    final acknowledgements = <String, List<QuickMessageAcknowledgement>>{};
    for (final event in ordered) {
      final acknowledged = event.payload[acknowledgesKey];
      if (acknowledged is String) {
        (acknowledgements[acknowledged] ??= []).add(
          QuickMessageAcknowledgement(
            riderId: event.deviceId,
            displayName: _nameFor(event, displayNames),
            acknowledgedAt: event.createdAt,
          ),
        );
        continue;
      }
      if (!_isVisibleTo(event, localRiderId)) continue;
      final message = tryParseQuickMessage(event.payload['message']);
      final label = event.payload['label'];
      if (label is! String || label.isEmpty) continue;
      if (message?.retiresEarlierMessages ?? false) {
        // The rider says the thing they raised is dealt with. That clears their
        // card rather than adding a second one to it.
        messages.removeWhere(
          (_, existing) => existing.senderRiderId == event.deviceId,
        );
        continue;
      }
      messages[event.id] = ReceivedQuickMessage(
        eventId: event.id,
        senderRiderId: event.deviceId,
        senderDisplayName: _nameFor(event, displayNames),
        label: label,
        // The sender's own priority is authoritative when this build knows the
        // kind; otherwise the relayed envelope priority is what there is.
        priority: message?.priority ?? event.priority,
        raisedAt: event.createdAt,
        raisedFromLocalRider: event.deviceId == localRiderId,
        message: message,
        raisedAtPosition: _positionFrom(event.payload['position']),
        addressedToLocalRider: _recipients(event).contains(localRiderId),
      );
    }
    final live =
        messages.values
            .where(
              (message) =>
                  !departed.contains(message.senderRiderId) &&
                  !_isExpired(message, ordered, now),
            )
            .map(
              (message) => message.withAcknowledgements(
                acknowledgements[message.eventId] ?? const [],
              ),
            )
            .toList()
          ..sort(_mostUrgentFirst);
    return List.unmodifiable(live);
  }

  /// The payload one rider records to tell the sender their message was seen.
  ///
  /// Addressed to the sender, so an acknowledgement is not group noise, and
  /// labelled so the dashboard event log reads as a sentence on both phones.
  static Map<String, Object?> acknowledgementPayload({
    required ReceivedQuickMessage message,
  }) => {
    acknowledgesKey: message.eventId,
    'label': 'Seen: ${message.label}',
    'recipientRiderIds': [message.senderRiderId],
  };

  /// Whether [event] is an acknowledgement rather than a new quick message.
  static bool isAcknowledgement(RideEvent event) =>
      event.type == RideEventType.statusMessage &&
      event.payload[acknowledgesKey] is String;

  static int _mostUrgentFirst(
    ReceivedQuickMessage first,
    ReceivedQuickMessage second,
  ) {
    final byPriority = second.priority.index.compareTo(first.priority.index);
    if (byPriority != 0) return byPriority;
    final byUnacknowledged = (first.isAcknowledged ? 1 : 0).compareTo(
      second.isAcknowledged ? 1 : 0,
    );
    if (byUnacknowledged != 0) return byUnacknowledged;
    return second.raisedAt.compareTo(first.raisedAt);
  }

  /// A quick message with no recipient list is group-visible, which is what the
  /// dashboard grid sends. One with a list is only for the riders on it —
  /// deliberately the opposite default from a rejoin share, because the sender
  /// chose the whole group when they left the list off.
  static bool _isVisibleTo(RideEvent event, String localRiderId) {
    if (event.deviceId == localRiderId) return true;
    final recipients = _recipients(event);
    return recipients.isEmpty || recipients.contains(localRiderId);
  }

  static Set<String> _recipients(RideEvent event) {
    final recipients = event.payload['recipientRiderIds'];
    if (recipients is! List) return const {};
    return recipients.whereType<String>().toSet();
  }

  static String _nameFor(RideEvent event, Map<String, String> displayNames) {
    final relayed = event.payload['senderDisplayName'];
    if (relayed is String && relayed.trim().isNotEmpty) return relayed.trim();
    return displayNames[event.deviceId] ?? 'A rider';
  }

  static GeoPoint? _positionFrom(Object? value) {
    if (value is! Map) return null;
    final latitude = value['latitude'];
    final longitude = value['longitude'];
    if (latitude is! num || longitude is! num) return null;
    if (latitude.abs() > 90 || longitude.abs() > 180) return null;
    return GeoPoint(
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
    );
  }

  static bool _isExpired(
    ReceivedQuickMessage message,
    List<RideEvent> events,
    DateTime now,
  ) {
    for (final event in events) {
      if (event.id != message.eventId) continue;
      final expiresAt = event.expiresAt;
      return expiresAt != null && !expiresAt.isAfter(now);
    }
    return false;
  }
}
