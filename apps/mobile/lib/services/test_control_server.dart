import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../controllers/ride_controller.dart';
import '../controllers/situational_awareness_controller.dart';
import '../controllers/test_control_controller.dart';
import '../domain/hazard.dart';
import '../domain/geo_point.dart';
import '../domain/rider_location.dart';
import '../domain/ride_join_payload.dart';
import '../domain/ride_role.dart';
import 'test_control_configuration.dart';
import 'test_control_registry.dart';
import 'test_control_snapshot.dart';

/// A loopback-and-LAN HTTP surface that drives the app for field tests.
///
/// ## Why this exists
///
/// Several steps in `docs/field-test-plan.md` need two devices doing specific
/// things at specific moments, and the measurement *is* the timing - step 8b asks
/// for the observed delay between a hazard leaving one idle phone and appearing
/// on another. A person tapping two phones cannot produce that number reliably,
/// and cannot produce it at all while also watching what both screens say.
///
/// ## Why it binds to the network rather than loopback
///
/// The driver runs on a development Mac, not on the phone. Loopback would need a
/// USB port forward, and one of the two test phones is paired over the network
/// with no cable, so USB-only would make it undrivable. Reachability is therefore
/// a requirement, and the compensating controls are the three gates in
/// [TestControlConfiguration] plus the idle timeout in [TestControlController].
///
/// ## What it will not do
///
/// [testControlForbiddenActions] is enforced in [_handle] before routing. SOS,
/// emergency-contact disclosure, phone-number sharing and outbound
/// calls/messages are not reachable through this surface at any privilege level.
/// An automation port that can fire a real emergency action on a motorcycle
/// safety app is not a convenience worth having.
class TestControlServer {
  TestControlServer(
    this._control,
    this._ride,
    this._registry, {
    this.configuration = const TestControlConfiguration(),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final TestControlController _control;
  final RideController _ride;
  final TestControlRegistry _registry;
  final TestControlConfiguration configuration;
  final DateTime Function() _now;

  /// The awareness controller for the ride that is active right now, or a
  /// conflict if there is none - which is the honest answer, since hazards and
  /// positions only exist inside a ride.
  SituationalAwarenessController get _awareness =>
      _registry.awareness ??
      (throw StateError(
        'No ride is active, so there is no situational-awareness controller to '
        'drive. Create or join a ride first.',
      ));

  HttpServer? _server;

  bool get isListening => _server != null;
  int? get port => _server?.port;

  /// Starts listening, or returns without doing anything when the surface is not
  /// compiled in or not switched on. Safe to call repeatedly - the app calls it
  /// whenever the toggle changes.
  Future<void> start() async {
    if (!TestControlConfiguration.enabled) return;
    if (!_control.isOn) return;
    if (_server != null) return;
    // Dual-stack, and the IPv6 half is the point rather than an afterthought.
    // Xcode's CoreDevice tunnel to a paired phone is IPv6-only, so an
    // IPv4-only bind can only be reached across the Wi-Fi network - which means
    // exposing the port to every device on it. Binding anyIPv6 with
    // v6Only: false accepts the tunnel *and* IPv4-mapped LAN connections, so a
    // cabled or paired phone can be driven at its tunnel address with nothing
    // listening on the shared network at all.
    final server = await HttpServer.bind(
      InternetAddress.anyIPv6,
      configuration.port,
      shared: true,
      v6Only: false,
    );
    _server = server;
    server.listen(
      _handle,
      onError: (Object error) {
        if (kDebugMode) debugPrint('Test control request failed: $error');
      },
      cancelOnError: false,
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    // Not a browser surface. Deny cross-origin reads outright rather than
    // reasoning about which origins a phone on a shared network might see.
    response.headers.set('Access-Control-Allow-Origin', 'null');
    response.headers.set('Cache-Control', 'no-store');

    final path = request.uri.path;

    try {
      // Belt and braces: even a mis-typed future route cannot expose one of the
      // excluded actions.
      final segments = request.uri.pathSegments.map((s) => s.toLowerCase());
      if (segments.any(testControlForbiddenActions.contains)) {
        await _send(response, HttpStatus.forbidden, {
          'error': 'forbidden_action',
          'detail':
              'This action is permanently excluded from the test-control '
              'surface. See testControlForbiddenActions.',
        });
        return;
      }

      // Liveness only, deliberately unauthenticated and stateless: it says a
      // driven build is listening, and nothing about the ride.
      if (path == '/v1/health') {
        await _send(response, HttpStatus.ok, {
          'status': 'ok',
          'enabledAtBuild': TestControlConfiguration.enabled,
          'switchedOn': _control.isOn,
        });
        return;
      }

      if (!_control.authorize(_bearerToken(request))) {
        await _send(response, HttpStatus.unauthorized, {
          'error': 'unauthorized',
          'detail':
              'Missing or stale bearer token. Turn the test-control setting on '
              'in the app and use the token it shows.',
        });
        return;
      }

      await _route(request, response, path);
    } on FormatException catch (error) {
      await _send(response, HttpStatus.badRequest, {
        'error': 'invalid_request',
        'detail': error.message,
      });
    } on StateError catch (error) {
      await _send(response, HttpStatus.conflict, {
        'error': 'invalid_state',
        'detail': error.message,
      });
    } on Object catch (error) {
      await _send(response, HttpStatus.internalServerError, {
        'error': 'failed',
        'detail': error.toString(),
      });
    }
  }

  Future<void> _route(
    HttpRequest request,
    HttpResponse response,
    String path,
  ) async {
    final method = request.method;

    if (method == 'GET' && path == '/v1/state') {
      await _send(
        response,
        HttpStatus.ok,
        TestControlSnapshot.capture(
          ride: _ride,
          awareness: _registry.awareness,
          now: _now(),
        ).toJson(),
      );
      return;
    }

    // Capability material, so it is an explicit read rather than part of
    // /v1/state - a snapshot should be safe to paste into a results log, and a
    // join token is not.
    if (method == 'GET' && path == '/v1/ride/invite') {
      final session = _ride.session;
      if (session == null) {
        throw StateError('No ride is active.');
      }
      await _send(response, HttpStatus.ok, {
        'rideCode': session.rideCode,
        'joinToken': session.joinToken,
        // The same string a QR code carries (#279). Exposed here rather than in
        // /v1/state because it is capability material - anyone holding it can join
        // - and this endpoint is already the explicit read for that.
        'invitation': RideJoinPayload(
          rideId: session.rideId,
          rideCode: session.rideCode,
          inviteSecret: session.inviteSecret,
          joinToken: session.joinToken,
        ).encode(),
      });
      return;
    }

    if (method != 'POST') {
      await _send(response, HttpStatus.notFound, {
        'error': 'unknown_route',
        'detail': '$method $path is not a test-control route.',
      });
      return;
    }

    final body = await _readJson(request);

    // RideController does not throw. `_run` catches everything into
    // `errorMessage` and, when another action is already in flight, returns
    // without doing anything at all - see ride_controller.dart. So `await`
    // completing proves nothing about whether the action happened.
    //
    // This bit exists because of a real false success. Driving a live ride where
    // the local rider was Tail End Charlie, `POST /v1/ride/end` and then
    // `POST /v1/ride` both answered 200, and the second answered with the *old*
    // ride: `endRide` had thrown "Only the ride leader can end the ride", `_run`
    // had swallowed it, and the create then no-opped. An automated field test
    // would have recorded a clean create-join-start against a ride that never
    // changed. Clearing the error first and reporting it afterwards is what makes
    // that visible.
    // The other half of the same problem: `_run` drops the operation entirely
    // when one is already in flight, leaving no error behind. A driver firing
    // requests back to back would get 200s for actions that never ran, so refuse
    // rather than accept one we cannot promise to perform.
    if (_ride.busy) {
      throw StateError(
        'Another ride action is still in flight. Retry in a moment - this '
        'request was not performed.',
      );
    }
    _ride.clearError();

    switch (path) {
      case '/v1/ride':
        await _ride.createRide(_requireString(body, 'displayName'));
      // Joins from a scanned invitation, which is the only path that touches no
      // network (#279). Driving it is how the offline claim gets proven against a
      // relay that is genuinely unreachable rather than merely slow.
      case '/v1/ride/join-invitation':
        await _ride.joinRideFromInvitation(
          RideJoinPayload.decode(_requireString(body, 'invitation')),
          _requireString(body, 'displayName'),
        );
      case '/v1/ride/join':
        await _ride.joinRide(
          _requireString(body, 'rideCode'),
          _requireString(body, 'displayName'),
          joinToken: body['joinToken'] as String?,
        );
      case '/v1/ride/start':
        await _ride.startRide();
      case '/v1/ride/leave':
        await _ride.leaveRide();
      case '/v1/ride/end':
        await _ride.endRide();
      case '/v1/role':
        await _ride.setRole(_requireEnum(body, 'role', RideRole.values));
      case '/v1/hazard':
        await _awareness.reportHazard(
          type: _requireEnum(body, 'type', HazardType.values),
          severity:
              _optionalEnum(body, 'severity', HazardSeverity.values) ??
              HazardSeverity.caution,
          position: _optionalPosition(body),
          details: body['details'] as String?,
        );
      // Injecting a fix lets step 20 - ride 1 km off route and back - be driven
      // on a bench. It is not a substitute for real GPS: a mock fix arrives with
      // whatever accuracy is asked for, so it cannot exercise the multipath and
      // accuracy-rejection behaviour that #270 is about.
      case '/v1/location':
        await _awareness.recordLocalLocation(
          LocationSample(
            position: _requirePosition(body),
            recordedAt: _now(),
            accuracyMeters: (body['accuracyMeters'] as num?)?.toDouble() ?? 5,
            speedMetersPerSecond: (body['speedMetersPerSecond'] as num?)
                ?.toDouble(),
            headingDegrees: (body['headingDegrees'] as num?)?.toDouble(),
          ),
        );
      default:
        await _send(response, HttpStatus.notFound, {
          'error': 'unknown_route',
          'detail': 'POST $path is not a test-control route.',
        });
        return;
    }

    // A swallowed failure is reported as a failure. `errorIsRetryable` is false
    // for the rider's own bad input (a FormatException, which is also how the
    // controller expresses "you are not the leader"), so that maps to 400; a
    // retryable one is a conflict with current state.
    if (_ride.errorMessage case final message?) {
      await _send(
        response,
        _ride.errorIsRetryable ? HttpStatus.conflict : HttpStatus.badRequest,
        {
          'error': 'action_failed',
          'detail': message,
          'retryable': _ride.errorIsRetryable,
          // The snapshot still goes back: knowing what the state actually is
          // matters more than the error string when a driver has to decide
          // whether to abandon the run.
          'state': TestControlSnapshot.capture(
            ride: _ride,
            awareness: _registry.awareness,
            now: _now(),
          ).toJson(),
        },
      );
      return;
    }

    // Every mutation answers with the post-action snapshot, so a driver gets the
    // state it needs to assert on without a second round trip - which matters
    // when the thing being measured is a delay.
    await _send(
      response,
      HttpStatus.ok,
      TestControlSnapshot.capture(
        ride: _ride,
        awareness: _registry.awareness,
        now: _now(),
      ).toJson(),
    );
  }

  static String? _bearerToken(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null) return null;
    const prefix = 'Bearer ';
    if (!header.startsWith(prefix)) return null;
    final token = header.substring(prefix.length).trim();
    return token.isEmpty ? null : token;
  }

  static Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    if (raw.trim().isEmpty) return const {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Body must be a JSON object.');
    }
    return decoded;
  }

  static String _requireString(Map<String, Object?> body, String key) {
    final value = body[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException(
        '"$key" is required and must be a non-empty string.',
      );
    }
    return value.trim();
  }

  static T _requireEnum<T extends Enum>(
    Map<String, Object?> body,
    String key,
    List<T> values,
  ) =>
      _optionalEnum(body, key, values) ??
      (throw FormatException(
        '"$key" is required and must be one of: '
        '${values.map((value) => value.name).join(', ')}.',
      ));

  static T? _optionalEnum<T extends Enum>(
    Map<String, Object?> body,
    String key,
    List<T> values,
  ) {
    final raw = body[key];
    if (raw == null) return null;
    if (raw is! String) {
      throw FormatException('"$key" must be a string.');
    }
    for (final value in values) {
      if (value.name == raw) return value;
    }
    throw FormatException(
      '"$key" must be one of: ${values.map((value) => value.name).join(', ')}.',
    );
  }

  static GeoPoint _requirePosition(Map<String, Object?> body) =>
      _optionalPosition(body) ??
      (throw const FormatException('"latitude" and "longitude" are required.'));

  static GeoPoint? _optionalPosition(Map<String, Object?> body) {
    final latitude = body['latitude'];
    final longitude = body['longitude'];
    if (latitude == null && longitude == null) return null;
    if (latitude is! num || longitude is! num) {
      throw const FormatException(
        '"latitude" and "longitude" must both be numbers.',
      );
    }
    if (latitude < -90 || latitude > 90) {
      throw const FormatException('"latitude" must be between -90 and 90.');
    }
    if (longitude < -180 || longitude > 180) {
      throw const FormatException('"longitude" must be between -180 and 180.');
    }
    return GeoPoint(
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
    );
  }

  static Future<void> _send(
    HttpResponse response,
    int status,
    Map<String, Object?> body,
  ) async {
    response.statusCode = status;
    response.write(jsonEncode(body));
    await response.close();
  }
}
