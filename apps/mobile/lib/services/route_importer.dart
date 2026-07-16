import 'package:uuid/uuid.dart';

import '../domain/imported_route.dart';
import 'gpx_import_source.dart';
import 'gpx_parser.dart';

class RouteImporter {
  RouteImporter({
    required this.source,
    this.parser = const GpxParser(),
    String Function()? idFactory,
    DateTime Function()? clock,
  }) : _idFactory = idFactory ?? const Uuid().v4,
       _clock = clock ?? DateTime.now;

  final GpxImportSource source;
  final GpxParser parser;
  final String Function() _idFactory;
  final DateTime Function() _clock;

  Future<ImportedRoute?> importFromPicker() async {
    final file = await source.pickGpxFile();
    if (file == null) return null;
    return parser.parse(
      file.bytes,
      routeId: _idFactory(),
      sourceFileName: file.name,
      importedAt: _clock(),
    );
  }
}
