import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';

void main() {
  RouteManeuver maneuver({
    String type = 'arrive',
    double latitude = 51.4545,
    double longitude = -2.5879,
    String? modifier,
    int? exitNumber,
    double? bearingBefore,
  }) => RouteManeuver(
    position: GeoPoint(latitude: latitude, longitude: longitude),
    type: type,
    modifier: modifier,
    exitNumber: exitNumber,
    bearingBeforeDegrees: bearingBefore,
  );

  group('a junction keeps its identity when the route is rebuilt (#428)', () {
    test('two objects describing the same junction share an identity', () {
      // The defect this exists for: `hashCode` is per object here, because this
      // class defines no value equality. A route is re-derived constantly, and
      // anything keyed on hashCode treated each rebuild as a new junction — so
      // "Arrive at the destination" was announced again every time.
      expect(maneuver().identity, maneuver().identity);
      expect(
        identical(maneuver(), maneuver()),
        isFalse,
        reason: 'these really are distinct objects, which is the whole point',
      );
    });

    test('identity survives fields that a rebuild may legitimately move', () {
      // A re-fetch can carry different bearings for the same junction without it
      // becoming a different junction.
      expect(
        maneuver(bearingBefore: 10).identity,
        maneuver(bearingBefore: 11).identity,
      );
    });

    test('different junctions do not share an identity', () {
      expect(
        maneuver(latitude: 51.4545).identity,
        isNot(maneuver(latitude: 51.4600).identity),
      );
      expect(
        maneuver(type: 'arrive').identity,
        isNot(maneuver(type: 'turn').identity),
      );
      expect(
        maneuver(modifier: 'left').identity,
        isNot(maneuver(modifier: 'right').identity),
      );
      // Two exits of the same roundabout sit at the same node, so the exit
      // number is what tells them apart.
      expect(
        maneuver(type: 'roundabout', exitNumber: 1).identity,
        isNot(maneuver(type: 'roundabout', exitNumber: 3).identity),
      );
    });

    test('a difference finer than a metre is the same junction', () {
      // Five decimal places is about a metre: finer than any two distinct
      // junctions, coarser than the last bits of a double a re-fetch can move.
      expect(
        maneuver(latitude: 51.45450001).identity,
        maneuver(latitude: 51.45450002).identity,
      );
    });
  });
}
