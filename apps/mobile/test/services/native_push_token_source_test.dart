import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_push_notification_controller.dart';
import 'package:ride_relay/internet/push_registration_client.dart';
import 'package:ride_relay/services/native_push_token_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('me.osholt.ride_relay/push');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('iOS is configured for direct APNs without Firebase SDK options', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    const configuration = NativePushConfiguration(
      enabled: true,
      apiKey: '',
      projectId: '',
      messagingSenderId: '',
      iosAppId: '1:123:ios:abc',
      androidAppId: '',
    );

    expect(configuration.isConfigured, isTrue);
  });

  test('reads native status, rotation, initial open, and live open', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'consumeInitialNotification') {
        return <String, Object?>{
          'rideId': 'ride-1',
          'eventId': 'cold-event',
          'category': 'safety',
        };
      }
      return <String, Object?>{
        'permission': 'granted',
        'platform': 'android',
        'provider': 'fcm',
        'token': 'initial-token-123456789',
      };
    });
    const configuration = NativePushConfiguration(
      enabled: true,
      apiKey: 'api-key',
      projectId: 'project-id',
      messagingSenderId: '123456789',
      iosAppId: '',
      androidAppId: '1:123456789:android:abc',
    );
    final source = NativePushTokenSource(configuration, channel: channel);
    final opened = <PushOpenRequest>[];
    final openedSubscription = source.openedNotifications.listen(opened.add);

    final status = await source.requestPermissionAndToken();

    expect(status.permission, PushPermissionState.granted);
    expect(status.token?.provider, PushProvider.fcm);
    expect(status.token?.value, 'initial-token-123456789');
    expect(opened.single.eventId, 'cold-event');
    expect(calls.map((call) => call.method), [
      'consumeInitialNotification',
      'configureAndRequest',
    ]);

    final rotated = source.tokenRotations.first;
    await _sendNativeCall(
      messenger,
      channel,
      const MethodCall('tokenRotated', <String, Object?>{
        'permission': 'granted',
        'platform': 'android',
        'provider': 'fcm',
        'token': 'rotated-token-123456789',
      }),
    );
    expect((await rotated).value, 'rotated-token-123456789');

    await _sendNativeCall(
      messenger,
      channel,
      const MethodCall('notificationOpened', <String, Object?>{
        'rideId': 'ride-1',
        'eventId': 'warm-event',
        'category': 'administrative',
      }),
    );
    expect(opened.last.eventId, 'warm-event');

    await openedSubscription.cancel();
    await source.close();
  });

  test(
    'a push for a leader broadcast or an alert opens like any other',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      const configuration = NativePushConfiguration(
        enabled: true,
        apiKey: 'api-key',
        projectId: 'project-id',
        messagingSenderId: '123456789',
        iosAppId: '',
        androidAppId: '1:123456789:android:abc',
      );
      final source = NativePushTokenSource(configuration, channel: channel);
      final opened = <PushOpenRequest>[];
      final subscription = source.openedNotifications.listen(opened.add);
      await source.requestPermissionAndToken();

      // The three keys builds 101 and 102 read, plus one a later relay might add:
      // an extra key is ignored rather than refusing the open.
      for (final category in [
        PushCategory.leaderBroadcast,
        PushCategory.groupAlert,
      ]) {
        await _sendNativeCall(
          messenger,
          channel,
          MethodCall('notificationOpened', <String, Object?>{
            'rideId': 'ride-1',
            'eventId': 'event-$category',
            'category': category,
            'somethingNew': 'ignored',
          }),
        );
      }

      expect(opened.map((request) => request.category), [
        'leaderBroadcast',
        'groupAlert',
      ]);
      expect(opened.every((request) => request.isGroupInstruction), isTrue);
      expect(opened.map((request) => request.rideId).toSet(), {'ride-1'});

      await subscription.cancel();
      await source.close();
    },
  );
}

Future<void> _sendNativeCall(
  TestDefaultBinaryMessenger messenger,
  MethodChannel channel,
  MethodCall call,
) async {
  await messenger.handlePlatformMessage(
    channel.name,
    const StandardMethodCodec().encodeMethodCall(call),
    (_) {},
  );
  await Future<void>.delayed(Duration.zero);
}
