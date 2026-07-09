/// Fluent query builder for the Kit `/kit/query` endpoint.
///
/// Conditions push down to the engine's specialized indexes for sub-millisecond
/// lookups. Friendly aliases are translated to the server's on-wire keys before
/// the request leaves the client:
/// - `column` -> `column_id`
/// - `min`/`max` -> `lo`/`hi`
/// - `min_inclusive`/`max_inclusive` -> `lo_inclusive`/`hi_inclusive`
///
/// The server's canonical keys are also accepted directly.
library;

import 'mongreldb.dart';

/// Chainable builder for a native MongrelDB query.
class QueryBuilder {
  final MongrelDB _client;
  final String _table;

  final List<Map<String, dynamic>> _conditions = [];
  List<int>? _projection;
  int? _limit;

  bool _lastTruncated = false;

  QueryBuilder(this._client, this._table);

  /// Add a native condition.
  ///
  /// Supported types: `pk`, `bitmap_eq`, `bitmap_in`, `range`, `range_f64`,
  /// `is_null`, `is_not_null`, `fm_contains`, `fm_contains_all`, `ann`,
  /// `sparse_match`, `min_hash_similar`.
  QueryBuilder where(String type, Map<String, Object?> params) {
    _conditions.add({type: _normalizeCondition(type, params)});
    return this;
  }

  /// Set the column projection (column ids to return).
  QueryBuilder projection(List<int> columnIds) {
    _projection = List<int>.from(columnIds);
    return this;
  }

  /// Set the row limit.
  QueryBuilder limit(int limit) {
    _limit = limit;
    return this;
  }

  /// Build the outgoing `/kit/query` payload.
  Map<String, dynamic> build() {
    final payload = <String, dynamic>{'table': _table};
    if (_conditions.isNotEmpty) {
      payload['conditions'] = List<Map<String, dynamic>>.from(_conditions);
    }
    if (_projection != null) {
      payload['projection'] = _projection;
    }
    if (_limit != null) {
      payload['limit'] = _limit;
    }
    return payload;
  }

  /// Execute the query and return matching rows.
  Future<List<Map<String, dynamic>>> execute() async {
    final r = await _client.post('/kit/query', build());
    final data = r.json() as Map<String, dynamic>? ?? const {};
    _lastTruncated = (data['truncated'] as bool?) ?? false;
    final rows = data['rows'];
    if (rows is List) {
      return rows
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    return const [];
  }

  /// Whether the last [execute] result was capped by the [limit].
  bool get truncated => _lastTruncated;

  /// Translate friendly aliases to the server's canonical wire keys.
  Map<String, dynamic> _normalizeCondition(
    String type,
    Map<String, Object?> params,
  ) {
    const aliases = <String, String>{
      'column': 'column_id',
      'min': 'lo',
      'max': 'hi',
      'min_inclusive': 'lo_inclusive',
      'max_inclusive': 'hi_inclusive',
    };
    final normalized = <String, dynamic>{};
    for (final entry in params.entries) {
      String key = entry.key;
      if (type == 'fm_contains' || type == 'fm_contains_all') {
        if (key == 'value') {
          key = 'pattern';
        }
      }
      normalized[aliases[key] ?? key] = entry.value;
    }
    return normalized;
  }
}
