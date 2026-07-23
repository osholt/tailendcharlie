import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/gpx_import_source.dart';
import '../services/shared_gpx_channel.dart';

/// Tracks a GPX file the platform has handed to the app via "Open in..." /
/// file association, until some screen claims and clears it. Re-checks on
/// every foreground resume, since the share can arrive while backgrounded.
class SharedRouteController extends ChangeNotifier with WidgetsBindingObserver {
  SharedRouteController._(this._channel) {
    WidgetsBinding.instance.addObserver(this);
  }

  final SharedGpxChannel _channel;
  PickedGpxFile? _pending;

  PickedGpxFile? get pending => _pending;

  static Future<SharedRouteController> load({
    SharedGpxChannel channel = const SharedGpxChannel(),
  }) async {
    final controller = SharedRouteController._(channel);
    await controller._refresh();
    return controller;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final file = await _channel.consumePending();
    if (file == null) return;
    _pending = file;
    notifyListeners();
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
