// The body of the emergency text (#173).
//
// The control opens the phone's messaging app with no recipient, on purpose: a
// ride invite carries a code, never a phone number. What it *can* do is fill in
// the message, and the position is the one thing a recipient outside the ride
// cannot work out for themselves. It was missing.

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/features/map/ride_map_feature.dart';

void main() {
  test('carries the position as coordinates and as a link', () {
    final body = emergencyMessageBody(
      const GeoPoint(latitude: 51.444158, longitude: -2.474737),
    );

    expect(body, contains('I have stopped and need assistance'));
    expect(body, contains('51.444158, -2.474737'));
    expect(
      body,
      contains('openstreetmap.org/?mlat=51.444158&mlon=-2.474737'),
      reason: 'a tappable link is what a recipient acts on',
    );
  });

  test('rounds to a precision a phone fix can justify', () {
    final body = emergencyMessageBody(
      const GeoPoint(latitude: 51.4441581240971, longitude: -2.4747370639671),
    );

    expect(body, contains('51.444158, -2.474737'));
    expect(
      body,
      isNot(contains('51.4441581')),
      reason: 'more decimals imply an accuracy no phone has',
    );
  });

  test('says plainly when there is no fix to send', () {
    final body = emergencyMessageBody(null);

    expect(body, contains('do not have a GPS position'));
    expect(
      body,
      isNot(contains('0.000000')),
      reason: 'a missing fix must never be sent as a coordinate',
    );
  });
}
