import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../domain/imported_route.dart';
import 'gpx_parser.dart';

class BundledDemoRouteLoader {
  const BundledDemoRouteLoader();

  Future<ImportedRoute> load() async {
    final data = await rootBundle.load('assets/demo_route.gpx');
    return const GpxParser().parse(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      routeId: const Uuid().v4(),
      sourceFileName: 'demo_route.gpx',
      importedAt: DateTime.now(),
    );
  }
}
