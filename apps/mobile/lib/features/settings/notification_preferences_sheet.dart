import 'package:flutter/material.dart';

import '../../controllers/ride_push_notification_controller.dart';

class NotificationPreferencesSheet extends StatefulWidget {
  const NotificationPreferencesSheet({super.key, required this.controller});

  final RidePushNotificationController controller;

  static Future<void> show(
    BuildContext context,
    RidePushNotificationController controller,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => NotificationPreferencesSheet(controller: controller),
  );

  @override
  State<NotificationPreferencesSheet> createState() =>
      _NotificationPreferencesSheetState();
}

class _NotificationPreferencesSheetState
    extends State<NotificationPreferencesSheet> {
  late bool _safety = widget.controller.preferences.safety;
  late bool _status = widget.controller.preferences.status;
  late bool _administrative = widget.controller.preferences.administrative;
  bool _saving = false;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Ride notifications',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            widget.controller.statusMessage ??
                'Choose which background ride updates this phone receives.',
            style: const TextStyle(color: Color(0xFFABB5C1), height: 1.4),
          ),
          const SizedBox(height: 18),
          _StatusCard(controller: widget.controller),
          const SizedBox(height: 12),
          SwitchListTile(
            key: const Key('push-safety-preference'),
            contentPadding: EdgeInsets.zero,
            value: _safety,
            onChanged: (value) => setState(() => _safety = value),
            title: const Text('Safety and assistance updates'),
            subtitle: const Text(
              'Stopped, mechanical, fuel and route-attention updates, instructions from your leader such as pull over, and one-tap rider alerts. Critical SOS alerts remain enabled when system permission allows.',
            ),
          ),
          SwitchListTile(
            key: const Key('push-status-preference'),
            contentPadding: EdgeInsets.zero,
            value: _status,
            onChanged: (value) => setState(() => _status = value),
            title: const Text('Ride and marker status'),
            subtitle: const Text('Resolved, all-passed and marker changes.'),
          ),
          SwitchListTile(
            key: const Key('push-administrative-preference'),
            contentPadding: EdgeInsets.zero,
            value: _administrative,
            onChanged: (value) => setState(() => _administrative = value),
            title: const Text('Administrative changes'),
            subtitle: const Text('Ride paused, resumed or ended.'),
          ),
          const SizedBox(height: 14),
          FilledButton(
            key: const Key('save-push-preferences'),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save notification preferences'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('refresh-push-registration'),
            onPressed: widget.controller.busy || !widget.controller.available
                ? null
                : widget.controller.refreshRegistration,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry registration'),
          ),
          const SizedBox(height: 14),
          const Text(
            'Push delivery is best-effort and may be delayed or suppressed by the operating system. It does not replace emergency services, the durable in-app alert, or an agreed group safety plan. Lock-screen messages intentionally omit coordinates, invitation secrets and medical details.',
            style: TextStyle(color: Color(0xFF98A3B1), height: 1.4),
          ),
        ],
      ),
    ),
  );

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.controller.updatePreferences(
      safety: _safety,
      status: _status,
      administrative: _administrative,
    );
    if (mounted) Navigator.of(context).pop();
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});

  final RidePushNotificationController controller;

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (controller.permission) {
      PushPermissionState.granted => (
        Icons.notifications_active_outlined,
        'System permission granted',
        const Color(0xFF72D6A0),
      ),
      PushPermissionState.denied => (
        Icons.notifications_off_outlined,
        'Blocked in system settings',
        const Color(0xFFFFC857),
      ),
      PushPermissionState.unavailable => (
        Icons.cloud_off_outlined,
        'Not configured in this build',
        const Color(0xFFFFC857),
      ),
      PushPermissionState.unknown => (
        Icons.notifications_none,
        'Permission not requested',
        const Color(0xFFABB5C1),
      ),
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF171D25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF303B48)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}
