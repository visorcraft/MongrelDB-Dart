// Example: atomic batch transactions with an idempotent retry in Dart.
//
// Run (from the repo root, with the client on the package path):
//
//   dart run examples/transactions.dart
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, opens one transaction, stages three puts, and commits
// them atomically. It then verifies the row count. Finally it stages a
// fourth put and commits it twice with the SAME idempotency key: the
// daemon replays the first commit's result so the second commit is a
// no-op. The table is dropped at the end.

import 'dart:io';

import 'package:mongreldb/mongreldb.dart';

const String dbUrl = 'http://127.0.0.1:8453';
const String table = 'example_txn';
const String txnKey = 'example-txn-key';

// Column schema shared across all examples:
//   col 1 = id (int64, primary key)
//   col 2 = name (varchar)
//   col 3 = score (float64)
Map<String, Object?> column(int id, String name, String ty,
        {required bool primaryKey}) =>
    {
      'id': id,
      'name': name,
      'ty': ty,
      'primary_key': primaryKey,
      'nullable': false,
    };

// Build a three-cell input row: column id -> value.
Map<int, Object?> row(int id, String name, double score) =>
    {1: id, 2: name, 3: score};

Future<void> main() async {
  final db = MongrelDB(dbUrl);
  try {
    // 1. Health check; bail out if the daemon is unreachable.
    if (!await db.health()) {
      stderr.writeln('daemon not reachable at $dbUrl');
      exitCode = 1;
      return;
    }
    print('Connected to MongrelDB');

    // 2. Create the table.
    final tableId = await db.createTable(table, [
      column(1, 'id', 'int64', primaryKey: true),
      column(2, 'name', 'varchar', primaryKey: false),
      column(3, 'score', 'float64', primaryKey: false),
    ]);
    print('Created table $table (id $tableId)');

    // 3. Stage three puts and commit them atomically.
    final txn1 = db.beginTransaction();
    txn1.put(table, row(1, 'Alice', 95.5));
    txn1.put(table, row(2, 'Bob', 82.0));
    txn1.put(table, row(3, 'Carol', 78.3));
    print('Staged ${txn1.length} ops');
    await txn1.commit();
    print('Committed transaction with 3 puts');

    // 4. Verify the row count.
    print('Total rows after commit: ${await db.count(table)}');

    // 5. Idempotent retry: stage a fourth put and commit twice with the
    //    same idempotency key. The second commit is replayed as a no-op
    //    (a fresh Transaction must be used, but the same key dedupes it).
    final txn2a = db.beginTransaction();
    txn2a.put(table, row(4, 'Dave', 60.0));
    await txn2a.commit(idempotencyKey: txnKey);
    print('Committed 4th put with idempotency key $txnKey');

    final txn2b = db.beginTransaction();
    txn2b.put(table, row(4, 'Dave', 60.0));
    await txn2b.commit(idempotencyKey: txnKey);
    print('Recommitted with same key (idempotent replay)');

    print('Total rows after idempotent retry: ${await db.count(table)}');

    // 6. Cleanup.
    await db.dropTable(table);
    print('Dropped table $table');
  } catch (e) {
    stderr.writeln('error: $e');
    exitCode = 1;
  } finally {
    db.close();
  }
}
