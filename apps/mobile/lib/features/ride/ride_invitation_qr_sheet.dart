import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../domain/ride_join_payload.dart';
import '../../domain/ride_session.dart';

/// Shows the ride's invitation as a QR code, generated on this phone.
///
/// The point is not saving typing. Every other join path resolves through the
/// relay, so a group with no signal cannot form a ride at all; a QR carries the
/// credentials themselves, so scanning one needs no network (#279). Generation is
/// local for the same reason - a code that needed fetching would be useless
/// exactly when it is wanted.
///
/// ## Deliberately a sheet, not a screen
///
/// Anyone who photographs this can join the ride, because the payload carries the
/// invite secret in the clear. That is the same exposure as a shared invite link
/// and fine for a private group, but it should be held up for a moment and put
/// away - not left open on a phone on a café table. A dismissible sheet expresses
/// that; a tab would not.
class RideInvitationQrSheet extends StatelessWidget {
  const RideInvitationQrSheet({super.key, required this.session});

  final RideSession session;

  static Future<void> show(BuildContext context, RideSession session) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (_) => RideInvitationQrSheet(session: session),
      );

  @override
  Widget build(BuildContext context) {
    final payload = RideJoinPayload(
      rideId: session.rideId,
      rideCode: session.rideCode,
      inviteSecret: session.inviteSecret,
      joinToken: session.joinToken,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Scan to join',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'This works with no signal. Everything needed to join is in the '
            'code itself, so nobody has to be online to scan it.',
            style: TextStyle(color: Color(0xFFABB5C1), height: 1.45),
          ),
          const SizedBox(height: 20),
          Center(
            // On white, always. A dark-themed QR code is a QR code many scanners
            // will not read, and this one is wanted in a car park in daylight.
            child: Container(
              key: const Key('ride-invitation-qr'),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: payload.encode(),
                version: QrVersions.auto,
                size: 240,
                backgroundColor: Colors.white,
                // High correction: this gets scanned in daylight, at arm's
                // length, off a screen that may be dimmed or smeared.
                errorCorrectionLevel: QrErrorCorrectLevel.H,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Ride ${session.rideCode}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2136),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFFA76B)),
            ),
            child: const Text(
              'Anyone who photographs this code can join the ride. Show it to '
              'the riders you meant to, then close this.',
              style: TextStyle(color: Color(0xFFE3CBB6), height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
