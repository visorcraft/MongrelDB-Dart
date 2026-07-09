// Example: basic CRUD operations with the MongrelDB Dart client.
//
// Run (from the repo root, with the client on the package path):
//
//   dart run examples/basic_crud.dart
//
// or, with a pubspec depending on `mongreldb`, under a `dart run` entry.
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, inserts three rows, counts them, queries all rows,
// upserts (updates) one row by primary key, deletes one row, then drops
// the table. Progress is printed at every step.

import 'dart:io';

import 'package:mongreldb/mongreldb.dart';

const String dbUrl = 'http://127.0.0.1:8453';
const String table = 'example_crud';

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

void printResult(String label, List<Map<String, dynamic>> rows) {
  print('  $label: ${rows.length} rows');
  for (final r in rows) {
    print('    { $r }');
  }
}

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

    // 3. Insert three rows.
    await db.put(table, row(1, 'Alice', 95.5));
    await db.put(table, row(2, 'Bob', 82.0));
    await db.put(table, row(3, 'Carol', 78.3));
    print('Inserted 3 rows');

    // 4. Count.
    print('Total rows: ${await db.count(table)}');

    // 5. Query all rows (no conditions, no projection, no limit).
    final allRows = await db.query(table).execute();
    printResult('all rows', allRows);

    // 6. Upsert (update) Alice's score. updateCells supplies the values
    //    written on a primary-key conflict.
    await db.upsert(
      table,
      row(1, 'Alice', 100.0),
      updateCells: {2: 'Alice', 3: 100.0},
    );
    print('Upserted Alice\'s score to 100.0');
    print('Total rows after upsert: ${await db.count(table)}');

    // 7. Delete Carol (primary key 3).
    await db.deleteByPk(table, 3);
    print('Deleted Carol; remaining rows: ${await db.count(table)}');

    // 8. Cleanup.
    await db.dropTable(table);
    print('Dropped table $table');
  } catch (e) {
    stderr.writeln('error: $e');
    exitCode = 1;
  } finally {
    db.close();
  }
}
