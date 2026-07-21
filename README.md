<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Dart Client</h1>

<p align="center">
  <b>Pure Dart client for MongrelDB, embedded and server database with SQL, vector search, full-text search, history retention, and AI-native retrieval.</b>
</p>

<p align="center">
  <a href="https://pub.dev/packages/mongreldb"><img src="https://img.shields.io/pub/v/mongreldb.svg" alt="Pub" /></a>
  <a href="https://dart.dev/"><img src="https://img.shields.io/badge/Dart-%3E%3D3.0-0175C2.svg" alt="Dart" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Dart client | `mongreldb` | `dart pub add mongreldb` |

## Requirements

- **Dart 3.0 or newer** (Flutter 3.10+ supported, no Flutter-specific deps)
- The Dart SDK standard library only (`dart:io`, `dart:convert`). No external runtime dependencies.
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon.

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put`, `upsert` (insert-or-update on PK conflict), `delete` by row id or primary key, with idempotency keys for safe retries.
- **Fluent query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match.
- **Idempotent batch transactions**, all operations staged locally and committed atomically, with the engine enforcing unique, foreign key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, multi-statement execution, and the `mongreldb_fts_rank` relevance-scoring UDF.
- **Schema management**: typed table creation, full schema catalog, and per-table descriptors.
- **History retention**: configure how many prior commit epochs remain readable through `AS OF EPOCH` time-travel SQL, and query the current window.
- **Maintenance**: compaction (all tables or per-table).
- **Pluggable HTTP transport**: pooled `dart:io HttpClient` by default, and an injectable `HttpTransport` for custom adapters.
- **Typed exception hierarchy**: `AuthException` (401/403), `NotFoundException` (404), `ConstraintException` (409, with error code and op index), `ConnectionException` (network), and `QueryException` (everything else).
- **Robust JSON handling**: malformed UTF-8 is substituted rather than rejecting the whole request; NaN and Infinity raise a clear `QueryException` instead of corrupting data.

## Examples

Runnable, commented examples live in [`example/`](example):

- [Basic CRUD](example/basic_crud.dart), connect, create a table, insert, query, count.

## Quick Example

```dart
import 'package:mongreldb/mongreldb.dart';

Future<void> main() async {
  // Connect to a running mongreldb-server daemon.
  final db = MongrelDB('http://127.0.0.1:8453');

  try {
    // Create a table. Column specs are plain maps; enum_variants pins a
    // column to a fixed string set and scalar default_value supplies the value
    // when the row omits the cell. Table checks use the optional constraints
    // argument.
    await db.createTable('orders', [
      {'id': 1, 'name': 'id',       'ty': 'int64',   'primary_key': true,  'nullable': false},
      {'id': 2, 'name': 'customer', 'ty': 'varchar', 'primary_key': false, 'nullable': false},
      {'id': 3, 'name': 'amount',   'ty': 'float64', 'primary_key': false, 'nullable': false},
      {
        'id': 4,
        'name': 'status',
        'ty': 'enum',
        'enum_variants': <String>['pending', 'paid', 'refunded'],
        'default_value': 'pending', // or default_expr: 'now' / 'uuid'
      },
    ], constraints: {
      'checks': [{'id': 1, 'name': 'amount_nonneg', 'expr': {'Ge': [{'Col': 3}, {'Lit': {'Float64': 0.0}}]}}],
    });

    // Insert rows.
    await db.put('orders', {1: 1, 2: 'Alice', 3: 99.50});
    await db.put('orders', {1: 2, 2: 'Bob',   3: 150.00});

    // Upsert (insert or update on PK conflict).
    await db.upsert('orders', {1: 1, 2: 'Alice', 3: 120.00},
        updateCells: {3: 120.00});

    // Query with a native index condition (learned-range index).
    final rows = await db
        .query('orders')
        .where('range', {'column': 3, 'min': 100.0})
        .projection([1, 2])
        .limit(100)
        .execute();

    print(await db.count('orders')); // 2

    // Run SQL.
    await db.sql("UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'");
  } finally {
    db.close();
  }
}
```

## Auth

```dart
// Bearer token (--auth-token mode).
final db = MongrelDB('http://127.0.0.1:8453', token: 'my-secret-token');

// HTTP Basic (--auth-users mode).
final db = MongrelDB('http://127.0.0.1:8453', username: 'admin', password: 's3cret');
```

## Transactions

Operations are staged locally and committed atomically. The engine enforces
unique, foreign key, and check constraints at commit time.

```dart
final txn = db.beginTransaction();
txn.put('orders', {1: 10, 2: 'Dave', 3: 50.0});
txn.put('orders', {1: 11, 2: 'Eve',  3: 75.0});
txn.deleteByPk('orders', 2);

try {
  await txn.commit(); // atomic, all or nothing
  print('Staged ${txn.length} operations');
} on ConstraintException catch (e) {
  print('Constraint violated: ${e.errorCode} - ${e.message}');
  txn.rollback();
}

// Idempotent commit, safe to retry; daemon returns the original response.
final txn2 = db.beginTransaction();
txn2.put('orders', {1: 20, 2: 'Frank', 3: 100.00});
await txn2.commit(idempotencyKey: 'order-20-create');
```

## Query builder

Conditions push down to the engine's specialized indexes. The builder accepts
friendly aliases that are translated to the server's on-wire keys: `column`
(to `column_id`), `min`/`max` (to `lo`/`hi`). The canonical keys are also
accepted directly.

```dart
// Bitmap equality (low-cardinality columns).
await db.query('orders').where('bitmap_eq', {'column': 2, 'value': 'Alice'}).execute();

// Range query (learned-range index).
await db.query('orders')
    .where('range', {'column': 3, 'min': 50.0, 'max': 150.0})
    .limit(100).execute();

// Full-text search (FM-index).
await db.query('documents')
    .where('fm_contains', {'column': 2, 'pattern': 'database performance'})
    .limit(10).execute();

// Vector similarity search (HNSW).
await db.query('embeddings')
    .where('ann', {'column': 2, 'query': [0.1, 0.2, 0.3], 'k': 10})
    .execute();

// Check whether a result was capped by the limit.
final q = db.query('orders').where('range', {'column': 3, 'min': 0}).limit(100);
final rows = await q.execute();
if (q.truncated) {
  // result set hit the limit; more matches exist on the server.
}
```

## SQL

```dart
await db.sql("INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)");
await db.sql("CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500");

// Recursive CTEs and window functions.
await db.sql("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r");
await db.sql("SELECT id, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) FROM orders");
```

## ANN index backends

The engine's `ann` index is swappable across three backends - `hnsw` (the default), `diskann`, and `ivf` - selected with the `algorithm` option. Quantization is independently configurable: `dense`, `binary_sign`, or `product` (product quantization, with `num_subvectors`, `bits_per_subvector`, `pq_training_samples`, `pq_seed`, and `pq_rerank_factor`). These are ordinary DDL strings run through `sql`, so no client changes are needed.

```dart
// DiskANN (on-disk graph, terabyte-scale)
await db.sql("CREATE INDEX orders_emb_diskann ON orders USING ann (embedding) WITH (algorithm = 'diskann', quantization = 'dense', diskann_l = 50, diskann_r = 64, beam_width = 8)");

// IVF with product quantization (clustered, memory-frugal)
await db.sql("CREATE INDEX orders_emb_ivf ON orders USING ann (embedding) WITH (algorithm = 'ivf', quantization = 'product', nlist = 1024, nprobe = 16, num_subvectors = 16, bits_per_subvector = 8)");

// HNSW with product quantization (recall-tuned)
await db.sql("CREATE INDEX orders_emb_hnsw_pq ON orders USING ann (embedding) WITH (algorithm = 'hnsw', quantization = 'product', m = 16, ef_construction = 200, ef_search = 50, num_subvectors = 32, pq_training_samples = 50000, pq_rerank_factor = 8)");
```


## User and role management

User and role administration is done through SQL against the `/sql` endpoint.
The client ships typed helpers for the common verbs, which quote identifiers
and escape literals so caller-supplied names are safe to interpolate.

```dart
await db.sql('CREATE USER "admin" WITH PASSWORD \'s3cret-pw\'');
await db.sql('ALTER USER "admin" ADMIN');

await db.sql('CREATE ROLE "analyst"');
await db.sql('GRANT SELECT ON orders TO "analyst"');
await db.sql('GRANT "analyst" TO "alice"');
```

## Error handling

```dart
import 'package:mongreldb/mongreldb.dart';

try {
  await db.put('orders', {1: 1}); // duplicate PK
} on ConstraintException catch (e) {
  print('Constraint: ${e.errorCode}'); // UNIQUE_VIOLATION
} on AuthException catch (e) {
  print('Not authorized: ${e.message}');
} on NotFoundException catch (e) {
  print('Not found: ${e.message}');
} on ConnectionException catch (e) {
  print("Can't reach daemon: ${e.message}");
} on MongrelDBException catch (e) {
  print('Error: ${e.message}');
}
```

## API reference

### `MongrelDB` class

| Method | Description |
|---|---|
| `health()` | Check daemon health |
| `tableNames()` | List table names |
| `createTable(name, columns, {constraints, indexes})` | Create a table with optional constraints and all index definitions |
| `dropTable(name)` | Drop a table |
| `count(table)` | Row count |
| `put(table, cells, {idempotencyKey})` | Insert a row |
| `upsert(table, cells, {updateCells, idempotencyKey})` | Upsert a row |
| `delete(table, rowId)` | Delete by row ID |
| `deleteByPk(table, pk)` | Delete by primary key |
| `query(table)` | Start a native query |
| `sql(sql)` | Execute SQL |
| `schema()` | Full schema catalog |
| `schemaFor(table)` | Single table schema |
| `compact()` | Compact all tables |
| `historyRetention()` | Full retention state as `{history_retention_epochs, earliest_retained_epoch}` |
| `historyRetentionEpochs()` | Current number of retained commit epochs |
| `earliestRetainedEpoch()` | Oldest epoch still readable via `AS OF EPOCH` |
| `setHistoryRetentionEpochs(epochs)` | Set the retention window |
| `beginTransaction()` | Start a batch |
| `close()` | Release pooled HTTP connections |

### `QueryBuilder` class

| Method | Description |
|---|---|
| `where(type, params)` | Add a native condition |
| `projection(columnIds)` | Set column projection |
| `limit(limit)` | Set row limit |
| `offset(offset)` | Skip matching rows before the limit |
| `build()` | Build the request payload |
| `execute()` | Run the query |
| `truncated` | Whether the last result was capped by the limit |

### `Transaction` class

| Method | Description |
|---|---|
| `put(table, cells)` | Stage an insert |
| `upsert(table, cells, {updateCells})` | Stage an upsert |
| `delete(table, rowId)` | Stage a delete |
| `deleteByPk(table, pk)` | Stage a delete by PK |
| `commit({idempotencyKey})` | Commit atomically |
| `rollback()` | Discard all operations |
| `length` | Number of staged operations |

## Building and testing

The test suite uses the `test` package and is offline-safe: it self-skips when
no `mongreldb-server` daemon is reachable.

```sh
dart pub get
dart test           # runs the suite (skips live tests offline)
```

For the live round-trip suite, start a daemon and point the tests at it:

```sh
MONGRELDB_URL=http://127.0.0.1:8453 dart test
```

Static analysis and formatting:

```sh
dart analyze --fatal-infos
dart format --set-exit-if-changed lib test
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change, the suite must stay green.
3. Keep Dart 3.0 as the minimum supported version.
4. Match the existing style: strict-casts and strict-inference enabled,
   `dart format` formatting, and `lowerCamelCase` for members.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full guide.

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
