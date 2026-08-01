/// Everything needed to join a ride, carried directly rather than looked up.
///
/// This is what makes an offline join possible at all (#279). Every existing join
/// path - typed code or pasted invite - ends in `RideCodeDirectory.resolve`, an
/// HTTPS call to the relay whose entire job is turning a six-digit code into
/// `{rideId, inviteSecret, resolveToken}`. So a group standing in a car park with
/// no signal cannot form a ride at all, which is precisely the situation this
/// product exists for.
///
/// A QR code has room for all three, so scanning one needs no network.
///
/// ## Why not a URL
///
/// A URL would spend bytes on a scheme and host to no purpose, and would invite
/// the secret into a path or query where web-server logs and browser history can
/// see it. Making an invitation *tappable* is a separate job with its own
/// constraints (#275); this is a machine-readable payload for a camera, and is
/// deliberately not something a browser will do anything with.
///
/// ## What it exposes
///
/// The ride's invite secret, in the clear. Anyone who photographs a displayed code
/// can join the ride. That is the same exposure as a shared invite link and is
/// acceptable for a private group, but it is the reason a display of this must be
/// deliberate and short-lived rather than a screen left sitting open.
class RideJoinPayload {
  const RideJoinPayload({
    required this.rideId,
    required this.rideCode,
    required this.inviteSecret,
    required this.joinToken,
  });

  /// Version prefix, so a payload from a future format is **rejected** rather
  /// than half-understood. A wrong join is worse than a refused one: a rider who
  /// silently ends up in a degraded session has no way to tell.
  static const scheme = 'tec1';

  /// Colon-separated because none of the four fields can contain a colon: the
  /// code is six digits, the id is a UUID, and both secrets are base64url, whose
  /// alphabet is `A-Za-z0-9-_`. So splitting cannot be ambiguous, and no escaping
  /// is needed to keep the payload short.
  static const _separator = ':';

  final String rideId;
  final String rideCode;
  final String inviteSecret;
  final String joinToken;

  String encode() =>
      [scheme, rideCode, rideId, inviteSecret, joinToken].join(_separator);

  /// Parses [raw], or throws [FormatException] with a reason a person can act on.
  ///
  /// The bounds mirror what the relay itself enforces when it serves these fields,
  /// so a payload this accepts is one the rest of the app can already handle. They
  /// are checked here rather than trusted because a QR code is arbitrary input
  /// from a camera - anyone can print one.
  static RideJoinPayload decode(String raw) {
    final parts = raw.trim().split(_separator);
    if (parts.length != 5 || parts.first != scheme) {
      throw const FormatException(
        'That code is not a Tail End Charlie ride invitation.',
      );
    }
    final [_, rideCode, rideId, inviteSecret, joinToken] = parts;

    if (!RegExp(r'^\d{6}$').hasMatch(rideCode)) {
      throw const FormatException('That invitation has no valid ride code.');
    }
    if (rideId.isEmpty || rideId.length > 128) {
      throw const FormatException('That invitation has no valid ride.');
    }
    // Below 16 characters the secret cannot drive authenticated transport - the
    // relay, push registration and the event authenticator all check the same
    // floor - so accepting a shorter one would produce a session that looks
    // joined and silently cannot talk to anybody.
    if (inviteSecret.length < 16 || inviteSecret.length > 512) {
      throw const FormatException(
        'That invitation is incomplete and cannot join securely.',
      );
    }
    if (joinToken.length < 16 || joinToken.length > 128) {
      throw const FormatException(
        'That invitation is incomplete and cannot join securely.',
      );
    }
    return RideJoinPayload(
      rideId: rideId,
      rideCode: rideCode,
      inviteSecret: inviteSecret,
      joinToken: joinToken,
    );
  }

  /// Never includes the secrets. A payload's `toString` reaches logs and error
  /// reports, and a ride secret has no business in either.
  @override
  String toString() => 'RideJoinPayload(ride $rideCode)';
}
