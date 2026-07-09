// Example: native query builder (range + primary-key lookups) in Dart.
//
// Run (from the repo root, with the client on the package path):
//
//   dart run examples/query_builder.dart
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, loads five rows with varying scores, then runs two
// native queries: a range scan over score in [60, 90], and an exact
// primary-key lookup for id == 4. Results are printed, then the table is
// dropped.

import 'dart:io';

import 'package:mongreldb/mongreldb.dart';

const String dbUrl = 'http://127.0.0.1:8453';
const String table = 'example_query';

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

    // 3. Load five rows with varying scores.
    await db.put(table, row(1, 'Alice', 40.0));
    await db.put(table, row(2, 'Bob', 65.0));
    await db.put(table, row(3, 'Carol', 82.0));
    await db.put(table, row(4, 'Dave', 91.0));
    await db.put(table, row(5, 'Eve', 12.5));
    print('Inserted 5 rows');

    // 4. Range query: 60 <= score <= 90 (both inclusive). The "min"/"max"
    //    aliases map to the server's lo/hi keys. The "score" column is
    //    float64, so use the range_f64 condition (plain "range" expects an
    //    i64 bound and rejects floats); range_f64 also requires the
    //    inclusivity flags (min_inclusive/max_inclusive -> lo_inclusive/
    //    hi_inclusive).
    final rangeRows = await db
        .query(table)
        .where('range_f64', {
          'column': 3,
          'min': 60.0,
          'max': 90.0,
          'min_inclusive': true,
          'max_inclusive': true,
        })
        .execute();
    printResult('range [60, 90] on score', rangeRows);

    // 5. Primary-key lookup: id == 4 (Dave).
    final pkRows = await db
        .query(table)
        .where('pk', {'value': 4})
        .execute();
    printResult('pk == 4', pkRows);

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
