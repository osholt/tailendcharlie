import 'package:flutter/material.dart';

import '../../domain/quick_message.dart';
import 'ride_map_feature.dart' show quickMessageIcon;

/// The map control that opens the leader's broadcasts (#854).
///
/// Offered only to the leader of a running group ride (see
/// `leaderBroadcastsAvailable`). It sits beside REPORT in the same action row, in
/// the same family - a big, glove-sized target in a fixed box - and is blue where
/// REPORT is amber and SOS red, so the three cannot be taken for one another.
///
/// 64 wide and as tall as REPORT, 96: narrower than REPORT because it shares its
/// row, and no taller because REPORT already sets the height of that row.
class LeaderBroadcastButton extends StatelessWidget {
  const LeaderBroadcastButton({super.key, required this.onPressed});

  /// Null while the sheet is already open, so the button cannot stack a second.
  final VoidCallback? onPressed;

  static const double width = 64;
  static const double height = 96;

  static const _fill = Color(0xFF1F4E79);

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    label: 'Tell the group',
    onTap: onPressed,
    excludeSemantics: true,
    child: Tooltip(
      message: 'Tell the group: pull over, wrong way, fuel, regroup',
      child: Material(
        color: _fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: Color(0xFF8FC4F5), width: 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('leader-broadcast-button'),
          onTap: onPressed,
          child: const SizedBox(
            width: width,
            height: height,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.campaign_rounded, size: 34, color: Colors.white),
                SizedBox(height: 4),
                // The box keeps its size at every text size, so the caption is
                // what gives way rather than the box overflowing.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'TELL\nGROUP',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        height: 1.05,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Opens the leader's list of broadcasts and returns the one they tapped, or null
/// when they closed it.
///
/// One tap on an option is the whole of it: the sheet closes and the caller sends.
/// There is no confirmation, because the leader is riding and these are not
/// emergencies (#854); a mis-tap costs a line on the group's screens, not a stop.
///
/// Scroll-controlled so it takes the height it needs - the framework otherwise caps
/// a sheet at nine sixteenths of the screen, which on a landscape phone left the
/// lower options below the fold (#133).
Future<QuickMessage?> showLeaderBroadcastSheet(BuildContext context) =>
    showModalBottomSheet<QuickMessage>(
      context: context,
      backgroundColor: const Color(0xFF161D26),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          key: const Key('leader-broadcast-sheet'),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: Text(
                  'Tell the group',
                  style: TextStyle(
                    color: Color(0xFFE4E9EF),
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              LeaderBroadcastOptions(
                onSelected: (message) =>
                    Navigator.of(sheetContext).pop(message),
              ),
              TextButton(
                key: const Key('leader-broadcast-cancel'),
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );

/// How many columns the broadcast options go in.
///
/// Two while each can hold a full-size target, one otherwise - the same rule the
/// two-option report sheet used (#133), for the same reason: the arrangement
/// changes, never the size of a target a gloved hand has to hit. The width one
/// option needs scales with the text size, because its label does.
int leaderBroadcastColumns({
  required double availableWidth,
  required double textScale,
}) {
  const gap = 12.0;
  // Icon, padding a gloved hand needs, and the longest label ("Wrong way – turn
  // around") broken over two lines, at the current text size.
  final needed = 34 + 28 + 12 * 7.2 * textScale;
  return availableWidth.isFinite && (availableWidth - gap) / 2 >= needed
      ? 2
      : 1;
}

/// The leader's broadcasts as large one-tap targets.
class LeaderBroadcastOptions extends StatelessWidget {
  const LeaderBroadcastOptions({super.key, required this.onSelected});

  final ValueChanged<QuickMessage> onSelected;

  /// Every option is at least this tall, in every arrangement, never traded for
  /// fit.
  static const double optionHeight = 84;

  static Color _colorFor(QuickMessage message) => switch (message) {
    QuickMessage.wrongWay => const Color(0xFFB45309),
    QuickMessage.pullOver => const Color(0xFF9B1B23),
    QuickMessage.stoppedForFuel => const Color(0xFF3D4A5C),
    _ => const Color(0xFF17497F),
  };

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = leaderBroadcastColumns(
          availableWidth: constraints.maxWidth,
          textScale: textScale,
        );
        final options = [
          for (final message in leaderBroadcastMessages)
            _Option(
              message: message,
              color: _colorFor(message),
              onPressed: () => onSelected(message),
            ),
        ];
        if (columns == 1) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: options,
          );
        }
        return Column(
          key: const Key('leader-broadcast-two-columns'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < options.length; index += 2)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: options[index]),
                  const SizedBox(width: 12),
                  Expanded(
                    child: index + 1 < options.length
                        ? options[index + 1]
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.message,
    required this.color,
    required this.onPressed,
  });

  final QuickMessage message;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: SizedBox(
      height: LeaderBroadcastOptions.optionHeight,
      child: FilledButton(
        key: Key('leader-broadcast-option-${message.name}'),
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(quickMessageIcon(message), size: 34),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                message.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  height: 1.1,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
