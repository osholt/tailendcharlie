# Tail End Charlie mobile app

The shared Flutter client and native iOS/Android shells. Run all commands in
this directory unless using the repository `Makefile`.

Create or join a ride, then use the bottom navigation for the Ride, Map, and
Awareness surfaces. The Map overflow menu can load the included demo GPX route
or import a GPX 1.1 file.

Google Nearby Connections is wired on both native platforms, but capability is
deliberately reported as `hardwareValidationRequired` until the physical
cross-platform/background field-test gate passes. See
`../../docs/nearby-relay.md` and `../../docs/maps-and-gpx.md` for configuration
and evidence boundaries.
