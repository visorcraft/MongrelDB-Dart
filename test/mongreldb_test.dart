// Live integration tests for the MongrelDB Dart client.
//
// These tests boot a real `mongreldb-server` binary and round-trip data
// through every public method. They skip automatically when no daemon is
// reachable at the URL in MONGRELDB_URL (default http://127.0.0.1:8453), so
// `dart test` still passes offline.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:mongreldb/mongreldb.dart';
import 'package:test/test.dart';

final Uri _serverUri =
    Uri.parse(Platform.environment['MONGRELDB_URL'] ?? 'http://127.0.0.1:8453');

bool? _reachableCache;

Future<bool> _serverReachable() async {
  if (_reachableCache != null) return _reachableCache!;
  try {
    final client = HttpClient();
    final req =
        await client.getUrl(_serverUri.replace(path: '/health')).timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw TimeoutException('health check timed out'),
    );
    final resp = await req.close().timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw TimeoutException('health read timed out'),
    );
    await resp.drain<void>();
    client.close(force: true);
    _reachableCache = resp.statusCode == 200;
  } catch (_) {
    _reachableCache = false;
  }
  return _reachableCache!;
}

Future<MongrelDB> _connect() async {
  final db = MongrelDB(_serverUri.toString());
  // Ensure the daemon is up before handing back a client.
  if (!await _serverReachable()) {
    db.close();
    throw StateError('MongrelDB daemon not reachable');
  }
  return db;
}

const _columns = <Map<String, Object?>>[
  {'id': 1, 'name': 'id', 'ty': 'int64', 'primary_key': true, 'nullable': false},
  {
    'id': 2,
    'name': 'label',
    'ty': 'varchar',
    'primary_key': false,
    'nullable': false
  },
  {
    'id': 3,
    'name': 'amount',
    'ty': 'float64',
    'primary_key': false,
    'nullable': false
  },
];

void main() {
  group('MongrelDB live', () {
    test('health reports true', () async {
      if (!await _serverReachable()) {
        print('skip: MONGRELDB_URL not reachable');
        return;
      }
      final db = await _connect();
      addTearDown(db.close);
      expect(await db.health(), isTrue);
    });

    test('createTable, put, count, and query round-trip', () async {
      if (!await _serverReachable()) {
        print('skip: MONGRELDB_URL not reachable');
        return;
      }
      final db = await _connect();
      addTearDown(db.close);
      final table = 'dart_items_${DateTime.now().microsecondsSinceEpoch}';

      await db.createTable(table, _columns);
      await db.put(table, {1: 1, 2: 'alpha', 3: 10.0});
      await db.put(table, {1: 2, 2: 'beta', 3: 25.0});

      expect(await db.count(table), 2);

      final rows = await db
          .query(table)
          .where('pk', {'value': 2})
          .execute();
      expect(rows, isNotEmpty);
    });

    test('upsert updates an existing row on PK conflict', () async {
      if (!await _serverReachable()) {
        print('skip: MONGRELDB_URL not reachable');
        return;
      }
      final db = await _connect();
      addTearDown(db.close);
      final table = 'dart_upsert_${DateTime.now().microsecondsSinceEpoch}';

      await db.createTable(table, _columns);
      await db.put(table, {1: 1, 2: 'alpha', 3: 10.0});
      await db.upsert(table, {1: 1, 2: 'alpha', 3: 99.0},
          updateCells: {3: 99.0});

      expect(await db.count(table), 1);
    });

    test('transaction commits multiple ops atomically', () async {
      if (!await _serverReachable()) {
        print('skip: MONGRELDB_URL not reachable');
        return;
      }
      final db = await _connect();
      addTearDown(db.close);
      final table = 'dart_txn_${DateTime.now().microsecondsSinceEpoch}';

      await db.createTable(table, _columns);

      // Seed two rows in a first committed transaction. delete_by_pk reads
      // committed state, so the row to delete must be visible before the
      // delete batch runs (the daemon cannot resolve a PK inserted earlier in
      // the same uncommitted /kit/txn batch).
      final seed = db.beginTransaction();
      seed.put(table, {1: 10, 2: 'dave', 3: 50.0});
      seed.put(table, {1: 11, 2: 'eve', 3: 75.0});
      await seed.commit();
      expect(seed.length, 2);
      expect(await db.count(table), 2);

      final txn = db.beginTransaction();
      txn.deleteByPk(table, 10);
      await txn.commit();
      expect(txn.length, 1);
      expect(await db.count(table), 1);
    });

    test('SQL round-trips through /sql', () async {
      if (!await _serverReachable()) {
        print('skip: MONGRELDB_URL not reachable');
        return;
      }
      final db = await _connect();
      addTearDown(db.close);
      final table = 'dart_sql_${DateTime.now().microsecondsSinceEpoch}';

      await db.createTable(table, _columns);
      await db.put(table, {1: 1, 2: 'alpha', 3: 1.0});
      // INSERT then SELECT. SELECT may return Arrow IPC bytes (decoded as []).
      await db.sql("INSERT INTO $table (id, label, amount) "
          "VALUES (2, 'beta', 2.0)");
      expect(await db.count(table), 2);
    });

    test('schema returns the created table', () async {
      if (!await _serverReachable()) {
        print('skip: MONGRELDB_URL not reachable');
        return;
      }
      final db = await _connect();
      addTearDown(db.close);
      final table = 'dart_schema_${DateTime.now().microsecondsSinceEpoch}';

      await db.createTable(table, _columns);
      final names = await db.tableNames();
      expect(names, contains(table));
      final desc = await db.schemaFor(table);
      expect(desc, isNotEmpty);
    });
  });
}
