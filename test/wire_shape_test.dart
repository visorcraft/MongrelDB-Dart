// Wire-shape conformance tests for the MongrelDB Dart client.
//
// These tests do NOT touch the network. They inject a fake [HttpTransport]
// that captures the outgoing request (method, URL, body) so we can assert
// that the JSON sent over the wire matches the documented column-spec
// keys. The daemon side already validates these keys; this suite locks the
// Dart client's serialization in place so a refactor of `createTable`
// cannot silently drop a key (or rename it) without breaking tests.
//
// Why a fake transport instead of stubbing `dart:io HttpClient`? The client
// owns its own [HttpTransport] abstraction (see `lib/src/http_transport.dart`)
// and accepts an override via the `MongrelDB` constructor. Overriding the
// transport is the supported injection point and avoids any socket setup.

import 'dart:convert';

import 'package:mongreldb/mongreldb.dart';
import 'package:test/test.dart';

/// A [HttpTransport] that records the most recent request and replies with
/// a canned payload. Subclassing (rather than mocking) avoids pulling in a
/// mock framework and lets us reuse the parent's [Response] type unchanged.
class _RecordingTransport extends HttpTransport {
  String? lastMethod;
  String? lastUrl;
  String? lastBody;
  Map<String, String> lastHeaders = <String, String>{};

  final int status;
  final String body;

  _RecordingTransport({this.status = 200, this.body = '{"table_id": 42}'});

  @override
  Future<Response> request(
    String method,
    String url,
    Map<String, String> headers, {
    String? body,
  }) async {
    lastMethod = method;
    lastUrl = url;
    lastBody = body;
    lastHeaders = Map<String, String>.from(headers);
    return Response(status, this.body);
  }
}

void main() {
  test('top-level 409 error maps to ConstraintException', () async {
    final fake = _RecordingTransport(
      status: 409,
      body: '{"status":"error","message":"epoch is no longer retained"}',
    );
    final db = MongrelDB('http://test.invalid', transport: fake);

    expect(db.sql('SELECT 1'), throwsA(isA<ConstraintException>()));
  });

  group('createTable wire shape', () {
    test('preserves every static JSON scalar including literal now', () {
      for (final value in <Object?>['text', 3, true, null, 'now']) {
        final wire = jsonEncode({'default_value': value});
        expect(jsonDecode(wire)['default_value'], value);
      }
    });
    test(
      'sends enum_variants and default_value verbatim in the JSON body',
      () async {
        final fake = _RecordingTransport();
        final db = MongrelDB('http://test.invalid', transport: fake);

        await db.createTable('widgets', [
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
            'ty': 'text',
            // The keys under test: enum constraint and column default.
            'enum_variants': <String>['a', 'b', 'c'],
            'default_value': 'a',
            'default_expr': 'uuid',
          },
          {
            'id': 3,
            'name': 'embedding',
            'ty': 'embedding(384)',
            'embedding_source': {
              'kind': 'configured_model',
              'provider_id': 'docs',
              'model_id': 'model',
              'model_version': '1',
            },
          },
        ], constraints: {
          'checks': [
            {
              'id': 1,
              'name': 'status_known',
              'expr': {
                'Eq': [
                  {'Col': 2},
                  {
                    'Lit': {'Bytes': 'a'}
                  },
                ],
              },
            },
          ],
        }, indexes: [
          {'name': 'bm', 'column_id': 2, 'kind': 'bitmap'},
          {'name': 'fm', 'column_id': 2, 'kind': 'fm_index'},
          {
            'name': 'ann',
            'column_id': 3,
            'kind': 'ann',
            'predicate': 'embedding IS NOT NULL',
            'options': {
              'ann': {
                'm': 24,
                'ef_construction': 96,
                'ef_search': 48,
                'quantization': 'dense',
              },
            },
          },
          {'name': 'range', 'column_id': 1, 'kind': 'learned_range'},
          {'name': 'minhash', 'column_id': 2, 'kind': 'minhash'},
          {'name': 'sparse', 'column_id': 2, 'kind': 'sparse'},
        ]);

        // Request line + URL are stable.
        expect(fake.lastMethod, 'POST');
        expect(fake.lastUrl, endsWith('/kit/create_table'));

        // Body must be non-null and parse as JSON (the client encodes via
        // jsonEncode, so a non-JSON body would be a regression).
        final body = fake.lastBody;
        expect(body, isNotNull);
        final decoded = jsonDecode(body!) as Map<String, dynamic>;
        expect(decoded['name'], 'widgets');

        final columns =
            (decoded['columns'] as List).cast<Map<String, dynamic>>();
        expect(columns, hasLength(3));

        final status = columns[1];
        expect(status['name'], 'status');

        // Round-trip the column map: both keys must survive serialization
        // with their original values intact.
        expect(status['enum_variants'], <String>['a', 'b', 'c']);
        expect(status['default_value'], 'a');
        expect(status['default_expr'], 'uuid');
        expect(columns[2]['embedding_source']['kind'], 'configured_model');
        final indexes =
            (decoded['indexes'] as List).cast<Map<String, dynamic>>();
        expect(indexes.map((index) => index['kind']), [
          'bitmap',
          'fm_index',
          'ann',
          'learned_range',
          'minhash',
          'sparse'
        ]);
        expect(indexes[2]['options']['ann']['quantization'], 'dense');
        expect(indexes[2]['predicate'], 'embedding IS NOT NULL');
        expect(
          ((decoded['constraints'] as Map<String, dynamic>)['checks'] as List)
              .first['name'],
          'status_known',
        );

        // Belt-and-braces: assert the keys appear in the raw JSON text in
        // the exact wire format, so a regression that re-encodes the map
        // (e.g. through a stripping layer) still fails this test.
        expect(body, contains('"enum_variants":["a","b","c"]'));
        expect(body, contains('"default_value":"a"'));
        expect(body, contains('"constraints":{"checks":['));
      },
    );

    test(
      'omits enum_variants and default_value when not supplied',
      () async {
        final fake = _RecordingTransport();
        final db = MongrelDB('http://test.invalid', transport: fake);

        await db.createTable('plain', [
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
        ]);

        final body = fake.lastBody;
        expect(body, isNotNull);

        // Neither key should appear at all when the caller did not set them.
        expect(body, isNot(contains('enum_variants')));
        expect(body, isNot(contains('default_value')));

        // Sanity: the columns still parse, and the unrelated keys are
        // present so we know the body is not empty / truncated.
        final decoded = jsonDecode(body!) as Map<String, dynamic>;
        final columns =
            (decoded['columns'] as List).cast<Map<String, dynamic>>();
        expect(columns[1]['name'], 'label');
        expect(columns[1]['ty'], 'varchar');
      },
    );

    test(
      'preserves the full static-default matrix with correct JSON types',
      () async {
        final fake = _RecordingTransport();
        final db = MongrelDB('http://test.invalid', transport: fake);

        await db.createTable('defaults_matrix', [
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
            'ty': 'text',
            'default_value': 'draft',
          },
          {
            'id': 3,
            'name': 'score',
            'ty': 'int64',
            'default_value': 7,
          },
          {
            'id': 4,
            'name': 'active',
            'ty': 'bool',
            'default_value': true,
          },
          {
            'id': 5,
            'name': 'optional',
            'ty': 'text',
            'default_value': null,
          },
          {
            'id': 6,
            'name': 'created',
            'ty': 'text',
            'default_value': 'now',
          },
          {
            'id': 7,
            'name': 'updated',
            'ty': 'text',
            'default_expr': 'now',
          },
        ]);

        expect(fake.lastMethod, 'POST');
        expect(fake.lastUrl, endsWith('/kit/create_table'));

        final body = fake.lastBody;
        expect(body, isNotNull);
        final decoded = jsonDecode(body!) as Map<String, dynamic>;
        final columns =
            (decoded['columns'] as List).cast<Map<String, dynamic>>();
        expect(columns, hasLength(7));

        // Literal scalar defaults must preserve their JSON types.
        expect(columns[1]['default_value'], 'draft');
        expect(columns[2]['default_value'], 7);
        expect(columns[3]['default_value'], true);
        expect(columns[4]['default_value'], isNull);
        expect(columns[5]['default_value'], 'now');

        // default_expr is a separate key and must not be folded into default_value.
        expect(columns[6]['default_expr'], 'now');
        expect(columns[6].containsKey('default_value'), isFalse);

        // Decode again to confirm raw JSON types, not just Dart runtime types.
        final redecoded = jsonDecode(body) as Map<String, dynamic>;
        final recols =
            (redecoded['columns'] as List).cast<Map<String, dynamic>>();
        expect(recols[2]['default_value'], isA<int>());
        expect(recols[3]['default_value'], isA<bool>());
        expect(recols[4].containsKey('default_value'), isTrue);
        expect(recols[4]['default_value'], isNull);
      },
    );
  });

  group('history retention wire shape', () {
    const retentionResponse =
        '{"history_retention_epochs": 100, "earliest_retained_epoch": 5}';

    test('GET uses the exact path and extracts both keys', () async {
      final fake = _RecordingTransport(body: retentionResponse);
      final db = MongrelDB('http://test.invalid', transport: fake);

      expect(await db.historyRetentionEpochs(), 100);
      expect(fake.lastMethod, 'GET');
      expect(fake.lastUrl, endsWith('/history/retention'));
      expect(fake.lastBody, isNull);
    });

    test('earliestRetainedEpoch reads the matching key', () async {
      final fake = _RecordingTransport(body: retentionResponse);
      final db = MongrelDB('http://test.invalid', transport: fake);

      expect(await db.earliestRetainedEpoch(), 5);
      expect(fake.lastMethod, 'GET');
      expect(fake.lastUrl, endsWith('/history/retention'));
    });

    test('PUT sends the exact body key and returns the new value', () async {
      final fake = _RecordingTransport(body: retentionResponse);
      final db = MongrelDB('http://test.invalid', transport: fake);

      expect(await db.setHistoryRetentionEpochs(250), 100);
      expect(fake.lastMethod, 'PUT');
      expect(fake.lastUrl, endsWith('/history/retention'));

      final body = fake.lastBody;
      expect(body, isNotNull);
      final decoded = jsonDecode(body!) as Map<String, dynamic>;
      expect(decoded.keys, equals(<String>['history_retention_epochs']));
      expect(decoded['history_retention_epochs'], 250);
    });

    test('historyRetention returns the full typed map', () async {
      final fake = _RecordingTransport(body: retentionResponse);
      final db = MongrelDB('http://test.invalid', transport: fake);

      final retention = await db.historyRetention();
      expect(retention, <String, int>{
        'history_retention_epochs': 100,
        'earliest_retained_epoch': 5,
      });
    });

    test('non-2xx response propagates as AuthException', () async {
      final fake = _RecordingTransport(
        status: 403,
        body: '{"error": {"message": "forbidden"}}',
      );
      final db = MongrelDB('http://test.invalid', transport: fake);

      expect(db.historyRetentionEpochs(), throwsA(isA<AuthException>()));
    });

    test('malformed response without required keys throws QueryException',
        () async {
      final fake = _RecordingTransport(body: '{"unexpected": 1}');
      final db = MongrelDB('http://test.invalid', transport: fake);

      expect(db.historyRetentionEpochs(), throwsA(isA<QueryException>()));
    });

    test('response with extra keys throws QueryException', () async {
      final fake = _RecordingTransport(
        body: '{"history_retention_epochs": 1, "earliest_retained_epoch": 0, '
            '"extra": true}',
      );
      final db = MongrelDB('http://test.invalid', transport: fake);

      expect(db.historyRetentionEpochs(), throwsA(isA<QueryException>()));
    });
  });
}
