import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/natural_voice_pack.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'install enables the verified pack and persists the chosen voice',
    () async {
      final store = _FakePackStore();
      final controller = await NaturalVoicePackController.load(store: store);

      expect(controller.installed, isFalse);
      await controller.install();
      expect(controller.installed, isTrue);
      expect(controller.enabled, isTrue);
      expect(controller.downloadProgress, 1);

      await controller.setVoice(NaturalNavigationVoice.isabella);
      final reloaded = await NaturalVoicePackController.load(store: store);
      expect(reloaded.enabled, isTrue);
      expect(reloaded.voice, NaturalNavigationVoice.isabella);
    },
  );

  test('removing a pack returns safely to the phone voice', () async {
    final store = _FakePackStore(installed: true);
    SharedPreferences.setMockInitialValues({
      NaturalVoicePackController.enabledPreferenceKey: true,
    });
    final controller = await NaturalVoicePackController.load(store: store);

    await controller.remove();

    expect(controller.installed, isFalse);
    expect(controller.enabled, isFalse);
    expect(store.removeCalls, 1);
  });

  test('a failed download is named and never enables the pack', () async {
    final controller = NaturalVoicePackController.inMemory(
      store: _FakePackStore(failure: const FormatException('Bad pack hash.')),
    );

    await controller.install();

    expect(controller.status, NaturalVoicePackStatus.failed);
    expect(controller.enabled, isFalse);
    expect(controller.failure, 'Bad pack hash.');
  });
}

class _FakePackStore implements NaturalVoicePackStore {
  _FakePackStore({this.installed = false, this.failure});

  bool installed;
  final Object? failure;
  int removeCalls = 0;

  @override
  String get modelDirectory => '/fake/kokoro';

  @override
  Future<void> cancelInstall() async {}

  @override
  Future<void> install({required ValueChanged<double?> onProgress}) async {
    onProgress(0.5);
    if (failure case final failure?) throw failure;
    installed = true;
    onProgress(1);
  }

  @override
  Future<bool> isInstalled() async => installed;

  @override
  Future<void> remove() async {
    removeCalls += 1;
    installed = false;
  }
}
