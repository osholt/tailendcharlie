import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/completed_rides_controller.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/geo_point.dart' as awareness;
import 'package:ride_relay/domain/quick_message.dart';
import 'package:ride_relay/domain/ride_broadcast_record.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/ride/previous_rides_screen.dart';
import 'package:ride_relay/features/ride/ride_dashboard.dart'
    show statusMessageRowTitle;
import 'package:ride_relay/features/ride/ride_broadcasts_card.dart';
import 'package:ride_relay/services/completed_ride_archiver.dart';
import 'package:ride_relay/services/completed_ride_sharer.dart';
import 'package:ride_relay/services/received_quick_message.dart';
import 'package:ride_relay/services/ride_broadcast_log.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/ride_summary_exporter.dart';

/// #854: what the leader told the group is part of the ride's history - rebuilt
/// from the journal, saved with the completed ride, listed with its times after
/// the ride, and carried in the shared summary.
void main() {
  const rideId = 'ride-1';
  const secret = 'shared-secret';
  // Isle of Man: nowhere near any rider's home.
  const here = awareness.GeoPoint(latitude: 54.15, longitude: -4.48);
  final start = DateTime.utc(2026, 10, 4, 12);

  final session = RideSession(
    rideId: rideId,
    rideCode: 'ABC123',
    inviteSecret: secret,
    joinToken: 'test-join-token-0123456789',
    localRiderId: 'becks',
    displayName: 'Becks',
    role: RideRole.rider,
    joinedAt: start,
  );

  RideEvent signed(
    String id,
    String device,
    RideEventType type,
    Map<String, Object?> payload,
    DateTime at, {
    String key = secret,
  }) {
    final unsigned = RideEvent(
      id: id,
      rideId: rideId,
      deviceId: device,
      type: type,
      priority: EventPriority.important,
      createdAt: at,
      payload: payload,
      signature: '',
    );
    return RideEvent(
      id: id,
      rideId: rideId,
      deviceId: device,
      type: type,
      priority: EventPriority.important,
      createdAt: at,
      payload: payload,
      signature: RideEventAuthenticator.sign(unsigned, key),
    );
  }

  RideEvent leaderRole(String device) => signed(
    'role-$device',
    device,
    RideEventType.rideCreated,
    {'role': 'lead'},
    start,
  );

  RideEvent sent(
    String id,
    QuickMessage kind,
    DateTime at, {
    String device = 'oliver',
    String name = 'Oliver',
    bool position = true,
    String? label,
  }) => signed(id, device, RideEventType.statusMessage, {
    'message': kind.name,
    'label': label ?? kind.label,
    'senderDisplayName': name,
    if (position) 'position': here.toJson(),
  }, at);

  // Built from local components so the time on screen does not depend on the zone
  // the test runs in.
  final first = DateTime(2026, 10, 4, 13, 40, 2);
  final second = DateTime(2026, 10, 4, 14, 5, 31);

  final journal = [
    leaderRole('oliver'),
    sent('b1', QuickMessage.pullOver, first),
    sent('b2', QuickMessage.regroupNextStop, second, position: false),
  ];

  List<RideBroadcastRecord> read(
    Iterable<RideEvent> events, {
    String me = 'becks',
    Map<String, String> names = const {},
  }) => const RideBroadcastLogReducer().fromEvents(
    rideId: rideId,
    inviteSecret: secret,
    events: events,
    localRiderId: me,
    displayNames: names,
  );

  group('the log', () {
    test('lists each broadcast with its time, who sent it, what and where', () {
      final log = read(journal);

      expect(log.map((record) => record.id), ['b1', 'b2']);
      final one = log.first;
      expect(one.sentBy, 'Oliver');
      expect(one.text, 'Pull over');
      expect(one.kind, 'pullOver');
      expect(one.sentAt.isAtSameMomentAs(first), isTrue);
      expect(one.position, here);
      expect(one.sentByLocalRider, isFalse);
      expect(log.last.position, isNull);
    });

    test('marks the rider\'s own', () {
      expect(read(journal, me: 'oliver').first.sentByLocalRider, isTrue);
    });

    test('is oldest first whatever order the journal held them in', () {
      expect(read(journal.reversed).map((record) => record.id), ['b1', 'b2']);
    });

    test('keeps a broadcast long after it left the banner', () {
      // The banner drops it after ten minutes; the history is for after the ride,
      // so it has no clock to expire against.
      final early = signed(
        'early',
        'oliver',
        RideEventType.statusMessage,
        {
          'message': 'pullOver',
          'label': 'Pull over',
          'senderDisplayName': 'Oliver',
        },
        start.add(const Duration(minutes: 5)),
      );

      expect(read([leaderRole('oliver'), early, ...journal]), hasLength(3));
    });

    test('is one entry per event, however often it was delivered', () {
      expect(read([...journal, ...journal]), hasLength(2));
    });

    test('holds only what the banner would have shown', () {
      final events = [
        ...journal,
        // Forged by a rider who was never the leader.
        sent(
          'forged',
          QuickMessage.wrongWay,
          first,
          device: 'nigel',
          name: 'Nigel',
        ),
        // A rider\'s own kind is not a leader broadcast.
        sent('fuel', QuickMessage.fuel, first, device: 'nigel', name: 'Nigel'),
        // A signature from another ride.
        signed(
          'foreign',
          'oliver',
          RideEventType.statusMessage,
          {'message': 'pullOver', 'label': 'Pull over'},
          first,
          key: 'another-secret',
        ),
      ];

      expect(read(events).map((record) => record.id), ['b1', 'b2']);
    });

    test('leaves out a rider\'s own kind even from the leader', () {
      // "Need fuel" is a quick message any rider sends, the leader included; it is
      // not a broadcast to the group and is not in this history.
      final events = [
        ...journal,
        sent('leader-fuel', QuickMessage.fuel, first, device: 'oliver'),
        sent('leader-help', QuickMessage.assistance, first, device: 'oliver'),
      ];

      expect(read(events).map((record) => record.id), ['b1', 'b2']);
    });

    test(
      'is not fooled by an acknowledgement that carries a broadcast\'s label',
      () {
        final message = const ReceivedQuickMessageReducer()
            .fromEvents(
              rideId: rideId,
              inviteSecret: secret,
              events: journal,
              localRiderId: 'becks',
              now: first,
            )
            .first;
        final seen = signed(
          'seen',
          'oliver',
          RideEventType.statusMessage,
          {
            ...ReceivedQuickMessageReducer.acknowledgementPayload(
              message: message,
            ),
            'message': 'pullOver',
          },
          first.add(const Duration(seconds: 10)),
        );

        expect(read([...journal, seen]).map((record) => record.id), [
          'b1',
          'b2',
        ]);
      },
    );

    test('names the leader from the roster when the event does not', () {
      final nameless = signed('b1', 'oliver', RideEventType.statusMessage, {
        'message': 'pullOver',
        'label': 'Pull over',
      }, first);

      expect(
        read(
          [leaderRole('oliver'), nameless],
          names: {'oliver': 'Ollie'},
        ).single.sentBy,
        'Ollie',
      );
      expect(
        read([leaderRole('oliver'), nameless]).single.sentBy,
        'The leader',
      );
    });

    test('drops a position off the globe rather than the message', () {
      final odd = signed('b1', 'oliver', RideEventType.statusMessage, {
        'message': 'pullOver',
        'label': 'Pull over',
        'senderDisplayName': 'Oliver',
        'position': {'latitude': 123.0, 'longitude': 0.0},
      }, first);

      final record = read([leaderRole('oliver'), odd]).single;

      expect(record.text, 'Pull over');
      expect(record.position, isNull);
    });

    test('reads as a headline, a clock time and a pasteable line', () {
      final record = read(journal).first;

      expect(record.headline, 'Oliver: Pull over');
      expect(record.clockLabel, '13:40:02');
      expect(record.timestampLabel, '2026-10-04 13:40:02');
      expect(record.summaryLine, startsWith('2026-10-04 13:40:02 ('));
      expect(record.summaryLine, endsWith('Oliver: Pull over'));
      expect(rideBroadcastLogText(read(journal)).split('\n'), hasLength(2));
    });
  });

  group('the dashboard journal row', () {
    test('names the leader on a broadcast, so it reads as a sentence', () {
      expect(statusMessageRowTitle(journal[1]), 'Oliver: Pull over');
      expect(statusMessageRowTitle(journal[2]), 'Oliver: Regroup at next stop');
    });

    test('says "Leader" when the event carries no name', () {
      final nameless = signed('b', 'oliver', RideEventType.statusMessage, {
        'message': 'pullOver',
        'label': 'Pull over',
      }, first);

      expect(statusMessageRowTitle(nameless), 'Leader: Pull over');
    });

    test('leaves every other status message as its own label', () {
      final fuel = sent(
        'fuel',
        QuickMessage.fuel,
        first,
        device: 'nigel',
        name: 'Nigel',
      );
      final empty = signed(
        'e',
        'nigel',
        RideEventType.statusMessage,
        {},
        first,
      );

      expect(statusMessageRowTitle(fuel), 'Need fuel');
      expect(statusMessageRowTitle(empty), 'Status message');
    });

    test('a kind only a newer build knows keeps its own words', () {
      final future = signed('f', 'oliver', RideEventType.statusMessage, {
        'message': 'slowDown',
        'label': 'Slow down',
        'senderDisplayName': 'Oliver',
      }, first);

      expect(statusMessageRowTitle(future), 'Slow down');
    });
  });

  group('saved with the ride', () {
    CompletedRide archived() => const CompletedRideArchiver().create(
      session: session,
      events: journal,
      archivedAt: DateTime.utc(2026, 10, 4, 15),
    );

    test('the archive keeps what the leader said', () {
      expect(archived().broadcasts.map((record) => record.text), [
        'Pull over',
        'Regroup at next stop',
      ]);
    });

    test('and it survives the library\'s JSON and its copies', () {
      final ride = archived();

      expect(CompletedRide.fromJson(ride.toJson()).broadcasts, ride.broadcasts);
      expect(ride.copyWith(libraryName: 'Renamed').broadcasts, ride.broadcasts);
      expect(ride.copyWith(rating: 4).broadcasts, ride.broadcasts);
    });

    test('a ride from before this has none, and writes nothing extra', () {
      final json = archived().copyWith(broadcasts: const []).toJson();

      expect(json.containsKey('broadcasts'), isFalse);
      expect(CompletedRide.fromJson(json).broadcasts, isEmpty);
    });

    test('one unreadable record costs that record, not the ride', () {
      final json = archived().toJson();
      json['broadcasts'] = [
        'not an object',
        {'id': 'x', 'sentAt': 'yesterday', 'sentBy': 'Y', 'text': 'Z'},
        {
          'id': '',
          'sentAt': '2026-10-04T13:00:00Z',
          'sentBy': 'Y',
          'text': 'Z',
        },
        ...(json['broadcasts']! as List),
      ];

      final restored = CompletedRide.fromJson(json);

      expect(restored.broadcasts, archived().broadcasts);
      expect(restored.title, 'Ride ABC123');
    });

    test('the shared summary text and CSV list them', () {
      const exporter = RideSummaryExporter();
      final summary = exporter.summarize(
        session,
        journal,
        generatedAt: DateTime.utc(2026, 10, 4, 15),
      );

      final text = exporter.toPlainText(summary);
      expect(text, contains('Leader messages: 2'));
      expect(text, contains('Oliver: Pull over'));
      final csv = exporter.toCsv(summary);
      expect(
        csv,
        contains('"message_time_local","message_time_utc","sent_by","message"'),
      );
      expect(csv, contains('"Oliver","Regroup at next stop"'));
    });

    test('and so does the previous ride\'s summary', () {
      final text = rideBroadcastLogText(archived().broadcasts);

      expect(text, contains('Oliver: Pull over'));
      expect(const SystemCompletedRideSharer(), isA<CompletedRideSharer>());
    });

    test('a quiet ride says nothing about them', () {
      const exporter = RideSummaryExporter();
      final summary = exporter.summarize(session, [
        leaderRole('oliver'),
      ], generatedAt: DateTime.utc(2026, 10, 4, 15));

      expect(exporter.toPlainText(summary), isNot(contains('Leader messages')));
      expect(exporter.toCsv(summary), isNot(contains('message_time')));
    });
  });

  group('the card', () {
    Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

    List<String> captureClipboard(WidgetTester tester) {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      return copied;
    }

    testWidgets('lists each message with its time, who and what', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(RideBroadcastsCard(broadcasts: read(journal))),
      );

      expect(find.text('2 leader messages'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('ride-broadcast-time-b1')))
            .data,
        '13:40:02',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('ride-broadcast-text-b1')))
            .data,
        'Oliver: Pull over',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('ride-broadcast-text-b2')))
            .data,
        'Oliver: Regroup at next stop',
      );
    });

    testWidgets('says "(you)" for the leader\'s own phone', (tester) async {
      await tester.pumpWidget(
        host(RideBroadcastsCard(broadcasts: read(journal, me: 'oliver'))),
      );

      expect(
        tester
            .widget<Text>(find.byKey(const Key('ride-broadcast-text-b1')))
            .data,
        'Oliver (you): Pull over',
      );
    });

    testWidgets('a tap copies the time in the form footage shows', (
      tester,
    ) async {
      final copied = captureClipboard(tester);
      await tester.pumpWidget(
        host(RideBroadcastsCard(broadcasts: read(journal))),
      );

      await tester.tap(find.byKey(const Key('ride-broadcast-row-b2')));
      await tester.pump();

      expect(copied, ['2026-10-04 14:05:31']);
      await tester.tap(find.byKey(const Key('ride-broadcast-copy-b1')));
      await tester.pump();
      expect(copied.last, '2026-10-04 13:40:02');
    });

    testWidgets('"Copy all" copies a line each', (tester) async {
      final copied = captureClipboard(tester);
      await tester.pumpWidget(
        host(RideBroadcastsCard(broadcasts: read(journal))),
      );

      await tester.tap(find.byKey(const Key('ride-broadcasts-copy-all')));
      await tester.pump();

      expect(copied.single.split('\n'), hasLength(2));
      expect(find.text('Copied all 2 messages'), findsOneWidget);
    });

    testWidgets('shows nothing when the leader sent none', (tester) async {
      await tester.pumpWidget(host(const RideBroadcastsCard(broadcasts: [])));

      expect(find.byKey(const Key('ride-broadcasts-card')), findsNothing);
    });

    testWidgets('a previous ride lists them, and one with none does not', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> open(CompletedRide ride) async {
        final store = InMemoryCompletedRideStore();
        await store.save(ride);
        final completed = await CompletedRidesController.load(store);
        await tester.pumpWidget(
          MaterialApp(
            home: PreviousRideDetailScreen(
              ride: ride,
              completedRides: completed,
              distanceUnits: DistanceUnitController.forLocale(
                const Locale('en', 'GB'),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      final ride = const CompletedRideArchiver().create(
        session: session,
        events: journal,
        archivedAt: DateTime.utc(2026, 10, 4, 15),
      );
      await open(ride);
      expect(find.byKey(const Key('ride-broadcasts-card')), findsOneWidget);
      expect(find.text('2 leader messages'), findsOneWidget);

      // A fresh screen, not the same one re-pumped: it reads its ride once.
      await tester.pumpWidget(const SizedBox());
      await open(ride.copyWith(broadcasts: const []));
      expect(find.byKey(const Key('ride-broadcasts-card')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
