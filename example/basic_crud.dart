// Basic CRUD example for the MongrelDB Dart client.
//
// Run with:
//   dart pub get
//   dart run example/basic_crud.dart
//
// Requires a running mongreldb-server on http://127.0.0.1:8453.
import 'package:mongreldb/mongreldb.dart';

Future<void> main() async {
  final db = MongrelDB('http://127.0.0.1:8453');
  try {
    print('health: ${await db.health()}');

    // Drop a leftover table if present, then create a fresh one.
    try {
      await db.dropTable('demo');
    } on NotFoundException {
      // expected on first run
    }

    await db.createTable('demo', [
      {'id': 1, 'name': 'id', 'ty': 'int64', 'primary_key': true, 'nullable': false},
      {'id': 2, 'name': 'label', 'ty': 'varchar', 'primary_key': false, 'nullable': false},
      {'id': 3, 'name': 'amount', 'ty': 'float64', 'primary_key': false, 'nullable': false},
    ]);

    await db.put('demo', {1: 1, 2: 'first', 3: 10.0});
    await db.put('demo', {1: 2, 2: 'second', 3: 20.0});
    print('count: ${await db.count('demo')}');

    // Upsert: change the second row.
    await db.upsert('demo', {1: 2, 2: 'second', 3: 42.0}, updateCells: {3: 42.0});

    // Read it back via the query builder.
    final rows = await db.query('demo').where('pk', {'value': 2}).execute();
    print('row 2: $rows');

    // Batch delete in a transaction.
    final txn = db.beginTransaction();
    txn.deleteByPk('demo', 1);
    txn.deleteByPk('demo', 2);
    await txn.commit();
    print('count after txn: ${await db.count('demo')}');
  } finally {
    db.close();
  }
}
