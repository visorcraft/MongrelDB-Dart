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
