import 'package:flutter/services.dart';

import '../domain/join_invite.dart';

const rideInvitationPath = '/join.html';

/// A private, server-resolvable invitation captured from an App/Universal Link.
///
/// The token is capability material. It is deliberately carried only in the URL
/// fragment, which browsers do not send to the web server or in referrer
/// headers. The relay still resolves and validates it when the rider joins, so
/// an expired or revoked ride gets the same explanation as paste-to-join.
class RideInvitationLink {
  const RideInvitationLink({required this.rideCode, required this.joinToken});

  final String rideCode;
  final String joinToken;
}

abstract interface class IncomingRideInvitationLinkSource {
  Future<String?> consumePending();
}

/// Pulls the latest ride-invitation link captured by the native lifecycle
/// bridge. Pull delivery handles both cold starts and warm resumes without an
/// event-listener race.
class RideInvitationLinkChannel implements IncomingRideInvitationLinkSource {
  const RideInvitationLinkChannel();

  static const _channel = MethodChannel('me.osholt.ride_relay/planner_link');

  @override
  Future<String?> consumePending() async {
    try {
      return await _channel.invokeMethod<String>(
        'consumePendingRideInvitationLink',
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// Builds the only invitation URL format the app shares.
///
/// [Uri.replace] percent-encodes the `#` inside `code#token`; it remains inside
/// the outer URL fragment and is decoded again by [Uri.fragment].
String rideInvitationUrl(String rideCode, String joinToken) {
  final invitation = joinInviteText(rideCode, joinToken);
  final parsed = parseJoinInvite(invitation);
  if (parsed.code != rideCode || parsed.token != joinToken) {
    throw const FormatException('Cannot create an invalid ride invitation.');
  }
  return Uri.https(
    'tailendcharlie.app',
    rideInvitationPath,
  ).replace(fragment: invitation).toString();
}

/// Parses a Tail End Charlie invitation link without ever logging its fragment.
RideInvitationLink? rideInvitationFromLink(String value) {
  if (value.length > 2048) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.toLowerCase() != 'tailendcharlie.app' ||
      uri.path != rideInvitationPath ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasQuery ||
      !uri.hasFragment) {
    return null;
  }

  final String fragment;
  try {
    fragment = Uri.decodeComponent(uri.fragment);
  } on FormatException {
    return null;
  }
  final invite = parseJoinInvite(fragment);
  final code = invite.code;
  final token = invite.token;
  if (code == null || token == null) return null;

  // Reject prose or extra capability material around the invitation. Sharing
  // text may contain prose, but the URL fragment itself has one exact grammar.
  if (fragment.trim() != joinInviteText(code, token)) return null;
  return RideInvitationLink(rideCode: code, joinToken: token);
}
