package me.osholt.ride_relay

import io.flutter.app.FlutterApplication

/**
 * Named in the manifest so [RideRelayEngine] has a process-wide home.
 *
 * Deliberately does nothing on create. The engine is started by whoever needs
 * it first — the phone activity or the car service — because a cold start that
 * is not going to a car should not pay for one (#602).
 */
class RideRelayApplication : FlutterApplication()
