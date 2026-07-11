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
/// a canned `200 OK` payload. Subclassing (rather than mocking) avoids
/// pulling in a mock framework and lets us reuse the parent's [Response]
/// type unchanged.
class _RecordingTransport extends HttpTransport {
  String? lastMethod;
  String? lastUrl;
  String? lastBody;
  Map<String, String> lastHeaders = <String, String>{};

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
    // createTable() reads 'table_id' from the response; return a stable id.
    return Response(200, '{"table_id": 42}');
  }
}

void main() {
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
        });

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
        expect(columns, hasLength(2));

        final status = columns[1];
        expect(status['name'], 'status');

        // Round-trip the column map: both keys must survive serialization
        // with their original values intact.
        expect(status['enum_variants'], <String>['a', 'b', 'c']);
        expect(status['default_value'], 'a');
        expect(status['default_expr'], 'uuid');
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
  });
}
