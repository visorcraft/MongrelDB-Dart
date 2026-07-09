/// High-level MongrelDB Dart client.
///
/// [MongrelDB] is a single class that owns the HTTP transport, authentication,
/// and error mapping. Typed CRUD helpers (`put`, `upsert`, `query`,
/// `beginTransaction`, ...) wrap the daemon's Kit transaction, query, and SQL
/// endpoints.
///
/// ```dart
/// import 'package:mongreldb/mongreldb.dart';
///
/// final db = MongrelDB('http://127.0.0.1:8453');
/// await db.createTable('orders', [
///   {'id': 1, 'name': 'id', 'ty': 'int64', 'primary_key': true, 'nullable': false},
/// ]);
/// await db.put('orders', {1: 1, 2: 'Alice', 3: 99.5});
/// ```
library;

import 'dart:convert';

import 'http_transport.dart';
import 'mongreldb_exception.dart';
import 'query_builder.dart';
import 'transaction.dart';

export 'http_transport.dart' show Response, HttpTransport;
export 'mongreldb_exception.dart';
export 'query_builder.dart' show QueryBuilder;
export 'transaction.dart' show Transaction;

/// MongrelDB client.
///
/// Connect to a running `mongreldb-server` daemon and run typed CRUD, batch
/// transactions, native index queries, and SQL.
class MongrelDB {
  /// Daemon base URL (no trailing slash).
  final String url;

  /// Bearer token (for `--auth-token` mode), if any.
  final String? token;

  /// Basic-auth username (for `--auth-users` mode), if any.
  final String? username;

  /// Basic-auth password (for `--auth-users` mode), if any.
  final String? password;

  /// Pooled HTTP transport.
  final HttpTransport transport;

  final Map<String, String> _defaultHeaders;

  MongrelDB(
    this.url, {
    this.token,
    this.username,
    this.password,
    HttpTransport? transport,
  }) : transport = transport ?? HttpTransport(),
       _defaultHeaders = {
         'Accept': 'application/json',
         if (token != null)
           'Authorization': 'Bearer $token'
         else if (username != null)
           'Authorization':
               'Basic ${base64Encode(utf8.encode('$username:${password ?? ''}'))}',
       };

  // -- HTTP helpers ----------------------------------------------------------

  Future<Response> get(String path, {Map<String, String>? headers}) =>
      _request('GET', path, headers ?? const {});

  Future<Response> post(
    String path,
    dynamic data, {
    Map<String, String>? headers,
  }) => _request(
    'POST',
    path,
    headers ?? {},
    body: data == null ? null : _encodeJson(data),
  );

  Future<Response> deleteRaw(String path, {Map<String, String>? headers}) =>
      _request('DELETE', path, headers ?? const {});

  /// JSON-encode a request payload.
  ///
  /// Rejects recursive structures and values with no JSON representation by
  /// raising [QueryException]; malformed UTF-8 is replaced rather than failing
  /// the whole request.
  String _encodeJson(Object? data) {
    try {
      return jsonEncode(
        data,
        toEncodable: (Object? nonEncodable) => throw FormatException(
          'Cannot JSON-encode value of type '
          '${nonEncodable.runtimeType}',
        ),
      );
    } on JsonUnsupportedObjectError catch (e) {
      throw QueryException(
        'Request payload cannot be JSON-encoded. '
        'INF, NaN, and recursive structures have no JSON representation.',
        cause: e,
      );
    } on FormatException catch (e) {
      throw QueryException(
        'Request payload cannot be JSON-encoded: $e',
        cause: e,
      );
    }
  }

  /// Low-level request with status-code mapping.
  Future<Response> _request(
    String method,
    String path,
    Map<String, String> headers, {
    String? body,
  }) async {
    final merged = <String, String>{..._defaultHeaders, ...headers};
    final full =
        '${url.replaceAll(RegExp(r'/+$'), '')}'
        '/${path.replaceAll(RegExp(r'^/+'), '')}';

    final Response response;
    try {
      response = await transport.request(method, full, merged, body: body);
    } on MongrelDBException {
      rethrow;
    }

    if (response.isSuccessful) {
      return response;
    }
    _throwForStatus(response);
  }

  /// Map an error response to a typed exception. Always throws.
  Never _throwForStatus(Response response) {
    final status = response.status;
    final body = response.body;

    Map<String, dynamic>? json;
    final trimmed = body.trim();
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          json = decoded;
        }
      } on FormatException {
        // Malformed JSON body - fall through to use the raw body as message.
      }
    }

    final err = json?['error'];
    final String message;
    if (err is Map<String, dynamic> && err['message'] is String) {
      message = err['message'] as String;
    } else {
      message = body;
    }

    switch (status) {
      case 401:
      case 403:
        throw AuthException(
          message.isNotEmpty ? message : 'Authentication failed ($status)',
        );
      case 404:
        throw NotFoundException(message.isNotEmpty ? message : 'Not found');
      case 409:
        throw ConstraintException(
          message.isNotEmpty ? message : 'Constraint violation',
          errorCode: (err['code'] as String?) ?? '',
          opIndex: err['op_index'] as int?,
        );
      default:
        throw QueryException(
          message.isNotEmpty ? message : 'Server error ($status)',
        );
    }
  }

  // -- Convenience API -------------------------------------------------------

  /// Ping the daemon. Returns true on a healthy 2xx response, false otherwise.
  Future<bool> health() async {
    try {
      final r = await get('/health');
      return r.isSuccessful;
    } on MongrelDBException {
      return false;
    }
  }

  /// List all table names.
  Future<List<String>> tableNames() async {
    final r = await get('/tables');
    final data = r.json();
    if (data is List) {
      return data.cast<String>();
    }
    return const [];
  }

  /// Create a table. [columns] is a list of column descriptors.
  /// Returns the new table id reported by the daemon.
  Future<int> createTable(
    String name,
    List<Map<String, Object?>> columns,
  ) async {
    final r = await post('/kit/create_table', {
      'name': name,
      'columns': columns,
    });
    final data = r.json();
    if (data is Map<String, dynamic>) {
      return (data['table_id'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  /// Drop a table by name.
  Future<void> dropTable(String name) async {
    await deleteRaw('/tables/${_encodeSegment(name)}');
  }

  /// Row count for a table.
  Future<int> count(String table) async {
    final r = await get('/tables/${_encodeSegment(table)}/count');
    final data = r.json();
    if (data is Map<String, dynamic>) {
      final count = data['count'];
      if (count is num) {
        return count.toInt();
      }
    }
    throw QueryException('mongreldb: malformed count response: ${r.body}');
  }

  /// Insert a row. [cells] maps column id to value (`{1: 1, 2: 'Alice'}`).
  ///
  /// Returns the per-op result object, or an empty map if none.
  Future<Map<String, dynamic>> put(
    String table,
    Map<int, Object?> cells, {
    String? idempotencyKey,
  }) async {
    final payload = <String, dynamic>{
      'ops': [
        {
          'put': {'table': table, 'cells': _cellsToFlat(cells)},
        },
      ],
    };
    if (idempotencyKey != null) {
      payload['idempotency_key'] = idempotencyKey;
    }
    final r = await post('/kit/txn', payload);
    final data = r.json() as Map<String, dynamic>? ?? const {};
    final results = (data['results'] as List?) ?? const [];
    if (results.isNotEmpty && results.first is Map<String, dynamic>) {
      return results.first as Map<String, dynamic>;
    }
    return {};
  }

  /// Upsert a row (insert or update on PK conflict).
  Future<Map<String, dynamic>> upsert(
    String table,
    Map<int, Object?> cells, {
    Map<int, Object?>? updateCells,
    String? idempotencyKey,
  }) async {
    final op = <String, dynamic>{'table': table, 'cells': _cellsToFlat(cells)};
    if (updateCells != null) {
      op['update_cells'] = _cellsToFlat(updateCells);
    }
    final payload = <String, dynamic>{
      'ops': [
        {'upsert': op},
      ],
    };
    if (idempotencyKey != null) {
      payload['idempotency_key'] = idempotencyKey;
    }
    final r = await post('/kit/txn', payload);
    final data = r.json() as Map<String, dynamic>? ?? const {};
    final results = (data['results'] as List?) ?? const [];
    if (results.isNotEmpty && results.first is Map<String, dynamic>) {
      return results.first as Map<String, dynamic>;
    }
    return {};
  }

  /// Delete a row by its internal row id.
  Future<void> delete(String table, int rowId) async {
    await post('/kit/txn', {
      'ops': [
        {
          'delete': {'table': table, 'row_id': rowId},
        },
      ],
    });
  }

  /// Delete a row by its primary key value.
  Future<void> deleteByPk(String table, Object? pk) async {
    await post('/kit/txn', {
      'ops': [
        {
          'delete_by_pk': {'table': table, 'pk': pk},
        },
      ],
    });
  }

  /// Start a fluent query builder.
  QueryBuilder query(String table) => QueryBuilder(this, table);

  /// Execute SQL against the daemon's DataFusion-backed `/sql` endpoint.
  ///
  /// Requests the JSON result format, so a SELECT returns a JSON array of row
  /// objects keyed by column name. Returns parsed JSON rows for SELECTs, or an
  /// empty list for statements like INSERT/UPDATE that produce no rows.
  Future<List<Map<String, dynamic>>> sql(String sql) async {
    final r = await post('/sql', {'sql': sql, 'format': 'json'});
    final body = r.body;
    if (body.isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(body);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    return const [];
  }

  /// Full schema catalog (table name to descriptor).
  Future<Map<String, dynamic>> schema() async {
    final r = await get('/kit/schema');
    final data = r.json() as Map<String, dynamic>? ?? const {};
    final tables = data['tables'];
    if (tables is Map<String, dynamic>) {
      return tables;
    }
    return const {};
  }

  /// Descriptor for a single table.
  Future<Map<String, dynamic>> schemaFor(String table) async {
    final r = await get('/kit/schema/${_encodeSegment(table)}');
    return r.json() as Map<String, dynamic>? ?? const {};
  }

  /// Compact all tables (merge sorted runs).
  Future<Map<String, dynamic>> compact() async {
    final r = await post('/compact', <String, dynamic>{});
    return r.json() as Map<String, dynamic>? ?? const {};
  }

  /// Begin a batch transaction.
  Transaction beginTransaction() => Transaction(this);

  /// Release pooled HTTP connections.
  void close() => transport.close();

  // -- Internal helpers ------------------------------------------------------

  /// Flatten `{colId: value}` into `[colId, value, colId, value, ...]`.
  List<Object?> _cellsToFlat(Map<int, Object?> cells) {
    final flat = <Object?>[];
    final keys = cells.keys.toList()..sort();
    for (final colId in keys) {
      flat.add(colId);
      flat.add(cells[colId]);
    }
    return flat;
  }

  /// Percent-encodes a single path segment so a table name containing `/`,
  /// `?`, `#`, or other reserved characters cannot inject extra segments.
  static String _encodeSegment(String segment) {
    // Uri.encodeComponent encodes everything that is not a letter, digit,
    // or one of -_.~ -- exactly the RFC 3986 unreserved set. Critically,
    // it encodes '/', '?', '#', and spaces.
    return Uri.encodeComponent(segment);
  }
}
