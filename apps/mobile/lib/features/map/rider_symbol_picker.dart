import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motorcycle_icon.dart';

/// Shared profile control for choosing the glyph inside a rider's colour badge.
///
/// Kept in one widget so onboarding, Settings, and create/join cannot offer
/// different identity choices.
class RiderSymbolPicker extends StatelessWidget {
  const RiderSymbolPicker({
    super.key,
    required this.displayName,
    required this.selectedSymbol,
    required this.motorcycleStyle,
    required this.badgeColor,
    required this.onSymbolChanged,
    required this.onMotorcycleStyleChanged,
    required this.keyPrefix,
    required this.bikeKeyPrefix,
  });

  final String displayName;
  final RiderSymbol selectedSymbol;
  final MotorcycleIconStyle motorcycleStyle;
  final Color badgeColor;
  final ValueChanged<RiderSymbol> onSymbolChanged;
  final ValueChanged<MotorcycleIconStyle> onMotorcycleStyleChanged;
  final String keyPrefix;
  final String bikeKeyPrefix;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('Rider symbol', style: TextStyle(color: Color(0xFFABB5C1))),
      const SizedBox(height: 8),
      Wrap(
        spacing: 9,
        runSpacing: 9,
        children: [
          _SymbolChoice(
            key: Key('$keyPrefix-motorcycle'),
            label: 'Bike',
            selected: selectedSymbol.kind == RiderSymbolKind.motorcycle,
            symbol: const RiderSymbol.motorcycle(),
            displayName: displayName,
            motorcycleStyle: motorcycleStyle,
            badgeColor: badgeColor,
            onTap: () => onSymbolChanged(const RiderSymbol.motorcycle()),
          ),
          _SymbolChoice(
            key: Key('$keyPrefix-initials'),
            label: 'Initials',
            selected: selectedSymbol.kind == RiderSymbolKind.initials,
            symbol: selectedSymbol.kind == RiderSymbolKind.initials
                ? selectedSymbol
                : const RiderSymbol.initials(),
            displayName: displayName,
            motorcycleStyle: motorcycleStyle,
            badgeColor: badgeColor,
            onTap: () => onSymbolChanged(
              selectedSymbol.kind == RiderSymbolKind.initials
                  ? selectedSymbol
                  : const RiderSymbol.initials(),
            ),
          ),
          _SymbolChoice(
            key: Key('$keyPrefix-emoji'),
            label: 'Emoji',
            selected: selectedSymbol.kind == RiderSymbolKind.emoji,
            symbol: RiderSymbol.emoji(
              selectedSymbol.kind == RiderSymbolKind.emoji
                  ? selectedSymbol.emoji!
                  : riderEmojiChoices.first,
            ),
            displayName: displayName,
            motorcycleStyle: motorcycleStyle,
            badgeColor: badgeColor,
            onTap: () => onSymbolChanged(
              RiderSymbol.emoji(
                selectedSymbol.kind == RiderSymbolKind.emoji
                    ? selectedSymbol.emoji!
                    : riderEmojiChoices.first,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (selectedSymbol.kind == RiderSymbolKind.motorcycle)
        SizedBox(
          height: 68,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: MotorcycleIconStyle.values.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final style = MotorcycleIconStyle.values[index];
              final selected = style == motorcycleStyle;
              return Semantics(
                button: true,
                selected: selected,
                label: '${style.label} motorcycle icon',
                child: InkWell(
                  key: Key('$bikeKeyPrefix-${style.name}'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onMotorcycleStyleChanged(style),
                  child: Container(
                    width: 56,
                    decoration: BoxDecoration(
                      color: selected
                          ? badgeColor.withValues(alpha: 0.16)
                          : const Color(0xFF1D2530),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected ? badgeColor : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: Center(
                      child: RiderMarkerBadge(
                        style: style,
                        badgeColor: badgeColor,
                        size: 34,
                        borderWidth: 0,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        )
      else if (selectedSymbol.kind == RiderSymbolKind.emoji)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final emoji in riderEmojiChoices)
              Semantics(
                button: true,
                selected: selectedSymbol.emoji == emoji,
                label: '$emoji rider emoji',
                child: InkWell(
                  key: Key(
                    '$keyPrefix-emoji-${emoji.runes.map((rune) => rune.toRadixString(16)).join('-')}',
                  ),
                  customBorder: const CircleBorder(),
                  onTap: () => onSymbolChanged(RiderSymbol.emoji(emoji)),
                  child: Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selectedSymbol.emoji == emoji
                          ? badgeColor.withValues(alpha: 0.22)
                          : const Color(0xFF1D2530),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selectedSymbol.emoji == emoji
                            ? badgeColor
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: Text(emoji, style: const TextStyle(fontSize: 24)),
                  ),
                ),
              ),
          ],
        )
      else ...[
        TextFormField(
          key: const Key('rider-custom-initials'),
          initialValue: selectedSymbol.customInitials ?? '',
          maxLength: 3,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [
            LengthLimitingTextInputFormatter(3),
            FilteringTextInputFormatter.allow(
              RegExp(r'[\p{L}\p{N}]', unicode: true),
            ),
          ],
          decoration: InputDecoration(
            labelText: 'Marker initials',
            hintText: riderInitials(displayName),
            counterText: '',
            helperText:
                'Leave blank to use ${riderInitials(displayName)} from your name.',
          ),
          onChanged: (value) {
            final normalized = normalizeCustomRiderInitials(value);
            onSymbolChanged(
              selectedSymbol.withInitials(
                customInitials: normalized,
                useAutomaticInitials: normalized == null,
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        const Text(
          'Initials colour',
          style: TextStyle(color: Color(0xFFABB5C1)),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 9,
          runSpacing: 9,
          children: [
            for (final ink in RiderInitialsInk.values)
              Semantics(
                button: true,
                selected: selectedSymbol.initialsInk == ink,
                label: '${ink.label} initials colour',
                child: InkWell(
                  key: Key('$keyPrefix-initials-ink-${ink.name}'),
                  customBorder: const CircleBorder(),
                  onTap: () =>
                      onSymbolChanged(selectedSymbol.withInitials(ink: ink)),
                  child: Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: badgeColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selectedSymbol.initialsInk == ink
                            ? Colors.white
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: Text(
                      'A',
                      style: TextStyle(
                        color: ink.color,
                        shadows: riderInitialsShadows(ink.color, 0.8),
                        fontSize: 26,
                        height: 1,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Your marker will show ${selectedSymbol.initialsFor(displayName)} in ${selectedSymbol.initialsInk.label.toLowerCase()}.',
          style: const TextStyle(color: Color(0xFF8994A2), fontSize: 12),
        ),
      ],
    ],
  );
}

class _SymbolChoice extends StatelessWidget {
  const _SymbolChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.symbol,
    required this.displayName,
    required this.motorcycleStyle,
    required this.badgeColor,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final RiderSymbol symbol;
  final String displayName;
  final MotorcycleIconStyle motorcycleStyle;
  final Color badgeColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '$label rider symbol',
    child: InkWell(
      borderRadius: BorderRadius.circular(13),
      onTap: onTap,
      child: Container(
        width: 88,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? badgeColor.withValues(alpha: 0.16)
              : const Color(0xFF1D2530),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: selected ? badgeColor : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RiderMarkerBadge(
              style: motorcycleStyle,
              symbol: symbol,
              displayName: displayName,
              badgeColor: badgeColor,
              size: 34,
              borderWidth: 0,
            ),
            const SizedBox(height: 5),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    ),
  );
}
