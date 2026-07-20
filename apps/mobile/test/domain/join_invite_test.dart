import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/join_invite.dart';

void main() {
  test('formats a code and token into one shareable invite', () {
    expect(
      joinInviteText('123456', 'aTokenWithPlentyOfEntropy'),
      '123456#aTokenWithPlentyOfEntropy',
    );
  });

  test('parses a bare compound invite', () {
    final parsed = parseJoinInvite('123456#aTokenWithPlentyOfEntropy');
    expect(parsed.code, '123456');
    expect(parsed.token, 'aTokenWithPlentyOfEntropy');
  });

  test('parses a compound invite embedded in a full shared sentence', () {
    final parsed = parseJoinInvite(
      'Join "Sunday Loop". Enter ride code 123456 in the app, or paste '
      'this invite: 123456#aTokenWithPlentyOfEntropy.',
    );
    expect(parsed.code, '123456');
    expect(parsed.token, 'aTokenWithPlentyOfEntropy');
  });

  test('falls back to a bare six-digit code with no token', () {
    final parsed = parseJoinInvite('123456');
    expect(parsed.code, '123456');
    expect(parsed.token, isNull);
  });

  test('finds a bare code within a larger pasted sentence', () {
    final parsed = parseJoinInvite('Enter ride code 123456 in the app.');
    expect(parsed.code, '123456');
    expect(parsed.token, isNull);
  });

  test('returns a null code for text with neither shape', () {
    final parsed = parseJoinInvite('not a code at all');
    expect(parsed.code, isNull);
    expect(parsed.token, isNull);
  });
}
