# Quickstart

This guide walks through installing the MongrelDB Dart client, connecting to a
running `mongreldb-server`, and doing your first round-trip of CRUD and query.

## Prerequisites

- Dart 3.0 or newer (`dart --version`).
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB)
  daemon. The simplest start is the prebuilt Linux binary:

  ```sh
  curl -L -o mongreldb-server \
    https://github.com/visorcraft/MongrelDB/releases/download/v0.46.2/mongreldb-server-linux-x64
  chmod +x mongreldb-server
  ./mongreldb-server ./data --port 8453
  ```

## Install

Add the dependency to `pubspec.yaml`:

```yaml
dependencies:
  mongreldb: ^0.1.0
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
| `default_value` | `String` | Default used when a row omits the cell. The server also accepts `default_expr` (e.g. `'now'`, `'uuid'`); `default_value` is the legacy alias. |
| `auto_increment` | `bool` | Assign monotonic ids on insert. |
| `encrypted` / `encrypted_indexable` | `bool` | Page-level AES-GCM encryption for at-rest columns. |

Check constraints (regex, range, equality) live on the table-level
`constraints` key alongside `uniques` and `foreign_keys`; they are sent as
part of the Kit create-table request but the Dart client's `createTable`
helper takes only the `columns` list, so callers post the constraints
payload through `db.post('/kit/create_table', ...)` directly.

## Run a query

```dart
final rows = await db.query('orders')
    .where('pk', {'value': 1})
    .execute();
```

## Next steps

- [Transactions](transactions.md) for atomic multi-op commits.
- [Queries](queries.md) for the native index condition API.
- [SQL](sql.md) for DataFusion-backed ad-hoc SQL.
- [Auth](auth.md) for Bearer and Basic authentication.
- [Errors](errors.md) for the exception hierarchy.
