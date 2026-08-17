import 'package:flutter/material.dart';

/// A way out of a bottom sheet that does not depend on acting on it.
///
/// Every place sheet on the map had two implicit ways to close and no explicit
/// one: tap the scrim, or drag the handle. Both stop working at exactly the
/// size where a rider most needs one — a discovery highlight carrying its full
/// research detail is opened `isScrollControlled`, so it fills the screen,
/// taking the scrim with it and scrolling the handle out of reach. What is left
/// is the action button, which is why "add it to the route" read as the only
/// way out (#592).
///
/// It is a control rather than a convention because a rider wearing gloves,
/// glancing down, should not have to know that a sheet can be flung away.
///
/// Pin it **outside** any scroll view. A close button that scrolls off is the
/// thing being fixed.
class SheetCloseButton extends StatelessWidget {
  const SheetCloseButton({super.key, this.onClose});

  /// Defaults to popping the sheet. Supplied only where closing has to do
  /// something else first.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('sheet-close-button'),
    tooltip: 'Close',
    visualDensity: VisualDensity.compact,
    onPressed: onClose ?? () => Navigator.of(context).maybePop(),
    icon: const Icon(Icons.close),
  );
}
