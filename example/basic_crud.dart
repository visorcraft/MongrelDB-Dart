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
    ]);

    await db.put('demo', {1: 1, 2: 'first', 3: 10.0});
    await db.put('demo', {1: 2, 2: 'second', 3: 20.0});
    print('count: ${await db.count('demo')}');

    // Column-level constraints: enum_variants fixes the allowed values and
    // default_value fills the cell when a row omits it. The daemon rejects
    // any insert whose value is outside the variant set with a 4xx error.
    await db.createTable('demo_enum', [
      {
        'id': 1,
        'name': 'id',
        'ty': 'int64',
        'primary_key': true,
        'nullable': false,
      },
      {
        'id': 2,
        'name': 'status',
        'ty': 'enum',
        // Order is preserved; the first variant is used when default_value
        // is omitted, so passing it explicitly is the recommended form.
        'enum_variants': <String>['new', 'active', 'archived'],
        'default_value': 'new',
      },
    ]);

    // Valid insert: 'new' is in enum_variants, so the row is accepted and
    // the default_value field is irrelevant here because the caller sets
    // column 2 explicitly.
    await db.put('demo_enum', {1: 1, 2: 'new'});
    print('demo_enum count: ${await db.count('demo_enum')}');

    // Invalid insert: 'pending' is NOT in enum_variants. The daemon returns
    // a constraint error (HTTP 409 → ConstraintException). We catch and
    // print it so the run still exits cleanly.
    try {
      await db.put('demo_enum', {1: 2, 2: 'pending'});
    } on MongrelDBException catch (e) {
      print('expected rejection: ${e.runtimeType}: ${e.message}');
    }

    // Upsert: change the second row.
    await db.upsert(
      'demo',
      {1: 2, 2: 'second', 3: 42.0},
      updateCells: {3: 42.0},
    );

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
