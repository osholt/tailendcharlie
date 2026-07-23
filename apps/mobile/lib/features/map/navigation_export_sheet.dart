import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/navigation_export.dart';

class NavigationExportSheet extends StatelessWidget {
  const NavigationExportSheet({super.key});

  static Future<NavigationTarget?> show(BuildContext context) =>
      showModalBottomSheet<NavigationTarget>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => const NavigationExportSheet(),
      );

  static NavigationPlatform get _currentPlatform =>
      switch (defaultTargetPlatform) {
        TargetPlatform.android => NavigationPlatform.android,
        _ => NavigationPlatform.iOS,
      };

  @override
  Widget build(BuildContext context) {
    // Filtered through the capability registry - not just for today's list
    // (every entry currently supports both platforms), but so a future
    // platform-exclusive integration is actually excluded here rather than
    // requiring someone to remember to update this sheet separately.
    final capabilities = navigationCapabilitiesFor(_currentPlatform).toList();
    final directLinks = capabilities
        .where(
          (capability) =>
              capability.transport == NavigationHandoffTransport.directLink,
        )
        .toList();
    final gpxShares = capabilities
        .where(
          (capability) =>
              capability.transport == NavigationHandoffTransport.gpxShare,
        )
        .toList();
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          children: [
            Text(
              'Navigate or export',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 5),
            const Text(
              'Direct links cannot transfer an exact GPX route. Use GPX sharing '
              'for motorcycle navigation apps and connected bike devices.',
              style: TextStyle(color: Color(0xFF98A3B1)),
            ),
            const SizedBox(height: 18),
            for (final capability in directLinks)
              _TargetTile(target: capability.target),
            if (directLinks.isNotEmpty && gpxShares.isNotEmpty)
              const Divider(height: 24),
            for (final capability in gpxShares)
              _TargetTile(target: capability.target),
          ],
        ),
      ),
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({required this.target});

  final NavigationTarget target;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
    leading: CircleAvatar(
      backgroundColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.12),
      child: Icon(_icon(target)),
    ),
    title: Text(target.label),
    subtitle: Text(target.limitation),
    trailing: Icon(
      target.hasDocumentedDirectLink
          ? Icons.open_in_new
          : Icons.ios_share_outlined,
      size: 20,
    ),
    onTap: () => Navigator.pop(context, target),
  );

  static IconData _icon(NavigationTarget target) => switch (target) {
    NavigationTarget.shareGpx => Icons.file_upload_outlined,
    NavigationTarget.googleMaps => Icons.map_outlined,
    NavigationTarget.waze => Icons.navigation_outlined,
    NavigationTarget.calimoto => Icons.route_outlined,
    NavigationTarget.myRouteApp => Icons.alt_route,
    NavigationTarget.garmin => Icons.gps_fixed,
    NavigationTarget.bmwMotorrad => Icons.two_wheeler,
    NavigationTarget.harleyDavidson => Icons.two_wheeler,
  };
}
