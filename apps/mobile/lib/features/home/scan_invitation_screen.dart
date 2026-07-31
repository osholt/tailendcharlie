import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../domain/ride_join_payload.dart';

/// Scans a ride invitation and hands back the payload.
///
/// Returns a [RideJoinPayload] on success and null if the rider backs out, so the
/// caller owns the joining. This screen decides one thing only: whether what the
/// camera saw is a valid invitation.
///
/// ## Refusal has to be survivable
///
/// Camera permission is asked for here and nowhere else, and a refusal must leave
/// the rider exactly where they were with every other way in still working - the
/// six-digit code and the pasted invite both still exist. A scanner is the only
/// path that works with no signal, but it must never become the only path at all.
class ScanInvitationScreen extends StatefulWidget {
  const ScanInvitationScreen({super.key, this.controller});

  /// Injected in tests. Production builds the real camera controller.
  final MobileScannerController? controller;

  static Future<RideJoinPayload?> show(BuildContext context) =>
      Navigator.of(context).push<RideJoinPayload>(
        MaterialPageRoute(builder: (_) => const ScanInvitationScreen()),
      );

  @override
  State<ScanInvitationScreen> createState() => _ScanInvitationScreenState();
}

class _ScanInvitationScreenState extends State<ScanInvitationScreen> {
  late final MobileScannerController _controller =
      widget.controller ??
      MobileScannerController(
        // Only QR. Letting it read every barcode on a fuel receipt would produce
        // confident nonsense.
        formats: const [BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.noDuplicates,
      );

  String? _problem;

  /// Set the moment a valid invitation is found, so a camera that keeps firing
  /// cannot pop this route twice.
  bool _handled = false;

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      try {
        final payload = RideJoinPayload.decode(raw);
        _handled = true;
        Navigator.of(context).pop(payload);
        return;
      } on FormatException catch (error) {
        // Say what was wrong rather than going quiet. A rider pointing a phone at
        // the wrong thing needs to know it was the wrong thing, not wonder whether
        // the camera is working.
        if (mounted) setState(() => _problem = error.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan an invitation')),
    body: Stack(
      children: [
        MobileScanner(
          key: const Key('invitation-scanner'),
          controller: _controller,
          onDetect: _onDetect,
          errorBuilder: (context, error) => _CameraUnavailable(error: error),
        ),
        Positioned(
          left: 18,
          right: 18,
          bottom: 28,
          child: Column(
            children: [
              if (_problem case final problem?)
                Container(
                  key: const Key('invitation-scan-problem'),
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4A1520),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFF7F98)),
                  ),
                  child: Text(
                    problem,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFFFFF1E4)),
                  ),
                ),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Point the camera at the code on the ride leader’s phone. '
                  'This works with no signal.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Shown when the camera cannot be used, including a refused permission.
///
/// Names the other ways in rather than leaving the rider at a dead end: refusing a
/// camera must not cost them the ride.
class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      key: const Key('invitation-scanner-unavailable'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.no_photography_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              denied
                  ? 'Camera access is off for Tail End Charlie'
                  : 'The camera is not available',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            const Text(
              'You can still join with the six-digit ride code, or by pasting '
              'the invitation the leader shared. Scanning is the only way that '
              'works with no signal at all.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFFABB5C1), height: 1.45),
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              key: const Key('invitation-scanner-back'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Use a ride code instead'),
            ),
          ],
        ),
      ),
    );
  }
}
