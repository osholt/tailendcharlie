import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../domain/event_store.dart';
import '../domain/ride_event.dart';

class SqliteEventStore implements EventStore {
  Database? _database;
  Future<Database>? _opening;

  Future<Database> get _db {
    final database = _database;
    if (database != null) {
      return Future.value(database);
    }
    return _opening ??= _open();
  }

  Future<Database> _open() async {
    final databasePath = await getDatabasesPath();
    final database = await openDatabase(
      path.join(databasePath, 'ride_relay_v1.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE ride_events (
            id TEXT PRIMARY KEY,
            ride_id TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            acknowledged INTEGER NOT NULL DEFAULT 0,
            body TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE INDEX ride_events_ride_created_idx
          ON ride_events (ride_id, created_at)
        ''');
        await db.execute('''
          CREATE INDEX ride_events_pending_idx
          ON ride_events (ride_id, acknowledged, created_at)
        ''');
      },
    );
    _database = database;
    _opening = null;
    return database;
  }

  @override
  Future<void> append(RideEvent event) async {
    final db = await _db;
    await db.insert('ride_events', {
      'id': event.id,
      'ride_id': event.rideId,
      'created_at': event.createdAt.millisecondsSinceEpoch,
      'acknowledged': event.acknowledged ? 1 : 0,
      'body': jsonEncode(event.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  @override
  Future<void> close() async {
    final database = _database;
    _database = null;
    if (database != null) {
      await database.close();
    }
  }

  @override
  Future<void> deleteRide(String rideId) async {
    final db = await _db;
    await db.delete('ride_events', where: 'ride_id = ?', whereArgs: [rideId]);
  }

  @override
  Future<void> deleteEvents(String rideId, Iterable<String> eventIds) async {
    final ids = eventIds.toList(growable: false);
    if (ids.isEmpty) return;
    final db = await _db;
    await db.delete(
      'ride_events',
      where:
          'ride_id = ? AND id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: [rideId, ...ids],
    );
  }

  @override
  Future<List<RideEvent>> eventsForRide(String rideId) async {
    final db = await _db;
    final rows = await db.query(
      'ride_events',
      where: 'ride_id = ?',
      whereArgs: [rideId],
      orderBy: 'created_at ASC',
    );
    return rows.map(_decodeRow).toList(growable: false);
  }

  @override
  Future<Set<String>> existingEventIds(
    String rideId,
    Iterable<String> eventIds,
  ) async {
    final ids = eventIds.toList(growable: false);
    if (ids.isEmpty) return {};
    final db = await _db;
    final rows = await db.query(
      'ride_events',
      columns: const ['id'],
      where:
          'ride_id = ? AND id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: [rideId, ...ids],
    );
    return rows.map((row) => row['id']! as String).toSet();
  }

  @override
  Future<void> markAcknowledged(String eventId) async {
    final db = await _db;
    await db.update(
      'ride_events',
      {'acknowledged': 1},
      where: 'id = ?',
      whereArgs: [eventId],
    );
  }

  @override
  Future<void> markAcknowledgedAll(Iterable<String> eventIds) async {
    final ids = eventIds.toList(growable: false);
    if (ids.isEmpty) return;
    final db = await _db;
    await db.update(
      'ride_events',
      {'acknowledged': 1},
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
  }

  @override
  Future<int> pendingEventCount(String rideId) async {
    final db = await _db;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM ride_events '
            'WHERE ride_id = ? AND acknowledged = 0',
            [rideId],
          ),
        ) ??
        0;
  }

  @override
  Future<List<RideEvent>> pendingEvents(String rideId, {int? limit}) async {
    final db = await _db;
    final rows = await db.query(
      'ride_events',
      where: 'ride_id = ? AND acknowledged = 0',
      whereArgs: [rideId],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map(_decodeRow).toList(growable: false);
  }

  RideEvent _decodeRow(Map<String, Object?> row) {
    final event = RideEvent.fromJson(
      Map<String, Object?>.from(jsonDecode(row['body']! as String) as Map),
    );
    return event.copyWith(acknowledged: row['acknowledged'] == 1);
  }
}
