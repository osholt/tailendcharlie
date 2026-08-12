import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../controllers/ride_diagnostics_controller.dart';
import '../../data/ride_diagnostics_log_store.dart';

/// The runtime half of the ride-diagnostics gate (#419).
///
/// Renders **nothing** in an ordinary build, the way [TestControlSection] does:
/// the recorder is not in the binary there, so offering a switch for it would be
/// offering a control that cannot work.
///
/// The wording is deliberately plain about what is recorded. A rider who finds
/// this switched on should not have to infer "records where I went" from the word
/// "diagnostics" — that is the same reasoning `docs/test-control-api.md` gives for
/// why its row says another machine can drive the app rather than saying "debug".
///
/// ## Why the share lives here
///
/// The recorded log used to leave the phone only through a share started from
/// inside the live ride. A rider who finished the ride and moved on had no way to
/// hand it over at all (#456). This is the door that does not depend on being
/// anywhere in particular: whatever was recorded last can be shared from Settings,
/// which is also where the rider switched recording on and so the first place they
/// look for it.
class RideDiagnosticsSection extends StatefulWidget {
  const RideDiagnosticsSection({super.key, required this.controller});

  final RideDiagnosticsController controller;

  @override
  State<RideDiagnosticsSection> createState() => _RideDiagnosticsSectionState();
}

class _RideDiagnosticsSectionState extends State<RideDiagnosticsSection> {
  Future<List<RideDiagnosticsLog>>? _logs;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    // Assigned directly rather than through [_reloadLogs]: there is no state to
    // notify yet, and `setState` during `initState` is not allowed.
    _logs = _loadLogs();
  }

  Future<List<RideDiagnosticsLog>> _loadLogs() =>
      widget.controller.logStore?.list() ??
      Future.value(const <RideDiagnosticsLog>[]);

  void _reloadLogs() {
    // A block body, not an arrow: an assignment expression evaluates to the
    // assigned value, so `setState(() => _logs = …)` returns a Future and
    // Flutter asserts on that.
    setState(() {
      _logs = _loadLogs();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.controller.isAvailable) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            key: const Key('ride-diagnostics-toggle'),
            contentPadding: EdgeInsets.zero,
            value: widget.controller.isOn,
            onChanged: (enabled) async {
              await widget.controller.setEnabled(enabled);
              // A log appears the moment recording starts, so the list below is
              // stale as soon as the switch moves.
              if (mounted) _reloadLogs();
            },
            title: const Text('Record ride diagnostics'),
            subtitle: const Text(
              'Writes down each turn instruction, when it was spoken, every alert, '
              'and this phone’s own route, so a wrong instruction can be explained '
              'afterwards. No other rider’s position is recorded. Nothing is sent '
              'anywhere until you choose a recipient when you share it.',
            ),
          ),
          _buildRecordedLogs(context),
        ],
      ),
    );
  }

  Widget _buildRecordedLogs(BuildContext context) {
    return FutureBuilder<List<RideDiagnosticsLog>>(
      future: _logs,
      builder: (context, snapshot) {
        final logs = snapshot.data ?? const <RideDiagnosticsLog>[];
        if (logs.isEmpty) {
          // Said rather than left blank: a rider who recorded a ride and finds
          // nothing here needs to know whether the log is missing or merely
          // elsewhere.
          return Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              snapshot.connectionState == ConnectionState.waiting
                  ? 'Looking for recorded rides…'
                  : 'No recorded rides yet. Switch this on before a ride, and the '
                        'log will be here afterwards.',
              key: const Key('ride-diagnostics-no-logs'),
              style: TextStyle(
                color: Theme.of(context).hintColor,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            Text(
              'Recorded rides',
              style: TextStyle(
                color: Theme.of(context).hintColor,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            for (final log in logs)
              ListTile(
                key: Key('ride-diagnostics-log-${log.rideId}'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.description_outlined),
                title: Text(log.rideCode ?? 'Ride ${log.rideId}'),
                subtitle: Text(_when(log.writtenAt)),
                trailing: const Icon(Icons.ios_share, size: 20),
                enabled: !_sharing,
                onTap: () => _share(context, log),
              ),
          ],
        );
      },
    );
  }

  Future<void> _share(BuildContext context, RideDiagnosticsLog log) async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await SharePlus.instance.share(
        ShareParams(
          title: 'Ride diagnostics ${log.rideCode ?? log.rideId}',
          subject: 'Tail End Charlie diagnostics ${log.rideCode ?? log.rideId}',
          files: [
            XFile.fromData(
              Uint8List.fromList(utf8.encode(log.text)),
              mimeType: 'text/plain',
              name: log.fileName,
            ),
          ],
          fileNameOverrides: [log.fileName],
        ),
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share the log: $error')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  /// Local time, to the minute. A rider identifies a ride by when they rode it.
  static String _when(DateTime at) {
    final local = at.toLocal();
    final date =
        '${local.year}-${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}';
    return date;
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
