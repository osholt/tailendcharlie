import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/features/map/rider_symbol_picker.dart';

void main() {
  test('initials use first and last names, or two letters from one name', () {
    expect(riderInitials('Keith Simmonds'), 'KS');
    expect(riderInitials('  Katherine   L  '), 'KL');
    expect(riderInitials('Muffin'), 'MU');
    expect(riderInitials(''), '?');
  });

  test('symbol wire values remain backward compatible with bike styles', () {
    const initials = RiderSymbol.initials();
    const emoji = RiderSymbol.emoji('😈');

    expect(
      const RiderSymbol.motorcycle().wireValue(MotorcycleIconStyle.scrambler),
      MotorcycleIconStyle.scrambler.name,
    );
    expect(initials.wireValue(MotorcycleIconStyle.scrambler), 'initials');
    expect(emoji.wireValue(MotorcycleIconStyle.scrambler), 'emoji:😈');
    expect(
      RiderSymbol.fromWireValue(MotorcycleIconStyle.scrambler.name),
      riderSymbolDefault,
    );
    expect(RiderSymbol.fromWireValue('initials'), initials);
    expect(RiderSymbol.fromWireValue('emoji:😈'), emoji);
    expect(RiderSymbol.fromWireValue('emoji:not-an-emoji'), riderSymbolDefault);
  });

  test('live location carries a custom symbol through the existing field', () {
    final location = RiderLocation(
      riderId: 'keith',
      displayName: 'Keith Simmonds',
      role: RideRole.rider,
      sample: LocationSample(
        position: const GeoPoint(latitude: 51.5, longitude: -2.5),
        recordedAt: DateTime.utc(2026, 7, 29),
        accuracyMeters: 4,
      ),
      receivedAt: DateTime.utc(2026, 7, 29),
      motorcycleStyle: MotorcycleIconStyle.scrambler,
      riderSymbol: const RiderSymbol.emoji('😈'),
    );

    final json = location.toJson();
    expect(json['motorcycleStyle'], 'emoji:😈');
    expect(
      RiderLocation.fromJson(json).riderSymbol,
      const RiderSymbol.emoji('😈'),
    );
  });

  testWidgets('picker switches between initials and a chosen emoji', (
    tester,
  ) async {
    var symbol = riderSymbolDefault;
    var style = MotorcycleIconStyle.adventureTourer;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SingleChildScrollView(
                child: RiderSymbolPicker(
                  displayName: 'Keith Simmonds',
                  selectedSymbol: symbol,
                  motorcycleStyle: style,
                  badgeColor: Colors.teal,
                  keyPrefix: 'test-symbol',
                  bikeKeyPrefix: 'test-bike',
                  onSymbolChanged: (value) => update(() => symbol = value),
                  onMotorcycleStyleChanged: (value) =>
                      update(() => style = value),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('test-symbol-initials')));
    await tester.pump();
    expect(symbol, const RiderSymbol.initials());
    expect(find.text('KS'), findsWidgets);

    await tester.tap(find.byKey(const Key('test-symbol-emoji')));
    await tester.pump();
    final devilKey = Key(
      'test-symbol-emoji-${'😈'.runes.map((rune) => rune.toRadixString(16)).join('-')}',
    );
    await tester.ensureVisible(find.byKey(devilKey));
    await tester.tap(find.byKey(devilKey));
    await tester.pump();

    expect(symbol, const RiderSymbol.emoji('😈'));
    expect(find.text('😈'), findsWidgets);
  });

  testWidgets('initials use the available rider badge instead of body text', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: RiderMarkerBadge(
            style: MotorcycleIconStyle.scrambler,
            badgeColor: Colors.teal,
            symbol: RiderSymbol.initials(),
            displayName: 'Keith Simmonds',
            size: 34,
          ),
        ),
      ),
    );

    final text = tester.widget<Text>(find.text('KS'));
    expect(text.style?.fontSize, 34);
    expect(find.byKey(const Key('rider-marker-initials-fill')), findsOneWidget);
  });

  test('MapLibre raster keeps two initials on one line', () async {
    final result = await rasterizeRiderSymbolPng(
      symbol: const RiderSymbol.initials(),
      displayName: 'Keith Simmonds',
      motorcycleStyle: MotorcycleIconStyle.scrambler,
      size: 128,
    );
    final codec = await ui.instantiateImageCodec(result.bytes);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    final pixels = data!.buffer.asUint8List();
    var left = 128;
    var right = -1;
    var top = 128;
    var bottom = -1;
    for (var y = 0; y < 128; y += 1) {
      for (var x = 0; x < 128; x += 1) {
        if (pixels[(y * 128 + x) * 4 + 3] == 0) continue;
        left = x < left ? x : left;
        right = x > right ? x : right;
        top = y < top ? y : top;
        bottom = y > bottom ? y : bottom;
      }
    }

    expect(right - left, greaterThan(bottom - top));
    expect(right - left, greaterThan(100));
  });
}
