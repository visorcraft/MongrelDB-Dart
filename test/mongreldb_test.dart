// ignore_for_file: prefer_single_quotes
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

final Uri _serverUri = Uri.parse(
  Platform.environment['MONGRELDB_URL'] ?? 'http://127.0.0.1:8453',
);

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
  {
    'id': 1,
    'name': 'id',
    'ty': 'int64',
    'primary_key': true,
    'nullable': false,
  },
  {
    'id': 2,
    'name': 'label',
    'ty': 'varchar',
    'primary_key': false,
    'nullable': false,
  },
  {
    'id': 3,
    'name': 'amount',
    'ty': 'float64',
    'primary_key': false,
    'nullable': false,
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

      final rows = await db.query(table).where('pk', {'value': 2}).execute();
      expect(rows, isNotEmpty);
      // The returned row must carry primary key 2. The native /kit/query row
      // is a flat cell array, so confirm the PK through SQL JSON mode (rows
      // keyed by column name) where the id column is directly addressable.
      final pkRows = await db.sql('SELECT id FROM $table WHERE id = 2');
      expect(pkRows.first['id'], 2);
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
      await db.upsert(
        table,
        {1: 1, 2: 'alpha', 3: 99.0},
        updateCells: {3: 99.0},
      );

      expect(await db.count(table), 1);
      // Query the row back and verify the upserted value landed. SQL JSON mode
      // returns rows keyed by column name, so the amount column is directly
      // addressable.
      final rows = await db.sql('SELECT amount FROM $table WHERE id = 1');
      expect((rows.first['amount'] as num).toDouble(), 99.0);
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
      await db.sql(
        "INSERT INTO $table (id, label, amount) "
        "VALUES (2, 'beta', 2.0)",
      );
      expect(await db.count(table), 2);
      // JSON mode makes SELECT return rows as JSON objects (column names as
      // keys). Verify both rows come back with the right primary keys.
      final selected = await db.sql('SELECT id FROM $table ORDER BY id');
      expect(selected.length, 2);
      expect(selected.map((r) => r['id']).toList(), [1, 2]);
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

    test('range query returns only rows within the bounds', () async {
      if (!await _serverReachable()) {
        print('skip: MONGRELDB_URL not reachable');
        return;
      }
      final db = await _connect();
      addTearDown(db.close);
      final table = 'dart_range_${DateTime.now().microsecondsSinceEpoch}';

      await db.createTable(table, _columns);
      await db.put(table, {1: 1, 2: 'a', 3: 50.0});
      await db.put(table, {1: 2, 2: 'b', 3: 75.0});
      await db.put(table, {1: 3, 2: 'c', 3: 90.0});
      await db.put(table, {1: 4, 2: 'd', 3: 100.0});

      // Only scores >= 80 should come back (90 and 100) - assert the count.
      // The `amount` column is float64, so use `range_f64` (plain `range`
      // expects an i64 bound and rejects floats). range_f64 requires both
      // lo/hi bounds and the inclusivity flags.
      final rows = await db.query(table).where('range_f64', {
        'column': 3,
        'min': 80.0,
        'max': 200.0,
        'min_inclusive': true,
        'max_inclusive': true,
      }).execute();
      expect(rows.length, 2);
      // Only rows with id 3 (amount 90) and 4 (amount 100) qualify. Confirm
      // their exact PK values via SQL JSON mode (rows keyed by column name).
      final selected = await db.sql(
        'SELECT id FROM $table WHERE amount >= 80.0 ORDER BY id',
      );
      expect(selected.map((r) => r['id']).toList(), [3, 4]);
    });

    test('schemaFor on a nonexistent table throws NotFoundException', () async {
      if (!await _serverReachable()) {
        print('skip: MONGRELDB_URL not reachable');
        return;
      }
      final db = await _connect();
      addTearDown(db.close);

      expect(
        db.schemaFor('nonexistent_table_xyz'),
        throwsA(isA<NotFoundException>()),
      );
    });

    test('idempotent commit does not duplicate the row', () async {
      if (!await _serverReachable()) {
        print('skip: MONGRELDB_URL not reachable');
        return;
      }
      final db = await _connect();
      addTearDown(db.close);
      final table = 'dart_idem_${DateTime.now().microsecondsSinceEpoch}';

      await db.createTable(table, _columns);

      // Idempotency keys must be unique per run so a stale key from an
      // earlier run can't be replayed against this table.
      final key = 'order-100-create-${DateTime.now().microsecondsSinceEpoch}';

      // First idempotent commit inserts the row.
      final txn = db.beginTransaction();
      txn.put(table, {1: 100, 2: 'order', 3: 1.0});
      await txn.commit(idempotencyKey: key);
      expect(await db.count(table), 1);

      // A second, identical commit with the SAME key must not duplicate it.
      final txn2 = db.beginTransaction();
      txn2.put(table, {1: 100, 2: 'order', 3: 1.0});
      try {
        await txn2.commit(idempotencyKey: key);
      } catch (_) {
        // The daemon may reject the duplicate; the row count is what matters.
      }
      expect(await db.count(table), 1);
    });

    test('retention window keeps older epochs readable via AS OF EPOCH',
        () async {
      if (!await _serverReachable()) {
        print('skip: MONGRELDB_URL not reachable');
        return;
      }
      final db = await _connect();
      addTearDown(db.close);

      // Skip if the connected daemon predates the /history/retention endpoint.
      try {
        await db.historyRetentionEpochs();
      } on NotFoundException {
        print('skip: daemon does not expose /history/retention');
        return;
      }

      // Open a wide window before any writes.
      await db.setHistoryRetentionEpochs(10000);
      final baseEpoch = await db.earliestRetainedEpoch();
      expect(await db.historyRetentionEpochs(), 10000);
      expect(baseEpoch, greaterThan(0));

      final table = 'dart_retention_${DateTime.now().microsecondsSinceEpoch}';
      await db.createTable(table, _columns);
      await db.put(table, {1: 1, 2: 'first', 3: 1.0});
      await db.upsert(
        table,
        {1: 1, 2: 'first', 3: 1.0},
        updateCells: {2: 'second', 3: 2.0},
      );

      // Each committed operation advances the visible epoch by one, so the
      // first insert is visible at baseEpoch + 2 and the update at +3. Probe
      // a small range so the assertion survives minor epoch-alignment shifts.
      String? firstLabel;
      String? laterLabel;
      for (var offset = 1; offset <= 5; offset++) {
        final rows = await db.sql(
          'SELECT label FROM $table AS OF EPOCH ${baseEpoch + offset} '
          'WHERE id = 1',
        );
        if (rows.isNotEmpty) {
          final label = rows.first['label'] as String?;
          firstLabel ??= label;
          if (firstLabel != null && label != firstLabel) {
            laterLabel = label;
            break;
          }
        }
      }
      expect(firstLabel, 'first');
      expect(laterLabel, 'second');
    });

    test('lowering retention advances earliest and drops old epochs', () async {
      if (!await _serverReachable()) {
        print('skip: MONGRELDB_URL not reachable');
        return;
      }
      final db = await _connect();
      addTearDown(db.close);

      // Skip if the connected daemon predates the /history/retention endpoint.
      try {
        await db.historyRetentionEpochs();
      } on NotFoundException {
        print('skip: daemon does not expose /history/retention');
        return;
      }

      // Start with a window large enough to retain the first write.
      await db.setHistoryRetentionEpochs(10);
      final baseEpoch = await db.earliestRetainedEpoch();

      final table =
          'dart_retention_drop_${DateTime.now().microsecondsSinceEpoch}';
      await db.createTable(table, _columns);
      await db.put(table, {1: 1, 2: 'old', 3: 1.0});

      // Tighten the window and advance the current epoch past the old floor.
      await db.setHistoryRetentionEpochs(1);
      for (var i = 0; i < 5; i++) {
        await db.upsert(
          table,
          {1: 1, 2: 'old', 3: 1.0},
          updateCells: {2: 'new$i', 3: i.toDouble()},
        );
      }

      // The floor must have moved forward; history before it is gone.
      final newEarliest = await db.earliestRetainedEpoch();
      expect(newEarliest, greaterThan(baseEpoch));

      expect(
        db.sql(
          'SELECT label FROM $table AS OF EPOCH ${baseEpoch + 2} WHERE id = 1',
        ),
        throwsA(isA<MongrelDBException>()),
      );
    });
  });
}
