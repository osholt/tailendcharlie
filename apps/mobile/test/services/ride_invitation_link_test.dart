import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/join_invite.dart';
import 'package:ride_relay/services/ride_invitation_link.dart';

void main() {
  const code = '123456';
  const token = 'Abcdefghijklmnop12345678';

  test('private invitation material is carried only in the fragment', () {
    final value = rideInvitationUrl(code, token);
    final uri = Uri.parse(value);

    expect(uri.scheme, 'https');
    expect(uri.host, 'tailendcharlie.app');
    expect(uri.path, '/join.html');
    expect(uri.hasQuery, isFalse);
    expect(Uri.decodeComponent(uri.fragment), '$code#$token');
    expect(uri.path, isNot(contains(code)));
    expect(uri.query, isNot(contains(token)));

    final parsed = rideInvitationFromLink(value)!;
    expect(parsed.rideCode, code);
    expect(parsed.joinToken, token);
  });

  test('pasting the new URL retains the established code and token path', () {
    final parsed = parseJoinInvite(rideInvitationUrl(code, token));

    expect(parsed.code, code);
    expect(parsed.token, token);
    expect(parseJoinInvite('$code#$token').token, token);
  });

  test('rejects capability material outside the exact private fragment', () {
    expect(
      rideInvitationFromLink(
        'https://tailendcharlie.app/join.html?token=$token#$code',
      ),
      isNull,
    );
    expect(
      rideInvitationFromLink('https://example.com/join.html#$code%23$token'),
      isNull,
    );
    expect(
      rideInvitationFromLink(
        'https://tailendcharlie.app/join.html#open-$code%23$token',
      ),
      isNull,
    );
    expect(
      rideInvitationFromLink('https://tailendcharlie.app/join.html#$code'),
      isNull,
    );
  });
}
