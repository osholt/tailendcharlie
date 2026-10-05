import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:share_plus/share_plus.dart';

/// Hands one recorded diagnostics log to the share sheet as a text file.
///
/// The seam the ended-ride screen shares through, so a widget test can see what
/// would have been shared without opening a share sheet.
typedef RideDiagnosticsFileSharer =
    Future<void> Function({
      required String fileName,
      required String text,
      Rect? sharePositionOrigin,
    });

/// The attachment name for a ride's log. The same name the summary share uses, so
/// a rider who shares both gets one file, not two that differ by a word.
String rideDiagnosticsFileName(String rideCode) =>
    'tail-end-charlie-diagnostics-$rideCode.txt';

/// The share sheet itself.
Future<void> shareRideDiagnosticsFile({
  required String fileName,
  required String text,
  Rect? sharePositionOrigin,
}) => SharePlus.instance.share(
  ShareParams(
    title: 'Ride diagnostics',
    subject: 'Tail End Charlie diagnostics',
    files: [
      XFile.fromData(
        Uint8List.fromList(utf8.encode(text)),
        mimeType: 'text/plain',
        name: fileName,
      ),
    ],
    fileNameOverrides: [fileName],
    sharePositionOrigin: sharePositionOrigin,
  ),
);
