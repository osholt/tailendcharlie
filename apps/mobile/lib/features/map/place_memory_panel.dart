/// The saved places and the history that sit above a search's results (#937).
///
/// Shared by Home's **Where to?** and the plan surface's place picker, so the
/// two cannot drift apart: same rows, same keys apart from a prefix, same menus.
/// What the lists are and where they may go is in
/// `lib/services/place_memory.dart`; the short version is that they stay on the
/// phone.
///
/// Typing in the search field filters these rows as the rider types. That is a
/// local filter over a handful of rows and sends nothing anywhere; the search
/// itself still runs only when submitted (`docs/geocoder-decision.md`).
library;

import 'package:flutter/material.dart';

import '../../domain/ride_plan.dart';
import '../../services/place_memory.dart';

/// Opens a search to choose where a saved place points, or returns null when the
/// rider backs out. [title] says what is being chosen.
typedef RememberedPlacePicker = Future<RidePlanPlace?> Function(String title);

/// Everything a rider can do to their saved places and history.
///
/// Holds no widgets of its own: each method opens the dialog it needs over the
/// [BuildContext] it is given, changes [memory], and returns.
class PlaceMemoryActions {
  PlaceMemoryActions({required this.memory, required this.pickPlace});

  final PlaceMemory memory;
  final RememberedPlacePicker pickPlace;

  /// Saves one [place] to the phone's own saved places and lets go of them
  /// again: for a surface that has a place in hand - a dropped pin, a stop - and
  /// no search of its own.
  static Future<SavedPlace?> saveOnce(
    BuildContext context,
    RidePlanPlace place,
  ) async {
    final memory = await PlaceMemory.open();
    try {
      if (!context.mounted) return null;
      return await PlaceMemoryActions(
        memory: memory,
        pickPlace: (_) async => null,
      ).saveAs(context, place);
    } finally {
      memory.dispose();
    }
  }

  /// Sets Home or Work, or adds a place of the rider's own, choosing where it
  /// points with [pickPlace].
  Future<void> add(BuildContext context, SavedPlaceKind kind) async {
    switch (kind) {
      case SavedPlaceKind.home:
        final place = await pickPlace('Set Home');
        if (place != null) await memory.setHome(place);
      case SavedPlaceKind.work:
        final place = await pickPlace('Set Work');
        if (place != null) await memory.setWork(place);
      case SavedPlaceKind.custom:
        if (!memory.canAddCustom) {
          await _notice(
            context,
            'You can keep ${PlaceMemory.customLimit} places of your own. '
            'Delete one to add another.',
          );
          return;
        }
        final name = await _askName(context, title: 'Name this place');
        if (name == null || !context.mounted) return;
        final place = await pickPlace('Where is $name?');
        if (place != null) await memory.addCustom(name, place);
    }
  }

  /// Saves [place] - a search result, a recent place or a dropped pin - as Home,
  /// Work or under a name of the rider's own.
  ///
  /// Returns what it was saved as, or null when the rider backed out.
  Future<SavedPlace?> saveAs(BuildContext context, RidePlanPlace place) async {
    final target = await showDialog<SavedPlaceKind>(
      context: context,
      builder: (context) => SimpleDialog(
        key: const Key('save-place-chooser'),
        title: const Text('Save this place as'),
        children: [
          SimpleDialogOption(
            key: const Key('save-place-as-home'),
            onPressed: () => Navigator.pop(context, SavedPlaceKind.home),
            child: Text(
              memory.home == null
                  ? 'Home'
                  : 'Home (replaces ${memory.home!.name})',
            ),
          ),
          SimpleDialogOption(
            key: const Key('save-place-as-work'),
            onPressed: () => Navigator.pop(context, SavedPlaceKind.work),
            child: Text(
              memory.work == null
                  ? 'Work'
                  : 'Work (replaces ${memory.work!.name})',
            ),
          ),
          SimpleDialogOption(
            key: const Key('save-place-as-other'),
            onPressed: () => Navigator.pop(context, SavedPlaceKind.custom),
            child: const Text('Another name…'),
          ),
        ],
      ),
    );
    if (target == null || !context.mounted) return null;
    switch (target) {
      case SavedPlaceKind.home:
        return memory.setHome(place);
      case SavedPlaceKind.work:
        return memory.setWork(place);
      case SavedPlaceKind.custom:
        if (!memory.canAddCustom) {
          await _notice(
            context,
            'You can keep ${PlaceMemory.customLimit} places of your own. '
            'Delete one to add another.',
          );
          return null;
        }
        final name = await _askName(context, title: 'Name this place');
        if (name == null) return null;
        return memory.addCustom(name, place);
    }
  }

  Future<void> rename(BuildContext context, SavedPlace place) async {
    final name = await _askName(
      context,
      title: 'Rename ${place.name}',
      initial: place.name,
      exceptId: place.id,
    );
    if (name != null) await memory.rename(place.id, name);
  }

  Future<void> changePlace(BuildContext context, SavedPlace place) async {
    final moved = await pickPlace('Move ${place.name} to');
    if (moved != null) await memory.relocate(place.id, moved);
  }

  Future<void> delete(BuildContext context, SavedPlace place) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('delete-saved-place-dialog'),
        title: Text('Delete ${place.name}?'),
        content: const Text(
          'It is removed from this phone. Nothing else changes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            key: const Key('delete-saved-place-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await memory.delete(place.id);
  }

  Future<void> clearHistory(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('clear-search-history-dialog'),
        title: const Text('Clear search history?'),
        content: const Text('Your saved places stay.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            key: const Key('clear-search-history-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await memory.clearRecents();
  }

  Future<String?> _askName(
    BuildContext context, {
    required String title,
    String initial = '',
    String? exceptId,
  }) => showDialog<String>(
    context: context,
    builder: (context) => _NameDialog(
      memory: memory,
      title: title,
      initial: initial,
      exceptId: exceptId,
    ),
  );

  Future<void> _notice(BuildContext context, String message) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
}

/// Asks for a saved place's name and says what is wrong with it as it is typed.
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.memory,
    required this.title,
    required this.initial,
    required this.exceptId,
  });

  final PlaceMemory memory;
  final String title;
  final String initial;
  final String? exceptId;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typed = _controller.text;
    final problem = typed.trim().isEmpty
        ? null
        : widget.memory.nameProblem(typed, exceptId: widget.exceptId);
    final acceptable = typed.trim().isNotEmpty && problem == null;
    return AlertDialog(
      key: const Key('saved-place-name-dialog'),
      title: Text(widget.title),
      content: TextField(
        key: const Key('saved-place-name-field'),
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        maxLength: PlaceMemory.nameLimit,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: "Mum's, The club, Campsite",
          errorText: problem,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('saved-place-name-save'),
          onPressed: acceptable
              ? () => Navigator.pop(context, typed.trim())
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

enum _SavedMenu { change, rename, delete }

enum _RecentMenu { save, remove }

/// The rows: Home, Work and the rider's own places, then the recent ones.
///
/// With nothing typed it offers to set Home and Work and shows everything. With
/// something typed it shows only the rows that match, and none of the set-up
/// rows, so the list narrows as the rider types and the results of the search
/// they submit still come from the service.
class PlaceMemoryPanel extends StatelessWidget {
  const PlaceMemoryPanel({
    super.key,
    required this.actions,
    required this.query,
    required this.keyPrefix,
    required this.onPickSaved,
    required this.onPickRecent,
  });

  final PlaceMemoryActions actions;

  /// What is typed in the search field right now.
  final String query;

  /// Distinguishes the keys of the sheet this sits in.
  final String keyPrefix;
  final ValueChanged<SavedPlace> onPickSaved;
  final ValueChanged<RecentPlace> onPickRecent;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: actions.memory,
    builder: (context, _) {
      final memory = actions.memory;
      final typing = query.trim().isNotEmpty;
      final saved = memory.savedMatching(query);
      final recents = memory.recentsMatching(query);
      const muted = TextStyle(color: Color(0xFF98A3B1));
      Widget heading(String text, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: Color(0xFF98A3B1),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      );

      Widget savedTile(SavedPlace place) => ListTile(
        key: Key('$keyPrefix-saved-${place.id}'),
        leading: Icon(switch (place.kind) {
          SavedPlaceKind.home => Icons.home_outlined,
          SavedPlaceKind.work => Icons.work_outline,
          SavedPlaceKind.custom => Icons.bookmark_outline,
        }),
        title: Text(place.name),
        subtitle: place.description == null
            ? null
            : Text(
                place.description!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
        onTap: () => onPickSaved(place),
        trailing: PopupMenuButton<_SavedMenu>(
          key: Key('$keyPrefix-saved-menu-${place.id}'),
          tooltip: 'Edit ${place.name}',
          onSelected: (action) => switch (action) {
            _SavedMenu.change => actions.changePlace(context, place),
            _SavedMenu.rename => actions.rename(context, place),
            _SavedMenu.delete => actions.delete(context, place),
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              key: Key('$keyPrefix-saved-change-${place.id}'),
              value: _SavedMenu.change,
              child: const Text('Change place'),
            ),
            if (place.kind == SavedPlaceKind.custom)
              PopupMenuItem(
                key: Key('$keyPrefix-saved-rename-${place.id}'),
                value: _SavedMenu.rename,
                child: const Text('Rename'),
              ),
            PopupMenuItem(
              key: Key('$keyPrefix-saved-delete-${place.id}'),
              value: _SavedMenu.delete,
              child: const Text('Delete'),
            ),
          ],
        ),
      );

      Widget addTile(
        String id,
        IconData icon,
        String title,
        SavedPlaceKind kind, {
        String? subtitle,
      }) => ListTile(
        key: Key('$keyPrefix-add-$id'),
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle, style: muted),
        onTap: () => actions.add(context, kind),
      );

      // Home, then Work, each either set or offered, then the rider's own and a
      // way to add another. Typing leaves only what matches.
      final savedRows = <Widget>[
        if (typing)
          for (final place in saved) savedTile(place)
        else ...[
          if (memory.home case final home?)
            savedTile(home)
          else
            addTile(
              'home',
              Icons.home_outlined,
              'Add Home',
              SavedPlaceKind.home,
              subtitle: 'Choose it once, then pick it from here',
            ),
          if (memory.work case final work?)
            savedTile(work)
          else
            addTile(
              'work',
              Icons.work_outline,
              'Add Work',
              SavedPlaceKind.work,
            ),
          for (final place in memory.custom) savedTile(place),
          if (memory.canAddCustom)
            addTile(
              'custom',
              Icons.add_location_alt_outlined,
              'Save another place',
              SavedPlaceKind.custom,
            ),
        ],
      ];

      return Column(
        key: Key('$keyPrefix-place-memory'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (savedRows.isNotEmpty) heading('SAVED PLACES'),
          ...savedRows,
          if (recents.isNotEmpty)
            heading(
              'RECENT',
              trailing: typing
                  ? null
                  : TextButton(
                      key: Key('$keyPrefix-clear-history'),
                      onPressed: () => actions.clearHistory(context),
                      child: const Text('Clear'),
                    ),
            ),
          for (final (index, place) in recents.indexed)
            ListTile(
              key: Key('$keyPrefix-recent-$index'),
              leading: const Icon(Icons.history),
              title: Text(place.label),
              subtitle: place.description == null
                  ? null
                  : Text(
                      place.description!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
              onTap: () => onPickRecent(place),
              trailing: PopupMenuButton<_RecentMenu>(
                key: Key('$keyPrefix-recent-menu-$index'),
                tooltip: 'More for ${place.label}',
                onSelected: (action) => switch (action) {
                  _RecentMenu.save => actions.saveAs(
                    context,
                    place.toPlanPlace(),
                  ),
                  _RecentMenu.remove => actions.memory.forget(place),
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    key: Key('$keyPrefix-recent-save-$index'),
                    value: _RecentMenu.save,
                    child: const Text('Save as…'),
                  ),
                  PopupMenuItem(
                    key: Key('$keyPrefix-recent-remove-$index'),
                    value: _RecentMenu.remove,
                    child: const Text('Remove from history'),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}
