import 'package:flutter/material.dart';

import '../../services/discovery_road_facts.dart';
import '../../services/motorcycle_discovery.dart';

/// What a rider sees when they select a discovery road.
///
/// A planning surface, not a riding one, so it may be richer than anything shown
/// mid-ride - but it never appears on the ride map and it scrolls rather than
/// growing (#104, #125, #133, #160). Every string comes from
/// [DiscoveryRoadFacts]; this widget only decides where each one sits and which
/// of them get emphasis.
class DiscoveryRoadSheet extends StatelessWidget {
  const DiscoveryRoadSheet({
    super.key,
    required this.feature,
    this.onAddToRoute,
    this.onSuggestCorrection,
    this.onOpenLink,
  });

  final MotorcycleDiscoveryFeature feature;

  /// Null while a route is already being calculated, which disables the action.
  final VoidCallback? onAddToRoute;
  final VoidCallback? onSuggestCorrection;
  final void Function(String url)? onOpenLink;

  static Future<void> show(
    BuildContext context, {
    required MotorcycleDiscoveryFeature feature,
    VoidCallback? onAddToRoute,
    VoidCallback? onSuggestCorrection,
    void Function(String url)? onOpenLink,
  }) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => DiscoveryRoadSheet(
      feature: feature,
      onAddToRoute: onAddToRoute,
      onSuggestCorrection: onSuggestCorrection,
      onOpenLink: onOpenLink,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final facts = DiscoveryRoadFacts.of(feature);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      feature.category.label,
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  // A pending candidate must not look like a verified one.
                  DiscoveryResearchBadge(facts: facts),
                ],
              ),
              Text(feature.name, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                [
                  if (feature.score case final score?) 'Score $score/100',
                  '${feature.confidence} confidence',
                  'checked ${feature.lastVerified}',
                ].join(' · '),
              ),
              if (facts.description case final description?) ...[
                const SizedBox(height: 10),
                Text(description, key: const Key('discovery-description')),
              ],
              const SizedBox(height: 12),
              // A mapped limit and an unknown one must not read the same, so the
              // known case gets the sign-like emphasis and the unknown one is
              // deliberately quieter and italic (#145, #160).
              DiscoveryFactRow(
                key: const Key('discovery-speed-limit'),
                icon: facts.speedLimitIsKnown
                    ? Icons.speed
                    : Icons.help_outline,
                headline: facts.speedLimit,
                headlineStyle: facts.speedLimitIsKnown
                    ? theme.textTheme.titleMedium
                    : theme.textTheme.titleMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: const Color(0xFF98A3B1),
                      ),
                detail: facts.speedLimitProvenance,
              ),
              const SizedBox(height: 10),
              DiscoveryFactRow(
                key: const Key('discovery-enforcement'),
                icon: Icons.local_police_outlined,
                headline: 'Enforcement',
                detail: facts.enforcementLines.join('\n'),
              ),
              const SizedBox(height: 10),
              DiscoveryFactRow(
                key: const Key('discovery-busy-periods'),
                icon: Icons.groups_outlined,
                headline: 'Busy periods',
                detail: facts.busyPeriods,
              ),
              const SizedBox(height: 10),
              DiscoveryFactRow(
                key: const Key('discovery-research-status'),
                icon: facts.isVerified
                    ? Icons.verified_outlined
                    : Icons.pending_outlined,
                headline: facts.researchLabel,
                detail: facts.researchDetail,
              ),
              const SizedBox(height: 10),
              DiscoveryFactRow(
                key: const Key('discovery-source-verification'),
                icon: facts.sourceIsFetched
                    ? Icons.fact_check_outlined
                    : Icons.info_outline,
                headline: facts.sourceVerificationLabel,
                detail: facts.sourceVerificationDetail,
              ),
              const SizedBox(height: 10),
              Text(feature.warning),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => onOpenLink?.call(feature.sourceUrl),
                  icon: const Icon(Icons.open_in_new),
                  label: Text('Source: ${feature.sourceName}'),
                ),
              ),
              for (final source in facts.evidenceSources)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => onOpenLink?.call(source),
                    icon: const Icon(Icons.link, size: 18),
                    label: Text(
                      Uri.tryParse(source)?.host ?? source,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              FilledButton.icon(
                key: const Key('discovery-add-to-route'),
                onPressed: onAddToRoute,
                icon: const Icon(Icons.add_road),
                label: const Text('Add to route via here'),
              ),
              TextButton.icon(
                onPressed: onSuggestCorrection,
                icon: const Icon(Icons.edit_location_alt_outlined),
                label: const Text('Suggest a correction or removal'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One fact about a discovery road, with its provenance underneath it.
class DiscoveryFactRow extends StatelessWidget {
  const DiscoveryFactRow({
    super.key,
    required this.icon,
    required this.headline,
    required this.detail,
    this.headlineStyle,
  });

  final IconData icon;
  final String headline;
  final String detail;
  final TextStyle? headlineStyle;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 2, right: 10),
        child: Icon(icon, size: 20, color: const Color(0xFF98A3B1)),
      ),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              headline,
              style: headlineStyle ?? Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              detail,
              style: const TextStyle(fontSize: 12, color: Color(0xFF98A3B1)),
            ),
          ],
        ),
      ),
    ],
  );
}

/// Whether a discovery candidate has been reviewed by a person.
///
/// Deliberately a different colour for a pending entry, not just different text:
/// presenting an unverified candidate with the same confidence as a cited one is
/// the failure #160 names.
class DiscoveryResearchBadge extends StatelessWidget {
  const DiscoveryResearchBadge({super.key, required this.facts});

  static const verifiedForeground = Color(0xFF8FE3A8);
  static const pendingForeground = Color(0xFFF2CE7C);

  final DiscoveryRoadFacts facts;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('discovery-research-badge'),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: facts.isVerified
          ? const Color(0xFF16341F)
          : const Color(0xFF3A2E14),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(
        color: facts.isVerified
            ? const Color(0xFF3FA35C)
            : const Color(0xFFCE9A2B),
      ),
    ),
    child: Text(
      facts.researchLabel.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: facts.isVerified ? verifiedForeground : pendingForeground,
      ),
    ),
  );
}
