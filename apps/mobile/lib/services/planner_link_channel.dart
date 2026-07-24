import 'package:flutter/services.dart';

abstract interface class IncomingPlannerLinkSource {
  Future<String?> consumePending();
}

/// Pulls the latest planner Universal Link/App Link captured by the native
/// lifecycle bridge. Pull delivery handles both cold starts (the URL arrives
/// before Dart is ready) and warm resumes without an event-listener race.
class PlannerLinkChannel implements IncomingPlannerLinkSource {
  const PlannerLinkChannel();

  static const _channel = MethodChannel('me.osholt.ride_relay/planner_link');

  @override
  Future<String?> consumePending() async {
    try {
      return await _channel.invokeMethod<String>('consumePendingPlannerLink');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

String? planCodeFromPlannerLink(String value) {
  if (value.length > 2048) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.toLowerCase() != 'tailendcharlie.app' ||
      uri.path != '/planner.html' ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return null;
  }
  final values = uri.queryParametersAll['code'];
  if (values == null || values.length != 1) return null;
  final code = values.single.trim().toUpperCase();
  if (!RegExp(r'^[A-Z0-9]{4,16}$').hasMatch(code)) return null;
  return code;
}
