import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../domain/completed_ride.dart';
import '../domain/completed_ride_store.dart';

class JsonFileCompletedRideStore implements CompletedRideStore {
  JsonFileCompletedRideStore(this.directory);

  final Directory directory;

  static Future<JsonFileCompletedRideStore> openDefault() async {
    final support = await getApplicationSupportDirectory();
    return JsonFileCompletedRideStore(
      Directory(path.join(support.path, 'completed_rides')),
    );
  }

  @override
  Future<List<CompletedRide>> list() async {
    if (!await directory.exists()) return const [];
    final rides = <CompletedRide>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is Map) {
          rides.add(CompletedRide.fromJson(Map<String, Object?>.from(decoded)));
        }
      } on Object {
        // One damaged archive must never make the rest of the library vanish.
      }
    }
    rides.sort((left, right) => right.endedAt.compareTo(left.endedAt));
    return rides;
  }

  @override
  Future<void> save(CompletedRide ride) async {
    await directory.create(recursive: true);
    final file = _fileFor(ride.rideId);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(ride.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  @override
  Future<void> delete(String rideId) async {
    final file = _fileFor(rideId);
    if (await file.exists()) await file.delete();
  }

  File _fileFor(String rideId) {
    final safeName = base64Url.encode(utf8.encode(rideId)).replaceAll('=', '');
    return File(path.join(directory.path, '$safeName.json'));
  }
}
