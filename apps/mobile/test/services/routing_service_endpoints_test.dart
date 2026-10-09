import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/imported_track_matcher.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_attribute_provider.dart';
import 'package:ride_relay/services/routing_service_endpoints.dart';
import 'package:ride_relay/services/speed_limit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where routing, map matching, speed limits and geocoding go (#917): a build
/// override, else what the relay advertised, else the public services.
void main() {
  final self = AdvertisedRoutingServices.parse({
    'valhalla': 'https://routing.example.test/valhalla',
    'photon': 'https://routing.example.test/photon',
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RoutingServices.resetForTest();
  });
  tearDown(RoutingServices.resetForTest);

  group('resolution', () {
    test('with nothing configured, every service is the public one', () {
      final endpoints = RoutingServiceEndpoints.resolve();

      expect(
        endpoints.valhallaRouteUrl.toString(),
        'https://valhalla1.openstreetmap.de/route',
      );
      expect(
        endpoints.valhallaTraceRouteUrl.toString(),
        'https://valhalla1.openstreetmap.de/trace_route',
      );
      expect(
        endpoints.valhallaTraceAttributesUrl.toString(),
        'https://valhalla1.openstreetmap.de/trace_attributes',
      );
      expect(
        endpoints.valhallaLocateUrl.toString(),
        'https://valhalla1.openstreetmap.de/locate',
      );
      expect(
        endpoints.osrmBaseUrl.toString(),
        'https://router.project-osrm.org',
      );
      expect(
        endpoints.geocoderBaseUrl.toString(),
        'https://nominatim.openstreetmap.org',
      );
      expect(endpoints.geocoderApi, GeocoderApi.nominatim);
    });

    test('advertised services replace the public ones, each on its own', () {
      final endpoints = RoutingServiceEndpoints.resolve(advertised: self);

      expect(
        endpoints.valhallaRouteUrl.toString(),
        'https://routing.example.test/valhalla/route',
      );
      expect(
        endpoints.valhallaLocateUrl.toString(),
        'https://routing.example.test/valhalla/locate',
      );
      expect(
        endpoints.geocoderBaseUrl.toString(),
        'https://routing.example.test/photon',
      );
      expect(endpoints.geocoderApi, GeocoderApi.photon);
      // Not advertised, so still the public OSRM.
      expect(
        endpoints.osrmBaseUrl,
        RoutingServiceEndpoints.publicFallback.osrmBaseUrl,
      );
    });

    test('Photon is preferred to Nominatim when both are advertised', () {
      final both = AdvertisedRoutingServices.parse({
        'nominatim': 'https://geo.example.test/nominatim',
        'photon': 'https://geo.example.test/photon',
      });
      final nominatimOnly = AdvertisedRoutingServices.parse({
        'nominatim': 'https://geo.example.test/nominatim',
      });

      expect(
        RoutingServiceEndpoints.resolve(advertised: both).geocoderApi,
        GeocoderApi.photon,
      );
      final endpoints = RoutingServiceEndpoints.resolve(
        advertised: nominatimOnly,
      );
      expect(endpoints.geocoderApi, GeocoderApi.nominatim);
      expect(
        endpoints.geocoderBaseUrl.toString(),
        'https://geo.example.test/nominatim',
      );
    });

    test('a build override beats the relay, service by service', () {
      final endpoints = RoutingServiceEndpoints.resolve(
        overrides: RoutingServiceOverrides.parse(
          valhalla: 'https://dev.example.test/v/',
          geocoder: 'https://dev.example.test/n',
        ),
        advertised: self,
      );

      expect(
        endpoints.valhallaTraceAttributesUrl.toString(),
        'https://dev.example.test/v/trace_attributes',
      );
      expect(
        endpoints.geocoderBaseUrl.toString(),
        'https://dev.example.test/n',
      );
      expect(endpoints.geocoderApi, GeocoderApi.nominatim);
    });

    test('an override can name Photon, and an invalid one is ignored', () {
      final photon = RoutingServiceOverrides.parse(
        geocoder: 'https://dev.example.test/photon',
        geocoderApi: 'Photon',
      );
      expect(photon.geocoderApi, GeocoderApi.photon);

      final invalid = RoutingServiceOverrides.parse(
        valhalla: 'http://dev.example.test',
      );
      expect(invalid.valhalla, isNull);
      expect(
        RoutingServiceEndpoints.resolve(
          overrides: invalid,
          advertised: self,
        ).valhallaBaseUrl.toString(),
        'https://routing.example.test/valhalla',
      );
    });
  });

  group('what a relay may advertise', () {
    test('only plain HTTPS bases, each judged alone', () {
      final advertised = AdvertisedRoutingServices.parse({
        'valhalla': 'https://routing.example.test/valhalla/',
        'osrm': 'http://routing.example.test/osrm',
        'photon': 'https://user:secret@routing.example.test/photon',
        'nominatim': 'https://routing.example.test/n?key=1',
        'unknown': 'https://routing.example.test/other',
      });

      expect(
        advertised.valhalla.toString(),
        'https://routing.example.test/valhalla',
      );
      expect(advertised.osrm, isNull);
      expect(advertised.photon, isNull);
      expect(advertised.nominatim, isNull);
      expect(safeServiceBaseUrl('https://routing.example.test/x#frag'), isNull);
      expect(safeServiceBaseUrl('https:///nohost'), isNull);
      expect(safeServiceBaseUrl('not a url'), isNull);
    });

    test('anything but an object advertises nothing', () {
      expect(AdvertisedRoutingServices.parse(null).isEmpty, isTrue);
      expect(AdvertisedRoutingServices.parse('https://x.test').isEmpty, isTrue);
      expect(AdvertisedRoutingServices.parse({'valhalla': 7}).isEmpty, isTrue);
    });
  });

  group('the process-wide choice', () {
    test(
      'adopting an answer changes what every planner is built with',
      () async {
        await RoutingServices.adopt(self);

        final configuration = RoutingConfiguration.fromEnvironment();
        expect(
          configuration.motorcycleRoutingUrl.toString(),
          'https://routing.example.test/valhalla/route',
        );
        expect(
          configuration.trackMatchingUrl.toString(),
          'https://routing.example.test/valhalla/trace_route',
        );
        expect(
          configuration.routeAttributesUrl.toString(),
          'https://routing.example.test/valhalla/trace_attributes',
        );
        expect(configuration.geocoderApi, GeocoderApi.photon);

        final speedLimits = ValhallaSpeedLimitConfiguration.fromEnvironment();
        expect(
          speedLimits.lookupUri.toString(),
          'https://routing.example.test/valhalla/trace_attributes',
        );
        expect(
          speedLimits.candidateUri.toString(),
          'https://routing.example.test/valhalla/locate',
        );
      },
    );

    test('it survives a restart, and an empty answer rolls it back', () async {
      await RoutingServices.adopt(self);
      RoutingServices.resetForTest();
      expect(RoutingServices.current, RoutingServiceEndpoints.publicFallback);

      await RoutingServices.restore();
      expect(RoutingServices.advertised, self);

      await RoutingServices.adopt(AdvertisedRoutingServices.none);
      expect(RoutingServices.current, RoutingServiceEndpoints.publicFallback);
      RoutingServices.resetForTest();
      await RoutingServices.restore();
      expect(RoutingServices.current, RoutingServiceEndpoints.publicFallback);
    });

    test('an unreadable stored answer leaves the fallback in force', () async {
      SharedPreferences.setMockInitialValues({
        'routing.advertisedServiceUrls.v1': '{not json',
      });

      await RoutingServices.restore();

      expect(RoutingServices.current, RoutingServiceEndpoints.publicFallback);
    });

    test('the relay compatibility check is where the answer arrives', () async {
      Map<String, Object?> document(Map<String, Object?>? serviceUrls) => {
        'serverBuildCommit': 'unknown',
        'serverProtocol': 1,
        'minimumClientProtocol': 1,
        'maximumClientProtocol': 1,
        'capabilities': <String>[],
        'requiredCapabilities': <String>[],
        'cacheSeconds': 300,
        'updateUrls': {'default': 'https://tailendcharlie.app'},
        'serviceUrls': ?serviceUrls,
      };
      var answer = document(self.toJson());
      var now = DateTime.utc(2026, 10, 9);
      final relay = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example.test/api'),
        ),
        client: MockClient(
          (request) async => http.Response(jsonEncode(answer), 200),
        ),
        clock: () => now,
      );

      await relay.checkCompatibility();
      expect(
        RoutingServices.current.valhallaRouteUrl.toString(),
        'https://routing.example.test/valhalla/route',
      );

      // An older relay sends no serviceUrls at all: the app goes back to the
      // public services rather than keeping a choice nobody is vouching for.
      answer = document(null);
      now = now.add(const Duration(minutes: 10));
      await relay.checkCompatibility();
      expect(RoutingServices.current, RoutingServiceEndpoints.publicFallback);
      relay.close();
    });

    test('the launch refresh adopts the answer and survives failure', () async {
      final configuration = InternetRelayConfiguration(
        baseUri: Uri.parse('https://relay.example.test/api'),
      );
      await refreshAdvertisedRoutingServices(
        configuration: configuration,
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'serverBuildCommit': 'unknown',
              'serverProtocol': 1,
              'minimumClientProtocol': 1,
              'maximumClientProtocol': 1,
              'capabilities': <String>[],
              'requiredCapabilities': <String>[],
              'cacheSeconds': 300,
              'updateUrls': <String, String>{},
              'serviceUrls': self.toJson(),
            }),
            200,
          ),
        ),
      );
      expect(RoutingServices.advertised, self);

      await refreshAdvertisedRoutingServices(
        configuration: configuration,
        client: MockClient((request) async => http.Response('down', 503)),
      );
      expect(RoutingServices.advertised, self);

      // No relay compiled in: nothing to ask.
      await refreshAdvertisedRoutingServices(
        configuration: const InternetRelayConfiguration(baseUri: null),
        client: MockClient((request) async => fail('no request expected')),
      );
    });
  });

  group('Photon destination search', () {
    test('asks /api once, labels results and caches them', () async {
      final requests = <http.Request>[];
      final service = PhotonDestinationSearchService(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'type': 'FeatureCollection',
              'features': [
                {
                  'type': 'Feature',
                  'geometry': {
                    'type': 'Point',
                    'coordinates': [-2.5879, 51.4545],
                  },
                  'properties': {
                    'name': 'Bristol',
                    'county': 'City of Bristol',
                    'state': 'England',
                    'country': 'United Kingdom',
                    'countrycode': 'GB',
                  },
                },
                {
                  'type': 'Feature',
                  'geometry': {
                    'type': 'Point',
                    'coordinates': [-2.6, 51.45],
                  },
                  'properties': {
                    'street': 'Park Street',
                    'housenumber': '12',
                    'city': 'Bristol',
                    'postcode': 'BS1 5HX',
                    'country': 'United Kingdom',
                  },
                },
                {
                  'type': 'Feature',
                  'geometry': {'type': 'Point', 'coordinates': 'bad'},
                  'properties': {'name': 'Unusable'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        baseUrl: Uri.parse('https://routing.example.test/photon/'),
      );

      final first = await service.search('  Bristol ');
      final again = await service.search('bristol');

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.url.path, '/photon/api');
      expect(request.url.queryParameters, {'q': 'Bristol', 'limit': '5'});
      expect(request.headers['X-Client-Id'], routingClientId);
      expect(request.headers['User-Agent'], contains('TailEndCharlie'));
      expect(first, hasLength(2));
      expect(again, same(first));
      expect(first.first.label, 'Bristol, City of Bristol, United Kingdom');
      expect(first.first.point.latitude, 51.4545);
      expect(first.first.point.longitude, -2.5879);
      expect(
        first.last.label,
        '12 Park Street, Bristol, BS1 5HX, United Kingdom',
      );
    });

    test('coordinates need no request, and an empty answer says so', () async {
      final service = PhotonDestinationSearchService(
        client: MockClient(
          (request) async => http.Response(jsonEncode({'features': []}), 200),
        ),
        baseUrl: Uri.parse('https://routing.example.test/photon'),
      );

      final coordinates = await service.search('51.45, -2.58');
      expect(coordinates.single.point.latitude, 51.45);
      await expectLater(
        service.search('Nowhere at all'),
        throwsA(isA<FormatException>()),
      );
    });

    test('refuses a geocoder that is not HTTPS', () async {
      final service = PhotonDestinationSearchService(
        client: MockClient((request) async => fail('no request expected')),
        baseUrl: Uri.parse('http://routing.example.test/photon'),
      );

      await expectLater(
        service.search('Bristol'),
        throwsA(isA<FormatException>()),
      );
    });

    test('the resolved geocoder decides which client is built', () {
      final client = MockClient((request) async => http.Response('[]', 200));
      RoutingConfiguration configuration(GeocoderApi api) =>
          RoutingConfiguration.fromEndpoints(
            RoutingServiceEndpoints.resolve(
              overrides: RoutingServiceOverrides(
                geocoder: Uri.parse('https://geo.example.test'),
                geocoderApi: api,
              ),
            ),
          );

      expect(
        buildDestinationSearchService(
          client: client,
          configuration: configuration(GeocoderApi.photon),
        ),
        isA<PhotonDestinationSearchService>(),
      );
      expect(
        buildDestinationSearchService(
          client: client,
          configuration: configuration(GeocoderApi.nominatim),
        ),
        isA<NominatimDestinationSearchService>(),
      );
    });
  });

  test('every Valhalla client identifies the app', () async {
    final headers = <String, Map<String, String>>{};
    final client = MockClient((request) async {
      headers[request.url.path] = request.headers;
      return http.Response('{}', 500);
    });
    const points = [
      GeoPoint(latitude: 51.45, longitude: -2.58),
      GeoPoint(latitude: 51.46, longitude: -2.59),
    ];
    final endpoints = RoutingServiceEndpoints.resolve(advertised: self);

    await expectLater(
      ValhallaMotorcycleRoutingService(
        client: client,
        routeUrl: endpoints.valhallaRouteUrl,
      ).routeThrough(points),
      throwsA(anything),
    );
    await expectLater(
      ValhallaRouteAttributeProvider(
        client: client,
        endpoint: endpoints.valhallaTraceAttributesUrl,
      ).trace(points),
      throwsA(anything),
    );
    await expectLater(
      ValhallaImportedTrackMatcher(
        client: client,
        traceUrl: endpoints.valhallaTraceRouteUrl,
      ).match(
        ImportedRoute(
          id: 'track',
          name: 'Track',
          importedAt: DateTime.utc(2026, 10, 9),
          sourceFileName: 'track.gpx',
          paths: const [RoutePath(kind: RoutePathKind.track, points: points)],
          waypoints: const [],
        ),
      ),
      throwsA(anything),
    );

    expect(headers.keys, {
      '/valhalla/route',
      '/valhalla/trace_attributes',
      '/valhalla/trace_route',
    });
    for (final sent in headers.values) {
      expect(sent['x-client-id'] ?? sent['X-Client-Id'], routingClientId);
    }
  });

  test('Nominatim and OSRM requests identify the app as well', () async {
    final headers = <Map<String, String>>[];
    final client = MockClient((request) async {
      headers.add(request.headers);
      if (request.url.path.endsWith('/search')) {
        return http.Response(
          jsonEncode([
            {'lat': '51.45', 'lon': '-2.58', 'display_name': 'Bristol'},
          ]),
          200,
        );
      }
      return http.Response(jsonEncode({'code': 'NoRoute'}), 200);
    });

    await NominatimDestinationSearchService(
      client: client,
      baseUrl: Uri.parse('https://geo.example.test'),
    ).search('Bristol');
    await expectLater(
      OsrmRoadRoutingService(
        client: client,
        baseUrl: Uri.parse('https://osrm.example.test'),
      ).routeThrough(const [
        GeoPoint(latitude: 51.45, longitude: -2.58),
        GeoPoint(latitude: 51.46, longitude: -2.59),
      ]),
      throwsA(anything),
    );

    expect(headers, hasLength(2));
    for (final sent in headers) {
      expect(sent['X-Client-Id'], routingClientId);
      expect(sent['User-Agent'], contains('TailEndCharlie'));
    }
  });
}
