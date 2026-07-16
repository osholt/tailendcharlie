import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

class PickedGpxFile {
  const PickedGpxFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

abstract interface class GpxImportSource {
  Future<PickedGpxFile?> pickGpxFile();
}

class SystemGpxImportSource implements GpxImportSource {
  const SystemGpxImportSource();

  static const _gpxType = XTypeGroup(
    label: 'GPX route',
    extensions: ['gpx'],
    mimeTypes: ['application/gpx+xml', 'application/xml', 'text/xml'],
    uniformTypeIdentifiers: ['com.topografix.gpx', 'public.xml'],
    webWildCards: ['application/gpx+xml', 'application/xml', 'text/xml'],
  );

  @override
  Future<PickedGpxFile?> pickGpxFile() async {
    final selected = await openFile(acceptedTypeGroups: const [_gpxType]);
    if (selected == null) return null;
    return PickedGpxFile(
      name: selected.name,
      bytes: await selected.readAsBytes(),
    );
  }
}
