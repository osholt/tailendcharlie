import 'package:flutter_tts/flutter_tts.dart';

/// One installed English text-to-speech voice.
class SpokenGuidanceVoice {
  const SpokenGuidanceVoice({
    required this.name,
    required this.locale,
    this.identifier,
    this.quality,
    this.gender,
    this.requiresNetwork,
  });

  final String name;
  final String locale;

  /// Stable on Apple platforms. Android identifies a voice by name + locale.
  final String? identifier;

  /// Apple reports `premium`, `enhanced`, or `default`; Android reports a
  /// five-step quality scale. Keeping the platform value lets Settings put the
  /// voices most likely to sound natural ahead of novelty/compact voices.
  final String? quality;
  final String? gender;

  /// Android exposes whether synthesis needs a network connection. Null on
  /// Apple, where installed voices are supplied by the operating system.
  final bool? requiresNetwork;

  String get key =>
      identifier?.isNotEmpty == true ? identifier! : '$locale\u0000$name';

  String get label {
    final details = <String>[name, locale];
    if (qualityLabel case final quality?) details.add(quality);
    if (requiresNetwork == true) {
      details.add('Network');
    } else if (requiresNetwork == false) {
      details.add('Offline');
    }
    return details.join(' · ');
  }

  String? get qualityLabel => switch (quality?.toLowerCase()) {
    'premium' => 'Premium',
    'enhanced' => 'Enhanced',
    'very high' => 'Very high quality',
    'high' => 'High quality',
    _ => null,
  };

  bool get isBritishEnglish => locale.toLowerCase() == 'en-gb';

  bool get isDaniel => isBritishEnglish && name.toLowerCase() == 'daniel';

  bool get isHighQuality => switch (quality?.toLowerCase()) {
    'premium' || 'enhanced' || 'very high' || 'high' => true,
    _ => false,
  };

  /// The short list keeps the ordinary picker useful on Apple devices whose
  /// installed catalogue includes dozens of novelty voices. Nothing is hidden:
  /// Settings can still expand to the complete English catalogue.
  bool get isRecommended => isDaniel || isBritishEnglish || isHighQuality;

  bool hasSameNameAndLocale(SpokenGuidanceVoice other) =>
      name.toLowerCase() == other.name.toLowerCase() &&
      locale.toLowerCase() == other.locale.toLowerCase();

  Map<String, String> get platformArguments => {
    'name': name,
    'locale': locale,
    if (identifier?.isNotEmpty == true) 'identifier': identifier!,
  };

  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'name': name,
      'locale': locale,
      if (identifier?.isNotEmpty == true) 'identifier': identifier,
      if (quality?.isNotEmpty == true) 'quality': quality,
      if (gender?.isNotEmpty == true) 'gender': gender,
    };
    final network = requiresNetwork;
    if (network != null) json['requiresNetwork'] = network;
    return json;
  }

  static SpokenGuidanceVoice? fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final locale = json['locale'];
    if (name is! String || name.trim().isEmpty) return null;
    if (locale is! String || locale.trim().isEmpty) return null;
    return SpokenGuidanceVoice(
      name: name.trim(),
      locale: locale.trim(),
      identifier: switch (json['identifier']) {
        final String value when value.trim().isNotEmpty => value.trim(),
        _ => null,
      },
      quality: switch (json['quality']) {
        final String value when value.trim().isNotEmpty => value.trim(),
        _ => null,
      },
      gender: switch (json['gender']) {
        final String value when value.trim().isNotEmpty => value.trim(),
        _ => null,
      },
      requiresNetwork: switch (json['requiresNetwork'] ??
          json['network_required']) {
        final bool value => value,
        final String value when value == '1' || value.toLowerCase() == 'true' =>
          true,
        final String value
            when value == '0' || value.toLowerCase() == 'false' =>
          false,
        _ => null,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SpokenGuidanceVoice && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// Reads usable voices from the platform without making settings depend on the
/// plugin's dynamic response shape.
Future<List<SpokenGuidanceVoice>> loadSpokenGuidanceVoices([
  FlutterTts? tts,
]) async {
  try {
    final raw = await (tts ?? FlutterTts()).getVoices;
    if (raw is! List) return const [];
    final voices = <SpokenGuidanceVoice>{};
    for (final entry in raw.whereType<Map>()) {
      final voice = SpokenGuidanceVoice.fromJson(
        Map<String, Object?>.from(entry),
      );
      // The guidance phrases are English. Offering a non-English synthesiser
      // would technically be selectable but would not be a usable voice.
      if (voice != null && voice.locale.toLowerCase().startsWith('en')) {
        voices.add(voice);
      }
    }
    return voices.toList(growable: false)..sort(compareSpokenGuidanceVoices);
  } on Object {
    // Voice choice is optional. A platform/plugin failure leaves the system
    // default available rather than breaking Settings or speech.
    return const [];
  }
}

int compareSpokenGuidanceVoices(
  SpokenGuidanceVoice first,
  SpokenGuidanceVoice second,
) {
  final preference = _voicePreferenceRank(
    first,
  ).compareTo(_voicePreferenceRank(second));
  if (preference != 0) return preference;
  final quality = _voiceQualityRank(
    first.quality,
  ).compareTo(_voiceQualityRank(second.quality));
  if (quality != 0) return quality;
  final locale = first.locale.compareTo(second.locale);
  return locale != 0 ? locale : first.name.compareTo(second.name);
}

int _voicePreferenceRank(SpokenGuidanceVoice voice) {
  if (voice.isDaniel) return 0;
  if (voice.isBritishEnglish && voice.isHighQuality) return 1;
  if (voice.isBritishEnglish) return 2;
  if (voice.isHighQuality) return 3;
  return 4;
}

int _voiceQualityRank(String? quality) => switch (quality?.toLowerCase()) {
  'premium' => 0,
  'enhanced' => 1,
  'very high' => 2,
  'high' => 3,
  'normal' || 'default' => 4,
  'low' => 5,
  'very low' => 6,
  _ => 7,
};

/// Speaks turn instructions so a rider does not have to look down.
///
/// A tester asked for it directly: "does the directions also have audio prompts
/// or just visual?" (#286). On a bike this is not a convenience over the visual
/// guidance - guidance you have to *read* competes with the road, so audio is the
/// difference between guidance usable at speed and guidance usable only when
/// stopped.
///
/// The engine sits behind [SpokenGuidanceEngine] so the decisions in
/// [SpokenGuidanceSpeaker] - what to say, when, and how often - are testable
/// without a platform channel. Those decisions are the part that can be wrong in
/// a way a rider would notice.
abstract interface class SpokenGuidanceEngine {
  Future<void> configure();
  Future<void> speak(String phrase);
  Future<void> stop();
}

/// The real engine.
///
/// Two platform settings matter more than the voice does:
///
/// - **iOS must duck rather than take over.** Most riders have an intercom
///   carrying music or another navigation app. `.mixWithOthers` plus
///   `duckOthers` lowers the other source for the phrase instead of stopping it.
///   Getting this wrong makes the feature actively unwelcome, because a prompt
///   that kills the music is worse than no prompt.
/// - **Android must not request audio focus permanently**, for the same reason.
///
/// **Foreground only, deliberately.** iOS would need the `audio` background mode
/// declared for prompts to continue once the app is not frontmost, and that is not
/// added here for two reasons. It is a release and review decision rather than a
/// code one. And #205 means the app does not yet record position in the
/// background at all - so background prompts would be guidance computed from a
/// position that had stopped updating, which is worse than silence. A rider
/// running another navigation app in front will not hear these; that is a known
/// limit, not an oversight.
class FlutterTtsSpokenGuidanceEngine implements SpokenGuidanceEngine {
  FlutterTtsSpokenGuidanceEngine({FlutterTts? tts, this.voiceProvider})
    : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  final SpokenGuidanceVoice? Function()? voiceProvider;
  SpokenGuidanceVoice? _appliedVoice;

  @override
  Future<void> configure() async {
    await _tts.setSharedInstance(true);
    await _tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
      IosTextToSpeechAudioCategoryOptions.mixWithOthers,
      IosTextToSpeechAudioCategoryOptions.duckOthers,
    ], IosTextToSpeechAudioMode.voicePrompt);
    // Slightly slower than default: a phrase heard once at 50 mph through a
    // helmet has to land first time.
    await _tts.setSpeechRate(0.48);
    await _tts.awaitSpeakCompletion(true);
    await _applyVoice();
  }

  @override
  Future<void> speak(String phrase) async {
    // Settings can change during a ride. Read the selection at the next phrase
    // rather than requiring the ride shell to rebuild its speaker.
    await _applyVoice();
    // The map needs compact labels such as "55 yd", but those same labels are
    // not safe speech input: at least one installed voice read `yd` as "id"
    // (#503). Expand only complete unit tokens here, at the final boundary, so
    // road names such as Lloyd and route names such as M4 remain untouched.
    await _tts.speak(_expandSpokenAbbreviations(phrase));
  }

  @override
  Future<void> stop() => _tts.stop();

  Future<void> _applyVoice() async {
    final chosen = voiceProvider?.call();
    if (chosen == _appliedVoice) return;
    if (chosen == null) {
      await _tts.clearVoice();
      _appliedVoice = null;
      return;
    }
    final result = await _tts.setVoice(chosen.platformArguments);
    if (result is num && result != 1) {
      // The voice may have been removed since it was saved. Keep speaking with
      // the system default instead of failing the prompt.
      await _tts.clearVoice();
    }
    _appliedVoice = chosen;
  }
}

const _spokenUnits = <({String abbreviation, String singular, String plural})>[
  (
    abbreviation: 'km/h',
    singular: 'kilometres per hour',
    plural: 'kilometres per hour',
  ),
  (abbreviation: 'mph', singular: 'miles per hour', plural: 'miles per hour'),
  (abbreviation: 'yd', singular: 'yard', plural: 'yards'),
  (abbreviation: 'mi', singular: 'mile', plural: 'miles'),
  (abbreviation: 'ft', singular: 'foot', plural: 'feet'),
  (abbreviation: 'km', singular: 'kilometre', plural: 'kilometres'),
  (abbreviation: 'm', singular: 'metre', plural: 'metres'),
];

String _expandSpokenAbbreviations(String phrase) {
  var expanded = phrase;
  for (final unit in _spokenUnits) {
    final abbreviation = RegExp.escape(unit.abbreviation);
    expanded = expanded.replaceAllMapped(
      RegExp('\\b(1(?:\\.0+)?)\\s+$abbreviation\\b', caseSensitive: false),
      (match) => '${match.group(1)} ${unit.singular}',
    );
    expanded = expanded.replaceAll(
      RegExp('\\b$abbreviation\\b', caseSensitive: false),
      unit.plural,
    );
  }
  return expanded;
}

/// Decides what is worth saying, and refuses to say it twice.
///
/// Deliberately holds no opinion about how instructions are computed - #15, #103,
/// #127 and #163 own that. This speaks what the screen is already showing, and
/// nothing the screen is not: a rider who hears one thing and sees another will
/// trust neither.
class SpokenGuidanceSpeaker {
  SpokenGuidanceSpeaker(this._engine);

  final SpokenGuidanceEngine _engine;

  String? _lastSpokenKey;
  final _spokenAlertKeys = <String>{};
  bool _configured = false;

  /// The instruction most recently spoken, for tests and for the caller to check
  /// it is not about to repeat itself.
  String? get lastSpokenKey => _lastSpokenKey;

  /// Speaks [phrase] for the manoeuvre identified by [key], at most once.
  ///
  /// [key] is the manoeuvre's identity rather than its wording, so re-rendering
  /// the same turn - which happens on every position fix - does not speak it
  /// again. Repeating a prompt every few seconds would be worse than silence.
  ///
  /// Returns whether anything was spoken, so a caller can tell "already said" from
  /// "not appropriate".
  Future<bool> speakManoeuvre({
    required String key,
    required String phrase,
    required bool enabled,
    required bool rideActive,
  }) async {
    // Off means silent, with no engine work at all: a rider who has not asked for
    // audio must not have a speech engine initialised behind their back.
    if (!enabled) return false;
    // Nothing is spoken outside a running ride. An instruction read aloud after
    // the ride has ended, or while still parked at the start, is noise at best
    // and misleading at worst.
    if (!rideActive) return false;
    if (phrase.trim().isEmpty) return false;
    if (key == _lastSpokenKey) return false;

    if (!_configured) {
      await _engine.configure();
      _configured = true;
    }
    _lastSpokenKey = key;
    await _engine.speak(phrase);
    return true;
  }

  /// Speaks a warning about the road, which is a different class of thing from a
  /// turn (#430).
  ///
  /// Kept apart from [speakManoeuvre] on purpose. A turn is guidance and a camera
  /// is safety, and #415's alerts-only mode exists precisely so a rider can
  /// silence one without silencing the other. Sharing one method would have made
  /// that distinction a boolean somebody forgets to pass.
  ///
  /// [key] is the hazard's identity, so a warning armed a mile out and held all
  /// the way in is said once rather than on every fix.
  Future<bool> speakAlert({
    required String key,
    required String phrase,
    required bool enabled,
    required bool rideActive,
  }) async {
    if (!enabled) return false;
    if (!rideActive) return false;
    if (phrase.trim().isEmpty) return false;
    if (_spokenAlertKeys.contains(key)) return false;

    if (!_configured) {
      await _engine.configure();
      _configured = true;
    }
    // Alerts keep their own memory rather than sharing `_lastSpokenKey`: a turn
    // spoken between two sightings of the same camera would otherwise let the
    // camera be announced twice.
    _spokenAlertKeys.add(key);
    await _engine.speak(phrase);
    return true;
  }

  /// Forgets what was last spoken, so the next ride starts clean.
  ///
  /// Without this a new ride whose first manoeuvre happened to carry the same
  /// identity as the last ride's final one would be silent for it.
  void reset() {
    _lastSpokenKey = null;
    _spokenAlertKeys.clear();
  }

  Future<void> stop() => _engine.stop();
}
