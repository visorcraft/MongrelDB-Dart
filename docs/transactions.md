# Transactions

The MongrelDB daemon commits batched operations atomically. The Dart client
mirrors that with a staging buffer: every `put`, `upsert`, and `delete` is held
locally until you call `commit()`, at which point the whole batch is flushed in
a single `/kit/txn` request. Unique, foreign key, and check constraints are
enforced by the engine at commit time, so either every operation lands or none.

## Basic commit

```dart
final txn = db.beginTransaction();
txn.put('orders', {1: 10, 2: 'Dave', 3: 50.0});
txn.put('orders', {1: 11, 2: 'Eve',  3: 75.0});
txn.deleteByPk('orders', 2);
final results = await txn.commit(); // atomic: all or nothing
```

`commit()` returns a list of per-operation result objects. Each entry reflects
the `action` the engine took (`inserted`, `updated`, `unchanged`, etc.).

## Rollback

Discard everything that has not been committed:

```dart
final txn = db.beginTransaction();
txn.put('orders', {1: 99, 2: 'temp', 3: 0.0});
txn.rollback(); // nothing is sent to the daemon
```

Calling `commit()` twice, or `rollback()` after `commit()`, raises a
`StateError`.

## Idempotent commits

Pass an idempotency key to make a commit safe to retry. If the daemon sees the
same key again (even after a crash), it returns the original response instead of
replaying the work:

```dart
await txn.commit(idempotencyKey: 'order-20-create');
```

Keys are opaque, caller-supplied strings. The client does not derive or store
them.

## Constraint handling

If a staged operation violates a constraint, the engine rejects the whole batch
and the client raises a [ConstraintException] with the server's `errorCode`
(for example, `UNIQUE_VIOLATION`) and, when reported, the `opIndex` of the
offending operation:

```dart
try {
  await txn.commit();
} on ConstraintException catch (e) {
  print('Constraint violated: ${e.errorCode} (op ${e.opIndex})');
}
```

## Supported operations

| Method | Description |
|---|---|
| `put(table, cells)` | Stage an insert |
| `upsert(table, cells, updateCells: ...)` | Stage an insert-or-update on PK conflict |
| `delete(table, rowId)` | Stage a delete by internal row id |
| `deleteByPk(table, pk)` | Stage a delete by primary key value |
| `commit()` | Flush the batch atomically |
| `rollback()` | Discard the staged batch |
| `length` | Number of staged operations |
