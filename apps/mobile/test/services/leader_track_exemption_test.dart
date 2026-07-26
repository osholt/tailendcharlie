import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/services/leader_track_exemption.dart';

void main() {
  final leaderTrack = [
    for (var index = 0; index <= 10; index += 1)
      GeoPoint(latitude: 52, longitude: -1 + index * 0.01),
  ];

  test('a rider inside the corridor is following the leader', () {
    expect(
      LeaderTrackExemption.isFollowingLeaderTrack(
        position: const GeoPoint(latitude: 52.0005, longitude: -0.95),
        leaderTrack: leaderTrack,
      ),
      isTrue,
    );
  });

  test('a rider outside the corridor is not', () {
    expect(
      LeaderTrackExemption.isFollowingLeaderTrack(
        position: const GeoPoint(latitude: 52.01, longitude: -0.95),
        leaderTrack: leaderTrack,
      ),
      isFalse,
    );
  });

  test('an uncertain fix gets the benefit of its own accuracy', () {
    const justOutside = GeoPoint(latitude: 52.0015, longitude: -0.95);
    expect(
      LeaderTrackExemption.isFollowingLeaderTrack(
        position: justOutside,
        leaderTrack: leaderTrack,
      ),
      isFalse,
    );
    expect(
      LeaderTrackExemption.isFollowingLeaderTrack(
        position: justOutside,
        leaderTrack: leaderTrack,
        accuracyMeters: 75,
      ),
      isTrue,
    );
  });

  test('a leader with no track yet exempts nobody', () {
    expect(
      LeaderTrackExemption.isFollowingLeaderTrack(
        position: const GeoPoint(latitude: 52, longitude: -1),
        leaderTrack: const [GeoPoint(latitude: 52, longitude: -1)],
      ),
      isFalse,
    );
  });
}
