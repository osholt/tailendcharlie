import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../controllers/ride_controller.dart';

/// The code a new group ride is joined with, shown the moment it exists.
///
/// That is when a leader most needs it, with riders waiting nearby, rather
/// than after a trip through the Ride page to find it.
class RideInviteStep extends StatelessWidget {
  const RideInviteStep({
    super.key,
    required this.controller,
    required this.onContinue,
  });

  final RideController controller;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final session = controller.session;
    final code = session?.rideCode ?? '';
    return Padding(
      key: const Key('ride-invite-step'),
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF6ED89A), size: 40),
          const SizedBox(height: 16),
          Text(
            session?.rideName ?? 'Ride created',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Share this code so the group can join.',
            style: TextStyle(color: Color(0xFFABB5C1)),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              color: const Color(0xFF111720),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF2A3441)),
            ),
            child: Center(
              child: Text(
                code,
                key: const Key('ride-invite-code'),
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 34,
                  letterSpacing: 6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: code)),
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => SharePlus.instance.share(
                    ShareParams(
                      text: controller.rideCodeShareText,
                      subject: 'Join my Tail End Charlie group',
                    ),
                  ),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          TextButton(
            key: const Key('ride-invite-continue'),
            onPressed: onContinue,
            child: const Text('Continue to ride'),
          ),
        ],
      ),
    );
  }
}
