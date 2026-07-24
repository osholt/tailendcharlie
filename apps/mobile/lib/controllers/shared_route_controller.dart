import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../internet/plan_directory.dart';
import '../services/gpx_import_source.dart';
import '../services/planner_link_channel.dart';
import '../services/shared_gpx_channel.dart';

enum PlannerLinkStatus { idle, loading, error }

/// Tracks a GPX file the platform has handed to the app via "Open in..." /
/// file association, until some screen claims and clears it. Re-checks on
/// every foreground resume, since the share can arrive while backgrounded.
class SharedRouteController extends ChangeNotifier with WidgetsBindingObserver {
  SharedRouteController._(
    this._channel,
    this._plannerLinkSource,
    this._planDirectory, {
    required this._ownsPlanDirectory,
  }) {
    WidgetsBinding.instance.addObserver(this);
  }

  final SharedGpxChannel _channel;
  final IncomingPlannerLinkSource _plannerLinkSource;
  final PlanDirectory _planDirectory;
  final bool _ownsPlanDirectory;
  PickedGpxFile? _pending;
  PlannerLinkStatus _plannerLinkStatus = PlannerLinkStatus.idle;
  String? _plannerLinkMessage;
  String? _plannerLinkCode;
  bool _plannerLinkRetryable = false;
  Future<void>? _refreshOperation;

  PickedGpxFile? get pending => _pending;
  PlannerLinkStatus get plannerLinkStatus => _plannerLinkStatus;
  String? get plannerLinkMessage => _plannerLinkMessage;
  String? get plannerLinkCode => _plannerLinkCode;
  bool get canRetryPlannerLink =>
      _plannerLinkStatus == PlannerLinkStatus.error && _plannerLinkRetryable;

  static Future<SharedRouteController> load({
    SharedGpxChannel channel = const SharedGpxChannel(),
    IncomingPlannerLinkSource plannerLinkSource = const PlannerLinkChannel(),
    PlanDirectory? planDirectory,
  }) async {
    final ownedDirectory = planDirectory == null
        ? HttpPlanDirectory.fromEnvironment()
        : null;
    final controller = SharedRouteController._(
      channel,
      plannerLinkSource,
      planDirectory ?? ownedDirectory!,
      ownsPlanDirectory: ownedDirectory != null,
    );
    await controller._refresh();
    return controller;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() {
    final existing = _refreshOperation;
    if (existing != null) return existing;
    final operation = _performRefresh();
    _refreshOperation = operation;
    return operation.whenComplete(() {
      if (identical(_refreshOperation, operation)) _refreshOperation = null;
    });
  }

  Future<void> _performRefresh() async {
    final file = await _channel.consumePending();
    if (file != null) {
      _pending = file;
      notifyListeners();
    }
    final rawLink = await _plannerLinkSource.consumePending();
    if (rawLink != null) await _loadPlannerLink(rawLink);
  }

  /// Stages a route obtained inside the app (for example from a web-planner
  /// code) through the same leader-only handoff as an OS "Open in…" file.
  void stagePending(PickedGpxFile file) {
    _pending = file;
    notifyListeners();
  }

  /// Call once a screen has either started importing the file or shown the
  /// rider a "start a ride first" message, so it is not offered again.
  void clearPending() {
    if (_pending == null) return;
    _pending = null;
    notifyListeners();
  }

  Future<void> _loadPlannerLink(String rawLink) async {
    final code = planCodeFromPlannerLink(rawLink);
    if (code == null) {
      _plannerLinkStatus = PlannerLinkStatus.error;
      _plannerLinkMessage =
          'That route link is invalid. Open the planner and enter its code manually.';
      _plannerLinkCode = null;
      _plannerLinkRetryable = false;
      notifyListeners();
      return;
    }
    await _fetchPlannerCode(code);
  }

  Future<void> _fetchPlannerCode(String code) async {
    _plannerLinkStatus = PlannerLinkStatus.loading;
    _plannerLinkMessage = 'Loading shared route $code…';
    _plannerLinkCode = code;
    _plannerLinkRetryable = false;
    notifyListeners();
    try {
      final plan = await _planDirectory.fetch(code);
      _pending = PickedGpxFile(
        name: _plannerFileName(plan.name),
        bytes: Uint8List.fromList(utf8.encode(plan.gpx)),
      );
      _plannerLinkStatus = PlannerLinkStatus.idle;
      _plannerLinkMessage = null;
      _plannerLinkRetryable = false;
      notifyListeners();
    } on PlanDirectoryException catch (error) {
      _plannerLinkStatus = PlannerLinkStatus.error;
      _plannerLinkMessage = error.message;
      _plannerLinkRetryable = error.retryable;
      notifyListeners();
    } on Object {
      _plannerLinkStatus = PlannerLinkStatus.error;
      _plannerLinkMessage =
          'The shared route could not be loaded. Check your connection and try again.';
      _plannerLinkRetryable = true;
      notifyListeners();
    }
  }

  Future<void> retryPlannerLink() async {
    final code = _plannerLinkCode;
    if (!canRetryPlannerLink || code == null) return;
    await _fetchPlannerCode(code);
  }

  void clearPlannerLinkNotice() {
    if (_plannerLinkStatus == PlannerLinkStatus.idle &&
        _plannerLinkMessage == null) {
      return;
    }
    _plannerLinkStatus = PlannerLinkStatus.idle;
    _plannerLinkMessage = null;
    _plannerLinkRetryable = false;
    notifyListeners();
  }

  @visibleForTesting
  Future<void> refreshForTesting() => _refresh();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsPlanDirectory && _planDirectory is HttpPlanDirectory) {
      _planDirectory.close();
    }
    super.dispose();
  }
}

String _plannerFileName(String? name) {
  final safe = (name ?? 'planned-route')
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9 _-]+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final bounded = safe.isEmpty
      ? 'planned-route'
      : safe.length > 80
      ? safe.substring(0, 80)
      : safe;
  return '$bounded.gpx';
}
