/// Fluent builder for POST `/kit/search` — multi-retriever hybrid search.
library;

import 'mongreldb.dart';

/// Chainable hybrid search builder (retrievers + RRF fusion + optional rerank).
class SearchBuilder {
  final MongrelDB _client;
  final String _table;

  final List<Map<String, dynamic>> _must = [];
  final List<Map<String, dynamic>> _retrievers = [];
  Map<String, dynamic> _fusion = {
    'reciprocal_rank': {'constant': 60},
  };
  Map<String, dynamic>? _rerank;
  int _limit = 10;
  List<int>? _projection;
  bool _explain = false;
  String? _cursor;

  SearchBuilder(this._client, this._table);

  /// Hard filter (same condition shapes as [QueryBuilder.where]).
  SearchBuilder must(String type, Map<String, Object?> params) {
    _must.add({type: _normalizeCondition(type, params)});
    return this;
  }

  SearchBuilder annRetriever(
    String name,
    int columnId,
    List<double> query, {
    int k = 64,
    double weight = 1.0,
  }) {
    _retrievers.add({
      'name': name,
      'weight': weight,
      'ann': {
        'column_id': columnId,
        'query': query,
        'k': k,
      },
    });
    return this;
  }

  /// [terms] is a list of `[tokenId, weight]` pairs.
  SearchBuilder sparseRetriever(
    String name,
    int columnId,
    List<List<num>> terms, {
    int k = 64,
    double weight = 1.0,
  }) {
    final pairs = terms.map((t) => [t[0].toInt(), t[1].toDouble()]).toList();
    _retrievers.add({
      'name': name,
      'weight': weight,
      'sparse': {
        'column_id': columnId,
        'query': pairs,
        'k': k,
      },
    });
    return this;
  }

  SearchBuilder minHashRetriever(
    String name,
    int columnId,
    List<String> members, {
    int k = 64,
    double weight = 1.0,
  }) {
    _retrievers.add({
      'name': name,
      'weight': weight,
      'min_hash': {
        'column_id': columnId,
        'members': members,
        'k': k,
      },
    });
    return this;
  }

  SearchBuilder fusion({int constant = 60}) {
    _fusion = {
      'reciprocal_rank': {'constant': constant < 1 ? 1 : constant},
    };
    return this;
  }

  /// [metric] is `cosine`, `dot_product`, or `euclidean`.
  SearchBuilder exactRerank(
    int embeddingColumn,
    List<double> query, {
    String metric = 'cosine',
    int candidateLimit = 64,
    double weight = 1.0,
  }) {
    _rerank = {
      'exact_vector': {
        'embedding_column': embeddingColumn,
        'query': query,
        'metric': metric,
        'candidate_limit': candidateLimit,
        'weight': weight,
      },
    };
    return this;
  }

  SearchBuilder limit(int limit) {
    _limit = limit;
    return this;
  }

  SearchBuilder projection(List<int> columnIds) {
    _projection = List<int>.from(columnIds);
    return this;
  }

  SearchBuilder explain([bool on = true]) {
    _explain = on;
    return this;
  }

  SearchBuilder cursor(String? cursor) {
    _cursor = cursor;
    return this;
  }

  Map<String, dynamic> build() {
    if (_retrievers.isEmpty) {
      throw ArgumentError('search requires at least one retriever');
    }
    if (_limit <= 0) {
      throw ArgumentError('search limit must be positive');
    }
    final payload = <String, dynamic>{
      'table': _table,
      'retrievers': List<Map<String, dynamic>>.from(_retrievers),
      'fusion': _fusion,
      'limit': _limit,
    };
    if (_must.isNotEmpty) {
      payload['must'] = List<Map<String, dynamic>>.from(_must);
    }
    if (_rerank != null) {
      payload['rerank'] = _rerank;
    }
    if (_projection != null) {
      payload['projection'] = _projection;
    }
    if (_explain) {
      payload['explain'] = true;
    }
    if (_cursor != null && _cursor!.isNotEmpty) {
      payload['cursor'] = _cursor;
    }
    return payload;
  }

  /// Execute hybrid search. Returns the decoded body (`hits`, optional
  /// `next_cursor` / `trace`).
  Future<Map<String, dynamic>> execute() async {
    final r = await _client.post('/kit/search', build());
    final data = r.json();
    if (data is Map<String, dynamic>) {
      return data;
    }
    return {'hits': <dynamic>[]};
  }

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
      var key = entry.key;
      if ((type == 'fm_contains' || type == 'fm_contains_all') &&
          key == 'value') {
        key = type == 'fm_contains_all' ? 'patterns' : 'pattern';
      }
      normalized[aliases[key] ?? key] = entry.value;
    }
    return normalized;
  }
}
