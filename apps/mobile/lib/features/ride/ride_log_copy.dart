import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Puts [text] on the clipboard and says so, for the ride review's lists (#849,
/// #854): every time in them is one tap from a note or a footage player.
///
/// The messenger is read before the await, because the tap that started this may
/// have left the tree by the time the clipboard answers.
Future<void> copyRideLogText(
  BuildContext context, {
  required String text,
  required String confirmation,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  await Clipboard.setData(ClipboardData(text: text));
  messenger?.showSnackBar(
    SnackBar(content: Text(confirmation), duration: const Duration(seconds: 2)),
  );
}
