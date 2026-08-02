import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../controllers/observer_access_controller.dart';
import '../../internet/observer_access_client.dart';

class ObserverAccessSheet extends StatefulWidget {
  const ObserverAccessSheet({
    super.key,
    required this.controller,
    this.canShareGroup = false,
  });

  final ObserverAccessController controller;
  final bool canShareGroup;

  static Future<void> show(
    BuildContext context,
    ObserverAccessController controller, {
    bool canShareGroup = false,
  }) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    // Without this an `isScrollControlled` sheet can reach full height and take
    // the drag handle behind the status bar and Dynamic Island, where it cannot
    // be grabbed. The body is a `SingleChildScrollView`, which consumes vertical
    // drags, so the handle is the only dismissing gesture there is - and a rider
    // reported being unable to leave this screen at all (#304).
    useSafeArea: true,
    builder: (_) => ObserverAccessSheet(
      controller: controller,
      canShareGroup: canShareGroup,
    ),
  );

  @override
  State<ObserverAccessSheet> createState() => _ObserverAccessSheetState();
}

class _ObserverAccessSheetState extends State<ObserverAccessSheet> {
  final _labelController = TextEditingController(text: 'Safety contact');
  Duration _duration = const Duration(hours: 4);
  ObserverAccessScope _scope = ObserverAccessScope.rider;
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
            // An explicit way out, not only a gesture. This sheet is used at a
            // kerbside, often with gloves on, and a drag handle is a small
            // target; a rider who could not leave it was left stuck in the app
            // while trying to set off (#304).
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Watcher link',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  key: const Key('close-observer-access-sheet'),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Creates a private, read-only web link for one trusted contact. '
              'It shares your last-known position, update freshness, ride '
              'status and your help or emergency-stop status. The watcher '
              'does not join the ride or appear in the rider list.',
            ),
            const SizedBox(height: 8),
            Text(
              _scope == ObserverAccessScope.group
                  ? 'It never shares the ride code, location trails, nearby '
                        'identifiers, phone numbers, emergency-contact details '
                        'or participant controls. A missing update is not proof '
                        'that a rider is safe.'
                  : 'It does not share the ride code, other riders, your '
                        'location trail, route, nearby identities or emergency '
                        'contact details. A missing update is not proof that '
                        'you are safe.',
              style: const TextStyle(color: Color(0xFFA9B4C2)),
            ),
            if (widget.canShareGroup) ...[
              const SizedBox(height: 18),
              SegmentedButton<ObserverAccessScope>(
                key: const Key('observer-scope'),
                segments: const [
                  ButtonSegment(
                    value: ObserverAccessScope.rider,
                    icon: Icon(Icons.person_outline),
                    label: Text('Just me'),
                  ),
                  ButtonSegment(
                    value: ObserverAccessScope.group,
                    icon: Icon(Icons.groups_outlined),
                    label: Text('Whole group'),
                  ),
                ],
                selected: {_scope},
                onSelectionChanged: widget.controller.busy
                    ? null
                    : (values) => setState(() {
                        _scope = values.single;
                        _consent = false;
                      }),
              ),
              const SizedBox(height: 8),
              Text(
                _scope == ObserverAccessScope.group
                    ? 'The watcher will see the current rider list, each '
                          'rider’s last-known position and freshness, and the '
                          'planned route outline. Tell the whole group before '
                          'creating this link.'
                    : 'This follows only your phone. Other riders and the '
                          'planned route stay private.',
                style: const TextStyle(color: Color(0xFFA9B4C2)),
              ),
            ],
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
              title: Text(
                _scope == ObserverAccessScope.group
                    ? 'I have told the group and choose to share this '
                          'read-only group view for the selected time.'
                    : 'I choose to share this information for the selected '
                          'time.',
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
                      scope: _scope,
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
                        onPressed: () => _share(context, invite),
                        icon: const Icon(Icons.share),
                        label: Text(
                          invite.grant.scope == ObserverAccessScope.group
                              ? 'Share group watcher link'
                              : 'Share safety link',
                        ),
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
                subtitle: Text('${grant.scope.label} · ${_grantStatus(grant)}'),
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

  Future<void> _share(BuildContext context, ObserverInvite invite) async {
    final renderObject = context.findRenderObject();
    final origin = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
    await SharePlus.instance.share(
      ShareParams(
        text: invite.grant.scope == ObserverAccessScope.group
            ? 'Watch our group ride using this private, read-only, '
                  'time-limited Tail End Charlie link:\n${invite.shareUri}'
            : 'Follow my last-known ride progress using this private, '
                  'time-limited Tail End Charlie link:\n${invite.shareUri}',
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
