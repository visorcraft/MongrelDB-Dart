# Quickstart

This guide walks through installing the MongrelDB Dart client, connecting to a
running `mongreldb-server`, and doing your first round-trip of CRUD and query.

## Prerequisites

- Dart 3.0 or newer (`dart --version`).
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB)
  daemon. The simplest start is the prebuilt Linux binary:

  ```sh
  curl -L -o mongreldb-server \
    https://github.com/visorcraft/MongrelDB/releases/download/v0.55.0/mongreldb-server-linux-x64
  chmod +x mongreldb-server
  ./mongreldb-server ./data --port 8453
  ```

## Install

Add the dependency to `pubspec.yaml`:

```yaml
dependencies:
  mongreldb: ^0.55.0
```

Then fetch packages:

```sh
dart pub get
```

The client has no runtime dependencies beyond the Dart SDK.

## Connect

```dart
import 'package:mongreldb/mongreldb.dart';

Future<void> main() async {
  final db = MongrelDB('http://127.0.0.1:8453');
  try {
    if (await db.health()) {
      print('daemon is healthy');
    }
  } finally {
    db.close();
  }
}
```

## Create a table and insert rows

```dart
await db.createTable('orders', [
  {'id': 1, 'name': 'id',       'ty': 'int64',   'primary_key': true,  'nullable': false},
  {'id': 2, 'name': 'customer', 'ty': 'varchar', 'primary_key': false, 'nullable': false},
  {'id': 3, 'name': 'amount',   'ty': 'float64', 'primary_key': false, 'nullable': false},
  {'id': 4, 'name': 'status',   'ty': 'varchar', 'primary_key': false, 'nullable': false, 'default_value': 'draft'},
  {'id': 5, 'name': 'score',    'ty': 'int64',   'primary_key': false, 'nullable': false, 'default_value': 7},
  {'id': 6, 'name': 'active',   'ty': 'bool',    'primary_key': false, 'nullable': false, 'default_value': true},
  {'id': 7, 'name': 'notes',    'ty': 'varchar', 'primary_key': false, 'nullable': true,  'default_value': null},
  {'id': 8, 'name': 'created',  'ty': 'text',    'primary_key': false, 'nullable': false, 'default_expr': 'now'},
]);

await db.put('orders', {1: 1, 2: 'Alice', 3: 99.50});
await db.put('orders', {1: 2, 2: 'Bob',   3: 150.00});

print(await db.count('orders')); // 2
```

### Column-spec keys

Each entry in the `columns` list is a `Map<String, Object?>` whose keys map
straight onto the daemon's `KitColumnDef`. The Dart client passes the map
through verbatim — there is no schema validation on the client side, so
unknown keys are forwarded and rejected by the daemon.

| Key | Type | Description |
|---|---|---|
| `id` | `int` | Stable column id used in cell maps (`{1: ..., 2: ...}`). |
| `name` | `String` | Column name, referenced by SQL and the schema catalog. |
| `ty` | `String` | Engine type id (e.g. `int64`, `varchar`, `float64`, `enum`). |
| `primary_key` | `bool` | Mark this column as the table's primary key. |
| `nullable` | `bool` | Allow `NULL` cells (default: false). |
| `enum_variants` | `List<String>` | When `ty == 'enum'`, the allowed string values. Required for enums; rejected if empty. |
| `default_value` | JSON scalar | Static default used when a row omits the cell. Can be a string, integer, boolean, or explicit `null`. |
| `default_expr` | `String` | Dynamic default: `'now'` or `'uuid'`. This is a separate key; do not mix it with `default_value`. |
| `auto_increment` | `bool` | Assign monotonic ids on insert. |
| `encrypted` / `encrypted_indexable` | `bool` | Page-level AES-GCM encryption for at-rest columns. |

Check constraints (regex, range, equality) live on the table-level
`constraints` key alongside `uniques` and `foreign_keys`; they are sent as
the optional named `constraints` argument to `createTable`.

```dart
await db.createTable('scores', columns, constraints: {
  'checks': [{'id': 1, 'name': 'score_nonneg', 'expr': {'Ge': [{'Col': 3}, {'Lit': {'Float64': 0.0}}]}}],
});
```

## Run a query

```dart
final rows = await db.query('orders')
    .where('pk', {'value': 1})
    .execute();
```

## History retention

MongrelDB keeps a rolling window of prior commit epochs. You can read old
versions of a table with `AS OF EPOCH` SQL, as long as the epoch is still
inside the configured window.

```dart
// Keep the last 1000 commit epochs readable.
await db.setHistoryRetentionEpochs(1000);

print(await db.historyRetentionEpochs()); // 1000
print(await db.earliestRetainedEpoch());  // oldest readable epoch

// Read the table as it was at an earlier epoch.
final oldRows = await db.sql(
  'SELECT * FROM orders AS OF EPOCH 42 WHERE id = 1',
);
```

Raising the window only protects future history; epochs that already fell out
of the previous window cannot be restored. Lowering the window moves the
floor forward, so older `AS OF EPOCH` queries will fail once their epoch is
no longer retained.

## Next steps

- [Transactions](transactions.md) for atomic multi-op commits.
- [Queries](queries.md) for the native index condition API.
- [SQL](sql.md) for DataFusion-backed ad-hoc SQL.
- [Auth](auth.md) for Bearer and Basic authentication.
- [Errors](errors.md) for the exception hierarchy.
