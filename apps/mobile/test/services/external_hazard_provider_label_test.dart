// No raw enum name may reach a rider (#175).
//
// The provider status badge rendered `state.name.toUpperCase()`, which put
// `NEEDSCONFIGURATION` on screen beside "Live UK traffic". A tester reported the
// whole section as faulty, which is the cost of shipping an unformatted enum.

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/external_hazard_provider.dart';

void main() {
  /// Words a rider reads: one capitalised word, then lower-case words. A
  /// camelCase identifier uppercased - `NEEDSCONFIGURATION` - cannot match this,
  /// which is the whole point. "Unavailable" happens to equal its own enum name
  /// and is a perfectly good label: the fault was never the wording, it was
  /// shipping the identifier.
  final readsAsEnglish = RegExp(r'^[A-Z][a-z]+( [a-z]+)*$');

  test('every state has a label that reads as words', () {
    for (final state in ExternalHazardProviderState.values) {
      final label = state.label;

      expect(label, isNotEmpty, reason: '${state.name} has no label');
      expect(
        label,
        matches(readsAsEnglish),
        reason: '"$label" for ${state.name} does not read as English',
      );
    }
  });

  test('the identifier form would fail this test', () {
    // Guards the guard: if the pattern ever stopped rejecting a raw enum name,
    // every case above would pass vacuously.
    for (final state in ExternalHazardProviderState.values) {
      expect(
        state.name.toUpperCase(),
        isNot(matches(readsAsEnglish)),
        reason: 'an uppercased identifier must not satisfy the label rule',
      );
    }
  });

  test('the reported case reads as words', () {
    expect(
      ExternalHazardProviderState.needsConfiguration.label,
      'Not set up',
      reason: 'this is the one a tester photographed as NEEDSCONFIGURATION',
    );
  });
}
