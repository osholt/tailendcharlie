import '../domain/imported_route.dart';
import 'road_routing.dart';

/// One immutable route option returned to CarPlay before anything is persisted.
class CarPlayRouteChoicePreview {
  CarPlayRouteChoicePreview({
    required this.id,
    required this.route,
    required this.distanceMeters,
    required this.duration,
    required this.summaryVariants,
    required this.additionalInformationVariants,
    required this.selectionSummaryVariants,
  }) : assert(summaryVariants.isNotEmpty),
       assert(additionalInformationVariants.isNotEmpty),
       assert(selectionSummaryVariants.isNotEmpty);

  factory CarPlayRouteChoicePreview.fromPlan(
    DestinationRoutePlan plan, {
    String suffix = 'primary',
    String? summary,
    String? additionalInformation,
  }) {
    final routeName = plan.route.name.trim();
    final shortSummary = summary?.trim();
    final detail = additionalInformation?.trim();
    return CarPlayRouteChoicePreview(
      id: '${plan.route.id}:$suffix',
      route: plan.route,
      distanceMeters: plan.distanceMeters,
      duration: plan.duration,
      summaryVariants: [
        if (shortSummary?.isNotEmpty == true) shortSummary!,
        if (routeName.isNotEmpty && routeName != shortSummary) routeName,
        'Recommended route',
      ],
      additionalInformationVariants: [
        if (detail?.isNotEmpty == true) detail!,
        'Motorcycle route',
      ],
      selectionSummaryVariants: [
        if (shortSummary?.isNotEmpty == true) shortSummary!,
        if (routeName.isNotEmpty && routeName != shortSummary) routeName,
        'Use this route',
      ],
    );
  }

  final String id;
  final ImportedRoute route;
  final double distanceMeters;
  final Duration duration;
  final List<String> summaryVariants;
  final List<String> additionalInformationVariants;
  final List<String> selectionSummaryVariants;

  List<GeoPoint> get points => [for (final path in route.paths) ...path.points];

  Map<String, Object?> toSnapshot() => {
    'id': id,
    'routeId': route.id,
    'summaryVariants': summaryVariants.take(3).toList(growable: false),
    'additionalInformationVariants': additionalInformationVariants
        .take(3)
        .toList(growable: false),
    'selectionSummaryVariants': selectionSummaryVariants
        .take(3)
        .toList(growable: false),
    'distanceMeters': distanceMeters,
    'durationSeconds': duration.inMilliseconds / 1000,
    'routePoints': [
      for (final point in points)
        {'latitude': point.latitude, 'longitude': point.longitude},
    ],
  };
}

/// A single destination with at most three route choices for `CPTrip`.
class CarPlayTripPreview {
  CarPlayTripPreview({
    required this.id,
    required this.destinationLabel,
    required List<CarPlayRouteChoicePreview> choices,
  }) : choices = List.unmodifiable(choices.take(3)) {
    if (this.choices.isEmpty) {
      throw const FormatException(
        'No route is available for that destination.',
      );
    }
    if (this.choices.any((choice) => choice.points.length < 2)) {
      throw const FormatException('A route preview has insufficient geometry.');
    }
  }

  factory CarPlayTripPreview.single({
    required String destinationLabel,
    required DestinationRoutePlan plan,
  }) => CarPlayTripPreview(
    id: '${plan.route.id}:carplay-preview',
    destinationLabel: destinationLabel,
    choices: [CarPlayRouteChoicePreview.fromPlan(plan)],
  );

  final String id;
  final String destinationLabel;
  final List<CarPlayRouteChoicePreview> choices;

  GeoPoint get origin => choices.first.points.first;
  GeoPoint get destination => choices.first.points.last;

  Map<String, Object?> toSnapshot() => {
    'schemaVersion': 1,
    'id': id,
    'destinationLabel': destinationLabel,
    'origin': {'latitude': origin.latitude, 'longitude': origin.longitude},
    'destination': {
      'latitude': destination.latitude,
      'longitude': destination.longitude,
    },
    'choices': [for (final choice in choices) choice.toSnapshot()],
  };
}

class CarPlayRoutePreviewSelection {
  const CarPlayRoutePreviewSelection({
    required this.destinationLabel,
    required this.route,
  });

  final String destinationLabel;
  final ImportedRoute route;
}

/// Keeps preview planning side-effect free and makes confirmation exactly-once.
class CarPlayRoutePreviewTransaction {
  CarPlayTripPreview? _pending;

  CarPlayTripPreview? get pending => _pending;

  void replace(CarPlayTripPreview preview) {
    _pending = preview;
  }

  CarPlayRoutePreviewSelection commit({
    required String previewId,
    required String routeChoiceId,
  }) {
    final preview = _pending;
    if (preview == null || preview.id != previewId) {
      throw const FormatException(
        'That route preview has expired. Choose the destination again.',
      );
    }
    final choice = preview.choices
        .where((candidate) => candidate.id == routeChoiceId)
        .firstOrNull;
    if (choice == null) {
      throw const FormatException(
        'That route choice is no longer available. Choose it again.',
      );
    }
    // Consume before the caller mutates ride state. A repeated native callback
    // can then neither create a second ride nor publish a route twice.
    _pending = null;
    return CarPlayRoutePreviewSelection(
      destinationLabel: preview.destinationLabel,
      route: choice.route,
    );
  }

  void cancel(String previewId) {
    if (_pending?.id == previewId) _pending = null;
  }

  void clear() {
    _pending = null;
  }
}
