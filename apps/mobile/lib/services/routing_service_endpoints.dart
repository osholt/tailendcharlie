import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What every routing, map-matching, speed-limit and geocoding request says it
/// is. The self-hosted service refuses a request without it (#917); the public
/// services ask for it.
const routingClientId = 'tailendcharlie.app';

/// The API a geocoding service speaks. They differ in path, query and response.
enum GeocoderApi { nominatim, photon }

/// Where the routing, map-matching, speed-limit and geocoding requests go.
///
/// There is one place these are decided (#917), in this order for each service
/// separately:
///
/// 1. a build-time `--dart-define`, for development against a test service;
/// 2. what the relay advertises in `/api/v1/compatibility` `serviceUrls`, so
///    the operator can move the services without an app release;
/// 3. the public services every earlier build used.
///
/// Valhalla's actions are all derived from one base URL, so route, map
/// matching, route checks and speed limits can never end up on different hosts.
@immutable
class RoutingServiceEndpoints {
  const RoutingServiceEndpoints({
    required this.valhallaBaseUrl,
    required this.osrmBaseUrl,
    required this.geocoderBaseUrl,
    required this.geocoderApi,
  });

  /// The public demo services, used when nothing else is configured. None of
  /// them is meant for production traffic; see docs/routing-service.md.
  static final publicFallback = RoutingServiceEndpoints(
    valhallaBaseUrl: Uri.parse('https://valhalla1.openstreetmap.de'),
    osrmBaseUrl: Uri.parse('https://router.project-osrm.org'),
    geocoderBaseUrl: Uri.parse('https://nominatim.openstreetmap.org'),
    geocoderApi: GeocoderApi.nominatim,
  );

  /// Applies the precedence above. Each service is resolved on its own: a
  /// relay that advertises only Valhalla leaves geocoding on its fallback.
  factory RoutingServiceEndpoints.resolve({
    RoutingServiceOverrides overrides = const RoutingServiceOverrides(),
    AdvertisedRoutingServices advertised = AdvertisedRoutingServices.none,
  }) {
    final fallback = publicFallback;
    final Uri geocoder;
    final GeocoderApi api;
    if (overrides.geocoder != null) {
      geocoder = overrides.geocoder!;
      api = overrides.geocoderApi;
    } else if (advertised.photon != null) {
      // Photon is preferred when both are offered: it is the self-hosted one,
      // and the only one whose terms permit search as you type.
      geocoder = advertised.photon!;
      api = GeocoderApi.photon;
    } else if (advertised.nominatim != null) {
      geocoder = advertised.nominatim!;
      api = GeocoderApi.nominatim;
    } else {
      geocoder = fallback.geocoderBaseUrl;
      api = fallback.geocoderApi;
    }
    return RoutingServiceEndpoints(
      valhallaBaseUrl:
          overrides.valhalla ?? advertised.valhalla ?? fallback.valhallaBaseUrl,
      osrmBaseUrl: overrides.osrm ?? advertised.osrm ?? fallback.osrmBaseUrl,
      geocoderBaseUrl: geocoder,
      geocoderApi: api,
    );
  }

  final Uri valhallaBaseUrl;
  final Uri osrmBaseUrl;
  final Uri geocoderBaseUrl;
  final GeocoderApi geocoderApi;

  Uri get valhallaRouteUrl => _valhallaAction('route');
  Uri get valhallaTraceRouteUrl => _valhallaAction('trace_route');
  Uri get valhallaTraceAttributesUrl => _valhallaAction('trace_attributes');
  Uri get valhallaLocateUrl => _valhallaAction('locate');

  Uri _valhallaAction(String action) => valhallaBaseUrl.replace(
    pathSegments: [
      ...valhallaBaseUrl.pathSegments.where((segment) => segment.isNotEmpty),
      action,
    ],
  );

  @override
  bool operator ==(Object other) =>
      other is RoutingServiceEndpoints &&
      other.valhallaBaseUrl == valhallaBaseUrl &&
      other.osrmBaseUrl == osrmBaseUrl &&
      other.geocoderBaseUrl == geocoderBaseUrl &&
      other.geocoderApi == geocoderApi;

  @override
  int get hashCode =>
      Object.hash(valhallaBaseUrl, osrmBaseUrl, geocoderBaseUrl, geocoderApi);

  @override
  String toString() =>
      'RoutingServiceEndpoints(valhalla: $valhallaBaseUrl, osrm: $osrmBaseUrl, '
      '${geocoderApi.name}: $geocoderBaseUrl)';
}

/// Build-time overrides. Empty or invalid values are ignored rather than
/// trusted, so a typo in a define falls back instead of breaking routing.
@immutable
class RoutingServiceOverrides {
  const RoutingServiceOverrides({
    this.valhalla,
    this.osrm,
    this.geocoder,
    this.geocoderApi = GeocoderApi.nominatim,
  });

  factory RoutingServiceOverrides.fromEnvironment() =>
      RoutingServiceOverrides.parse(
        valhalla: const String.fromEnvironment('RIDE_RELAY_VALHALLA_URL'),
        osrm: const String.fromEnvironment('RIDE_RELAY_ROUTING_URL'),
        geocoder: const String.fromEnvironment('RIDE_RELAY_GEOCODING_URL'),
        geocoderApi: const String.fromEnvironment('RIDE_RELAY_GEOCODING_API'),
      );

  factory RoutingServiceOverrides.parse({
    String valhalla = '',
    String osrm = '',
    String geocoder = '',
    String geocoderApi = '',
  }) => RoutingServiceOverrides(
    valhalla: safeServiceBaseUrl(valhalla),
    osrm: safeServiceBaseUrl(osrm),
    geocoder: safeServiceBaseUrl(geocoder),
    geocoderApi: geocoderApi.trim().toLowerCase() == 'photon'
        ? GeocoderApi.photon
        : GeocoderApi.nominatim,
  );

  final Uri? valhalla;
  final Uri? osrm;
  final Uri? geocoder;
  final GeocoderApi geocoderApi;
}

/// The services a relay advertised. Each entry was checked on the way in; an
/// entry that failed is simply absent, so one bad URL cannot disable the rest.
@immutable
class AdvertisedRoutingServices {
  const AdvertisedRoutingServices({
    this.valhalla,
    this.osrm,
    this.photon,
    this.nominatim,
  });

  static const none = AdvertisedRoutingServices();

  /// Reads a compatibility document's `serviceUrls`. Anything that is not an
  /// object, including its absence from an older relay, advertises nothing.
  factory AdvertisedRoutingServices.parse(Object? raw) {
    if (raw is! Map) return none;
    Uri? entry(String key) {
      final value = raw[key];
      return value is String ? safeServiceBaseUrl(value) : null;
    }

    return AdvertisedRoutingServices(
      valhalla: entry('valhalla'),
      osrm: entry('osrm'),
      photon: entry('photon'),
      nominatim: entry('nominatim'),
    );
  }

  final Uri? valhalla;
  final Uri? osrm;
  final Uri? photon;
  final Uri? nominatim;

  bool get isEmpty =>
      valhalla == null && osrm == null && photon == null && nominatim == null;

  Map<String, String> toJson() => {
    if (valhalla != null) 'valhalla': '$valhalla',
    if (osrm != null) 'osrm': '$osrm',
    if (photon != null) 'photon': '$photon',
    if (nominatim != null) 'nominatim': '$nominatim',
  };

  @override
  bool operator ==(Object other) =>
      other is AdvertisedRoutingServices &&
      other.valhalla == valhalla &&
      other.osrm == osrm &&
      other.photon == photon &&
      other.nominatim == nominatim;

  @override
  int get hashCode => Object.hash(valhalla, osrm, photon, nominatim);
}

/// A service base URL every phone may be pointed at: HTTPS with a host, and no
/// credentials, query or fragment. A trailing slash is dropped so derived
/// paths come out the same either way. Anything else is refused.
Uri? safeServiceBaseUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
  return uri.replace(path: segments.isEmpty ? '' : '/${segments.join('/')}');
}

/// The endpoints in force for this process.
///
/// Every planner, matcher, speed-limit lookup and search reads [current] when it
/// is built, so a change takes effect for the next one. The relay's latest
/// answer is kept on the phone, so a launch without signal still uses the
/// services the operator last chose rather than the public ones.
abstract final class RoutingServices {
  static const _preferenceKey = 'routing.advertisedServiceUrls.v1';

  static RoutingServiceOverrides _overrides =
      RoutingServiceOverrides.fromEnvironment();
  static AdvertisedRoutingServices _advertised = AdvertisedRoutingServices.none;
  static RoutingServiceEndpoints _current = RoutingServiceEndpoints.resolve(
    overrides: _overrides,
  );

  static RoutingServiceEndpoints get current => _current;
  static AdvertisedRoutingServices get advertised => _advertised;

  /// Loads what the relay last advertised. A missing or unreadable value
  /// leaves the fallback in force.
  static Future<void> restore() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final stored = preferences.getString(_preferenceKey);
      if (stored == null) return;
      _apply(AdvertisedRoutingServices.parse(jsonDecode(stored)));
    } on Object {
      // A corrupt preference is not worth failing a launch over; the next
      // compatibility check replaces it.
    }
  }

  /// Adopts a relay's answer, including an empty one: a relay that stops
  /// advertising a service has sent its clients back to the fallback, which is
  /// how the operator rolls a cut-over back.
  static Future<void> adopt(AdvertisedRoutingServices advertised) async {
    if (advertised == _advertised) return;
    _apply(advertised);
    try {
      final preferences = await SharedPreferences.getInstance();
      if (advertised.isEmpty) {
        await preferences.remove(_preferenceKey);
      } else {
        await preferences.setString(
          _preferenceKey,
          jsonEncode(advertised.toJson()),
        );
      }
    } on Object {
      // Still in force for this run; it is persisted at the next check.
    }
  }

  static void _apply(AdvertisedRoutingServices advertised) {
    _advertised = advertised;
    _current = RoutingServiceEndpoints.resolve(
      overrides: _overrides,
      advertised: advertised,
    );
  }

  @visibleForTesting
  static void resetForTest({
    RoutingServiceOverrides overrides = const RoutingServiceOverrides(),
  }) {
    _overrides = overrides;
    _apply(AdvertisedRoutingServices.none);
  }
}
