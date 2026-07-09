/// Batch transaction builder for atomic multi-operation commits.
///
/// Operations are staged in an in-memory buffer and flushed in a single
/// `/kit/txn` request on [commit]. The engine enforces unique, foreign key,
/// and check constraints atomically, so either every staged op lands or none.
///
/// ```dart
/// final txn = db.beginTransaction();
/// txn.put('orders', {1: 1, 2: 'Alice', 3: 99.5});
/// txn.put('orders', {1: 2, 2: 'Bob', 3: 150.0});
/// txn.deleteByPk('orders', 99);
/// final results = await txn.commit(); // atomic
/// ```
library;

import 'mongreldb.dart';

/// Staging buffer for a batch transaction.
class Transaction {
  final MongrelDB _client;
  final List<Map<String, dynamic>> _ops = [];
  bool _committed = false;

  Transaction(this._client);

  /// Stage an insert.
  Transaction put(
    String table,
    Map<int, Object?> cells, {
    bool returning = false,
  }) {
    _ops.add({
      'put': {
        'table': table,
        'cells': _cellsToFlat(cells),
        'returning': returning,
      },
    });
    return this;
  }

  /// Stage an upsert (insert or update on PK conflict).
  Transaction upsert(
    String table,
    Map<int, Object?> cells, {
    Map<int, Object?>? updateCells,
    bool returning = false,
  }) {
    final op = <String, dynamic>{
      'table': table,
      'cells': _cellsToFlat(cells),
      'returning': returning,
    };
    if (updateCells != null) {
      op['update_cells'] = _cellsToFlat(updateCells);
    }
    _ops.add({'upsert': op});
    return this;
  }

  /// Stage a delete by internal row id.
  Transaction delete(String table, int rowId) {
    _ops.add({
      'delete': {'table': table, 'row_id': rowId},
    });
    return this;
  }

  /// Stage a delete by primary key value.
  Transaction deleteByPk(String table, Object? pk) {
    _ops.add({
      'delete_by_pk': {'table': table, 'pk': pk},
    });
    return this;
  }

  /// Number of staged operations.
  int get length => _ops.length;

  /// Commit all staged operations atomically.
  ///
  /// Returns per-operation results. Throws [ConstraintException] if a
  /// constraint was violated (the engine rolls back every op).
  Future<List<Map<String, dynamic>>> commit({String? idempotencyKey}) async {
    if (_committed) {
      throw StateError('Transaction already committed');
    }
    if (_ops.isEmpty) {
      _committed = true;
      return const [];
    }
    final payload = <String, dynamic>{
      'ops': List<Map<String, dynamic>>.from(_ops),
    };
    if (idempotencyKey != null) {
      payload['idempotency_key'] = idempotencyKey;
    }
    final r = await _client.post('/kit/txn', payload);
    _committed = true;
    final data = r.json() as Map<String, dynamic>? ?? const {};
    final results = data['results'];
    if (results is List) {
      return results
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    return const [];
  }

  /// Discard all staged operations.
  void rollback() {
    if (_committed) {
      throw StateError('Cannot rollback a committed transaction');
    }
    _ops.clear();
  }

  /// Flatten `{colId: value}` into `[colId, value, ...]`.
  List<Object?> _cellsToFlat(Map<int, Object?> cells) {
    final flat = <Object?>[];
    final keys = cells.keys.toList()..sort();
    for (final colId in keys) {
      flat.add(colId);
      flat.add(cells[colId]);
    }
    return flat;
  }
}
