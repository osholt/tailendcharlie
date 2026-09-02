import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'spoken_audio_mode.dart';

typedef SpokenGuidanceFocusLost = Future<void> Function();

/// One short-lived audio-focus lease for an imminent spoken prompt.
abstract interface class SpokenGuidanceAudioFocus {
  bool get managesPlatformFocus;

  Future<bool> acquire({
    required SpokenAudioClass audioClass,
    required SpokenGuidanceFocusLost onLost,
  });

  Future<void> abandon();
}

/// Android's focus request is kept outside either renderer so neural audio and
/// system TTS obey the same ownership rules. Other platforms keep their existing
/// AVAudioSession/plugin behaviour.
class PlatformSpokenGuidanceAudioFocus implements SpokenGuidanceAudioFocus {
  PlatformSpokenGuidanceAudioFocus({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName) {
    if (managesPlatformFocus) {
      _channel.setMethodCallHandler(_dispatchMethodCall);
    }
  }

  static const _channelName = 'me.osholt.ride_relay/spoken_audio_focus';
  static final Map<int, SpokenGuidanceFocusLost> _owners = {};

  final MethodChannel _channel;
  int? _requestId;

  @override
  bool get managesPlatformFocus =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> acquire({
    required SpokenAudioClass audioClass,
    required SpokenGuidanceFocusLost onLost,
  }) async {
    if (!managesPlatformFocus) return true;
    await abandon();
    final reply = await _channel.invokeMapMethod<String, Object?>('acquire', {
      'audioClass': audioClass.name,
    });
    final granted = reply?['granted'] == true;
    final requestId = reply?['requestId'];
    if (!granted || requestId is! int) return false;
    _requestId = requestId;
    _owners[requestId] = onLost;
    return true;
  }

  @override
  Future<void> abandon() async {
    final requestId = _requestId;
    _requestId = null;
    if (!managesPlatformFocus || requestId == null) return;
    _owners.remove(requestId);
    await _channel.invokeMethod<void>('abandon', {'requestId': requestId});
  }

  static Future<void> _dispatchMethodCall(MethodCall call) async {
    if (call.method != 'focusLost') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final requestId = arguments['requestId'];
    if (requestId is! int) return;
    final onLost = _owners.remove(requestId);
    if (onLost != null) await onLost();
  }
}
