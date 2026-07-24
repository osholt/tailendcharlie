import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../controllers/observer_access_controller.dart';
import '../../internet/observer_access_client.dart';

class ObserverAccessSheet extends StatefulWidget {
  const ObserverAccessSheet({super.key, required this.controller});

  final ObserverAccessController controller;

  static Future<void> show(
    BuildContext context,
    ObserverAccessController controller,
  ) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => ObserverAccessSheet(controller: controller),
  );

  @override
  State<ObserverAccessSheet> createState() => _ObserverAccessSheetState();
}

class _ObserverAccessSheetState extends State<ObserverAccessSheet> {
  final _labelController = TextEditingController(text: 'Safety contact');
  Duration _duration = const Duration(hours: 4);
  bool _consent = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.refresh());
  }

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Share my progress',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Creates a private, read-only web link for one trusted contact. '
              'It shares your last-known position, update freshness, ride '
              'status and your help or emergency-stop status.',
            ),
            const SizedBox(height: 8),
            const Text(
              'It does not share the ride code, other riders, your location '
              'trail, route, nearby identities or emergency contact details. '
              'A missing update is not proof that you are safe.',
              style: TextStyle(color: Color(0xFFA9B4C2)),
            ),
            const SizedBox(height: 18),
            TextField(
              key: const Key('observer-label'),
              controller: _labelController,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Who is this link for?',
                hintText: 'Home contact',
              ),
            ),
            DropdownButtonFormField<Duration>(
              key: const Key('observer-duration'),
              initialValue: _duration,
              decoration: const InputDecoration(labelText: 'Access duration'),
              items: const [
                DropdownMenuItem(
                  value: Duration(hours: 1),
                  child: Text('1 hour'),
                ),
                DropdownMenuItem(
                  value: Duration(hours: 4),
                  child: Text('4 hours'),
                ),
                DropdownMenuItem(
                  value: Duration(hours: 12),
                  child: Text('12 hours'),
                ),
                DropdownMenuItem(
                  value: Duration(hours: 24),
                  child: Text('24 hours'),
                ),
              ],
              onChanged: widget.controller.busy
                  ? null
                  : (value) => setState(() => _duration = value ?? _duration),
            ),
            CheckboxListTile(
              key: const Key('observer-consent'),
              value: _consent,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'I choose to share this information for the selected time.',
              ),
              onChanged: widget.controller.busy
                  ? null
                  : (value) => setState(() => _consent = value ?? false),
            ),
            FilledButton.icon(
              key: const Key('create-observer-link'),
              onPressed: !_consent || widget.controller.busy
                  ? null
                  : () => widget.controller.create(
                      label: _labelController.text,
                      duration: _duration,
                    ),
              icon: widget.controller.busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: const Text('Create private link'),
            ),
            if (widget.controller.errorMessage case final error?) ...[
              const SizedBox(height: 10),
              Text(error, style: const TextStyle(color: Color(0xFFFF9AAB))),
            ],
            if (widget.controller.latestInvite case final invite?) ...[
              const SizedBox(height: 14),
              Card(
                color: const Color(0xFF20352D),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Link ready',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Share it only with the intended contact. The secret '
                        'part is shown only now and cannot be recovered later.',
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        key: const Key('share-observer-link'),
                        onPressed: () => _share(context, invite.shareUri),
                        icon: const Icon(Icons.share),
                        label: const Text('Share safety link'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 22),
            Text(
              'YOUR LINKS',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: const Color(0xFF8D98A7),
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 8),
            if (!widget.controller.busy && widget.controller.grants.isEmpty)
              const Text('No safety links have been created for this ride.'),
            for (final grant in widget.controller.grants)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  grant.isActiveAt(DateTime.now())
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                title: Text(grant.label),
                subtitle: Text(_grantStatus(grant)),
                trailing: grant.isActiveAt(DateTime.now())
                    ? TextButton(
                        onPressed: widget.controller.busy
                            ? null
                            : () => widget.controller.revoke(grant.id),
                        child: const Text('Revoke'),
                      )
                    : null,
              ),
          ],
        ),
      ),
    ),
  );

  Future<void> _share(BuildContext context, Uri uri) async {
    final renderObject = context.findRenderObject();
    final origin = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
    await SharePlus.instance.share(
      ShareParams(
        text:
            'Follow my last-known ride progress using this private, '
            'time-limited Tail End Charlie link:\n$uri',
        sharePositionOrigin: origin,
      ),
    );
  }

  String _grantStatus(ObserverGrant grant) {
    if (grant.revokedAt != null) return 'Revoked';
    if (!grant.expiresAt.isAfter(DateTime.now())) return 'Expired';
    return 'Expires ${MaterialLocalizations.of(context).formatFullDate(grant.expiresAt)} '
        '${TimeOfDay.fromDateTime(grant.expiresAt).format(context)}';
  }
}
