import '../domain/ride_event.dart';
import '../domain/ride_role.dart';
import 'ride_event_authenticator.dart';
import 'ride_lifecycle.dart';

/// One rider's **own** phone number, as it travels to the people who might need
/// to ring them (issue #188).
///
/// This is not [RideEventType.iceInfoShared] and must never be built from it.
/// An ICE share carries a rider's next of kin — the person to ring *about* them
/// — so dialling it to "call the leader" would ring the leader's partner to say
/// the leader is fine but somebody else has stopped. The two are separate
/// fields, separate events and separate consents.
///
/// Privacy, stated plainly, the same way [RideEventType.rejoinRouteShared]
/// states it: the ride relay is ride-scoped rather than per-recipient
/// encrypted, so "addressed to the leader and TEC" means the event names its
/// intended recipients, the sharer only sends when a recipient is known, and
/// every consumer drops a share it is not addressed to. It is not a
/// cryptographic guarantee against a ride member who already holds the ride
/// secret. Retention is bounded like an ICE share: a hard per-share TTL on the
/// client, a matching server-side retention cap, and a purge of anything
/// unused the moment the ride ends.
///
/// Never a rider's identity. A number is for dialling from the emergency sheet.
/// Nothing here belongs beside a name in the roster, in an observer surface or
/// in a snapshot export.
class RiderContactShare {
  const RiderContactShare({
    required this.eventId,
    required this.riderId,
    required this.displayName,
    required this.phoneNumber,
    required this.sharedAt,
    required this.sharedByRole,
    required this.toRideGroup,
  });

  final String eventId;

  /// The rider the number belongs to. Always the event author: nobody may
  /// publish a number on somebody else's behalf.
  final String riderId;

  /// Carried on the event for the same reason `iceInfoShared` carries it: a
  /// recipient may not have this rider in their roster yet. Only ever used to
  /// label the dial control, never to establish who a rider is.
  final String displayName;

  final String phoneNumber;
  final DateTime sharedAt;

  /// The role the sharer held when they shared. Why the recipient set is what it
  /// is, recorded so a reader can tell a coordination role's published contact
  /// from a rider's addressed one without re-deriving roles.
  final RideRole sharedByRole;

  /// True when the sharer holds a coordination role and is therefore reachable
  /// by the riders they are leading — the case in the original request, where a
  /// stopped rider needs to ring the leader or the TEC.
  final bool toRideGroup;

  Map<String, Object?> toJson() => {
    'riderId': riderId,
    'displayName': displayName,
    'phone': phoneNumber,
    'sharedByRole': sharedByRole.name,
  };

  /// Strict decode. Returns null rather than throwing, because one malformed
  /// share from a peer must never take the rest of a batch down with it.
  ///
  /// [event] supplies the author, the time and the recipient form: none of the
  /// three is read from the payload, so a peer cannot claim to be somebody else
  /// or backdate a share.
  static RiderContactShare? tryFromEvent(RideEvent event) {
    if (event.type != RideEventType.riderContactShared) return null;
    final raw = event.payload['contact'];
    if (raw is! Map) return null;
    final json = <String, Object?>{
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
    final riderId = _string(json['riderId'], 128);
    final displayName = _string(json['displayName'], 80);
    final phoneNumber = normalisePhoneNumber(json['phone']);
    // Only the rider a number belongs to may publish it.
    if (riderId == null || riderId != event.deviceId) return null;
    if (displayName == null || phoneNumber == null) return null;
    return RiderContactShare(
      eventId: event.id,
      riderId: riderId,
      displayName: displayName,
      phoneNumber: phoneNumber,
      sharedAt: event.createdAt,
      sharedByRole:
          _enumByName(RideRole.values, json['sharedByRole']) ?? RideRole.rider,
      toRideGroup: event.payload['recipientRiderIds'] == null,
    );
  }

  /// The characters a dialable number may contain, and nothing else.
  ///
  /// This value is put into a `tel:`/`sms:` URI built from data another ride
  /// member sent, so the charset is a security bound rather than a formatting
  /// nicety: no scheme, no path separator, no query, no control character and
  /// no whitespace beyond a single separating space can survive it. A number
  /// that does not survive is rejected outright rather than sanitised into
  /// something that dials somewhere unintended.
  static final _allowedPattern = RegExp(r'^\+?[0-9(](?:[0-9 ()./-]*[0-9])?$');
  static final _digitPattern = RegExp(r'[0-9]');

  static const minimumDigits = 5;
  static const maximumLength = 24;

  /// Returns the trimmed, validated number, or null when it is absent, empty or
  /// not a plain dialable string. Never guesses and never rewrites: what the
  /// rider typed is what is dialled.
  static String? normalisePhoneNumber(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > maximumLength) return null;
    if (!_allowedPattern.hasMatch(trimmed)) return null;
    if (_digitPattern.allMatches(trimmed).length < minimumDigits) return null;
    return trimmed;
  }

  static T? _enumByName<T extends Enum>(List<T> values, Object? value) {
    if (value is! String) return null;
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
    return null;
  }

  static String? _string(Object? value, int maximumLength) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > maximumLength) return null;
    return trimmed;
  }
}

/// How long a shared number lives, on the client as well as the relay.
///
/// Two hours, the band [RideEventType.iceInfoShared] already uses: long enough
/// to cover the ride a rider shared it for, short enough that a phone which
/// never syncs again is not left holding somebody's number for days. The
/// ride-end purge normally gets there first.
const riderContactShareLifetime = Duration(hours: 2);

/// Who a rider's number goes to, in one place so the rule is reversible.
///
/// Issue #188 settles two questions, and they resolve differently by role:
///
/// * A rider who holds no coordination role addresses their number to **the
///   leader and the TEC, and nobody else**. Those two have a reason to phone a
///   rider who has stopped or gone quiet; the group does not, and a number that
///   reaches everyone is a number riders will not share.
/// * A rider who **holds** the lead or TEC role is sharing for the opposite
///   reason: the case in the request is a stopped rider needing to reach them.
///   A contact for the role is of no use addressed to the other role-holder, so
///   it is offered to the ride — which also keeps it usable by a rider who
///   joins after it was shared, rather than silently excluding them.
///
/// Either way it is opt-in, per-ride, and purged when the ride ends. Reverse the
/// second branch here and the whole feature narrows to coordination roles only.
class RiderContactRecipients {
  const RiderContactRecipients._(this.riderIds, this.toRideGroup);

  /// The empty recipient list means "the whole ride", exactly as it does for
  /// `iceInfoShared` and `statusMessage`.
  const RiderContactRecipients.rideGroup() : this._(const [], true);

  const RiderContactRecipients.addressed(List<String> riderIds)
    : this._(riderIds, false);

  final List<String> riderIds;
  final bool toRideGroup;

  /// Nothing to share with: there is no leader and no TEC to address, so the
  /// rider is told rather than having an event recorded that reaches nobody.
  bool get isEmpty => !toRideGroup && riderIds.isEmpty;

  /// [localRole] is the role the sharer holds now. [leaderRiderId] and
  /// [tecRiderIds] are the current coordination roles, excluding the sharer.
  static RiderContactRecipients resolve({
    required RideRole localRole,
    required String? leaderRiderId,
    required Iterable<String> tecRiderIds,
  }) {
    if (localRole == RideRole.lead || localRole == RideRole.tailEndCharlie) {
      return const RiderContactRecipients.rideGroup();
    }
    return RiderContactRecipients.addressed([?leaderRiderId, ...tecRiderIds]);
  }
}

/// Rebuilds the numbers shared **with the local rider** from the journal.
///
/// Every filter is a rule from #188, applied in one place so the emergency
/// sheet, the roster and any companion surface cannot disagree:
///
/// * signed with the ride secret, so a number cannot be planted by an
///   unauthenticated event;
/// * authored by the rider it describes;
/// * addressed to the local rider, or explicitly to the ride;
/// * inside its own TTL;
/// * not from a rider who has left the ride, and never the local rider's own —
///   nobody needs a control to ring themselves;
/// * gone entirely once the ride has ended.
class RiderContactShareReducer {
  const RiderContactShareReducer();

  /// Keyed by rider id, latest share per rider wins.
  Map<String, RiderContactShare> fromEvents({
    required String rideId,
    required String inviteSecret,
    required Iterable<RideEvent> events,
    required String localRiderId,
    required DateTime now,
    Iterable<String> departedRiderIds = const [],
    bool rideEnded = false,
  }) {
    if (rideEnded) return const {};
    final ordered =
        events
            .where(
              (event) =>
                  event.rideId == rideId &&
                  event.type == RideEventType.riderContactShared &&
                  RideEventAuthenticator.verify(event, inviteSecret),
            )
            .toList(growable: false)
          ..sort(RideLifecycleReducer.compareEvents);
    final departed = departedRiderIds.toSet();
    final latest = <String, RiderContactShare>{};
    for (final event in ordered) {
      if (!isAddressedTo(event, localRiderId)) continue;
      final share = RiderContactShare.tryFromEvent(event);
      if (share == null) continue;
      if (share.riderId == localRiderId) continue;
      if (departed.contains(share.riderId)) continue;
      if (!now.isBefore(share.sharedAt.add(riderContactShareLifetime))) {
        continue;
      }
      latest[share.riderId] = share;
    }
    return Map.unmodifiable(latest);
  }

  /// Builds the payload a rider records.
  static Map<String, Object?> payload({
    required RiderContactShare share,
    required RiderContactRecipients recipients,
  }) => {
    'contact': share.toJson(),
    if (!recipients.toRideGroup)
      'recipientRiderIds': recipients.riderIds.toSet().toList(growable: false),
  };

  /// A share with no recipient list is the explicit ride-wide form a
  /// coordination role publishes; any other list must name the reader.
  ///
  /// Fails closed on a malformed list: a `recipientRiderIds` that is present but
  /// not a list is never treated as ride-wide.
  static bool isAddressedTo(RideEvent event, String riderId) {
    final recipients = event.payload['recipientRiderIds'];
    if (recipients == null) return true;
    if (recipients is! List) return false;
    return recipients.contains(riderId);
  }
}
