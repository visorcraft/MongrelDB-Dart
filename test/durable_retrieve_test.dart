// Unit tests for 0.64 durable recovery parsers and retrieve_text wire shape.
//
// These tests drive the shipped [QueryStatus.fromJson], [CommitHlc.fromJson],
// [TextRetrieveResult.fromJson], and client HTTP methods through a fake
// [HttpTransport] — they do not reimplement parsers.

import 'dart:convert';

import 'package:mongreldb/mongreldb.dart';
import 'package:test/test.dart';

/// Records the last request and returns a canned response.
class _RecordingTransport extends HttpTransport {
  String? lastMethod;
  String? lastUrl;
  String? lastBody;
  Map<String, String> lastHeaders = <String, String>{};

  final String body;

  _RecordingTransport({this.body = '{}'});

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
    return Response(200, this.body);
  }
}

/// Fixture mirrors mongreldb-server GET /queries/{id} (0.64+).
const _queryStatusFixture = <String, dynamic>{
  'query_id': 'abcdefabcdefabcdefabcdefabcdefab',
  'status': 'committed',
  'state': 'completed',
  'server_state': 'completed',
  'terminal_state': 'committed',
  'operation': 'INSERT',
  'committed': true,
  'committed_statements': 1,
  'last_commit_epoch': 17,
  'last_commit_epoch_text': '17',
  'last_commit_hlc': {
    'physical_micros': 1700000000000000,
    'logical': 3,
    'node_tiebreaker': 7,
  },
  'first_commit_statement_index': 0,
  'last_commit_statement_index': 0,
  'completed_statements': 1,
  'statement_index': 0,
  'cancel_outcome': null,
  'cancellation_reason': 'none',
  'retryable': false,
  'outcome': {
    'committed': true,
    'committed_statements': 1,
    'last_commit_epoch': 17,
    'last_commit_epoch_text': '17',
    'last_commit_hlc': {
      'physical_micros': 1700000000000000,
      'logical': 3,
      'node_tiebreaker': 7,
    },
    'first_commit_statement_index': 0,
    'last_commit_statement_index': 0,
    'completed_statements': 1,
    'statement_index': 0,
    'serialization': 'succeeded',
    'serialization_state': 'succeeded',
    'terminal_state': 'committed',
  },
  'durable': {
    'committed': true,
    'committed_statements': 1,
    'last_commit_epoch': 17,
    'last_commit_epoch_text': '17',
    'last_commit_hlc': {
      'physical_micros': 1700000000000000,
      'logical': 3,
      'node_tiebreaker': 7,
    },
    'first_commit_statement_index': 0,
    'last_commit_statement_index': 0,
    'completed_statements': 1,
    'statement_index': 0,
    'serialization': 'succeeded',
    'serialization_state': 'succeeded',
    'terminal_state': 'committed',
  },
  'terminal_error': null,
};

void main() {
  group('CommitHlc / DurableOutcome / QueryStatus parsers', () {
    test('queryStatus parses structural HLC without string parsing', () {
      final status = QueryStatus.fromJson(
        Map<String, dynamic>.from(_queryStatusFixture),
      );

      expect(status.committed, isTrue);
      expect(status.queryId, 'abcdefabcdefabcdefabcdefabcdefab');
      expect(status.status, 'committed');
      expect(status.state, 'completed');
      expect(status.serverState, 'completed');
      expect(status.terminalState, 'committed');

      final hlc = status.commitHlc();
      expect(hlc, isNotNull);
      expect(hlc!.physicalMicros, 1700000000000000);
      expect(hlc.logical, 3);
      expect(hlc.nodeTiebreaker, 7);

      expect(status.serializationState(), 'succeeded');
      expect(status.outcome.lastCommitEpoch, 17);
      expect(status.outcome.lastCommitHlc?.physicalMicros, 1700000000000000);
      expect(status.durable?.serializationState, 'succeeded');
    });

    test('CommitHlc.fromJson returns null for missing physical_micros', () {
      expect(CommitHlc.fromJson(null), isNull);
      expect(CommitHlc.fromJson(<String, dynamic>{}), isNull);
      expect(CommitHlc.fromJson(<String, dynamic>{'logical': 1}), isNull);
    });

    test('commitHlc prefers durable over outcome over top-level', () {
      final status = QueryStatus.fromJson({
        'last_commit_hlc': {
          'physical_micros': 1,
          'logical': 0,
          'node_tiebreaker': 0,
        },
        'outcome': {
          'last_commit_hlc': {
            'physical_micros': 2,
            'logical': 0,
            'node_tiebreaker': 0,
          },
        },
        'durable': {
          'last_commit_hlc': {
            'physical_micros': 3,
            'logical': 1,
            'node_tiebreaker': 2,
          },
        },
      });
      expect(status.commitHlc()?.physicalMicros, 3);

      final withoutDurable = QueryStatus.fromJson({
        'last_commit_hlc': {
          'physical_micros': 1,
          'logical': 0,
          'node_tiebreaker': 0,
        },
        'outcome': {
          'last_commit_hlc': {
            'physical_micros': 2,
            'logical': 0,
            'node_tiebreaker': 0,
          },
        },
      });
      expect(withoutDurable.commitHlc()?.physicalMicros, 2);
    });
  });

  group('queryStatus / cancelQuery HTTP', () {
    test('queryStatus GETs /queries/{id} and uses shipped parser', () async {
      final fake = _RecordingTransport(body: jsonEncode(_queryStatusFixture));
      final db = MongrelDB('http://test.invalid', transport: fake);

      final status = await db.queryStatus('abcdefabcdefabcdefabcdefabcdefab');

      expect(fake.lastMethod, 'GET');
      expect(
        fake.lastUrl,
        endsWith('/queries/abcdefabcdefabcdefabcdefabcdefab'),
      );
      expect(fake.lastBody, isNull);
      expect(status.committed, isTrue);
      expect(status.commitHlc()?.logical, 3);
      expect(status.serializationState(), 'succeeded');
    });

    test('cancelQuery POSTs /queries/{id}/cancel', () async {
      final fake = _RecordingTransport(
        body: jsonEncode({
          'cancelled': true,
          'outcome': {
            'serialization_state': 'cancelled',
          },
        }),
      );
      final db = MongrelDB('http://test.invalid', transport: fake);

      final result = await db.cancelQuery('qid-1');

      expect(fake.lastMethod, 'POST');
      expect(fake.lastUrl, endsWith('/queries/qid-1/cancel'));
      final body = jsonDecode(fake.lastBody!) as Map<String, dynamic>;
      expect(body, isEmpty);
      expect(result['cancelled'], isTrue);
    });

    test('queryStatus rejects empty query id', () async {
      final db = MongrelDB(
        'http://test.invalid',
        transport: _RecordingTransport(),
      );
      expect(db.queryStatus(''), throwsA(isA<QueryException>()));
    });
  });

  group('retrieveText', () {
    test('POSTs /kit/retrieve_text with table, embedding_column, text, k',
        () async {
      final fake = _RecordingTransport(
        body: jsonEncode({
          'hits': [
            {
              'row_id': '1',
              'rank': 1,
              'score': {'ann_cosine_distance': 0.1},
            },
          ],
          'provenance': {
            'embedding_column': 3,
            'provider_registry_generation': 1,
            'query_source_fingerprint': 'ab',
            'semantic_identity': {'provider_id': 'fixed', 'dimension': 2},
          },
        }),
      );
      final db = MongrelDB('http://test.invalid', transport: fake);

      final result = await db.retrieveText('docs', 3, 'cat', k: 5);

      expect(fake.lastMethod, 'POST');
      expect(fake.lastUrl, endsWith('/kit/retrieve_text'));
      final payload = jsonDecode(fake.lastBody!) as Map<String, dynamic>;
      expect(payload['table'], 'docs');
      expect(payload['embedding_column'], 3);
      expect(payload['text'], 'cat');
      expect(payload['k'], 5);

      expect(result.hits, hasLength(1));
      expect(result.hits.first['row_id'], '1');
      expect(result.provenance['embedding_column'], 3);
    });

    test('omits k when not supplied', () async {
      final fake = _RecordingTransport(
        body: '{"hits":[],"provenance":{}}',
      );
      final db = MongrelDB('http://test.invalid', transport: fake);

      await db.retrieveText('docs', 3, 'cat');
      final payload = jsonDecode(fake.lastBody!) as Map<String, dynamic>;
      expect(payload.containsKey('k'), isFalse);
    });

    test('TextRetrieveResult.fromJson handles missing fields', () {
      final empty = TextRetrieveResult.fromJson(null);
      expect(empty.hits, isEmpty);
      expect(empty.provenance, isEmpty);

      final partial = TextRetrieveResult.fromJson({'hits': []});
      expect(partial.hits, isEmpty);
      expect(partial.provenance, isEmpty);
    });
  });

  group('multi-retriever SearchBuilder', () {
    test('build includes two retrievers and fusion', () {
      final db = MongrelDB('http://test.invalid', transport: _RecordingTransport());
      final payload = db
          .search('docs')
          .annRetriever('ann', 3, [0.1, 0.2], k: 10, weight: 1.0)
          .sparseRetriever(
            'sparse',
            4,
            [
              [1, 0.5],
              [2, 0.25],
            ],
            k: 10,
            weight: 0.5,
          )
          .fusion(constant: 60)
          .limit(5)
          .build();

      final retrievers = payload['retrievers'] as List;
      expect(retrievers, hasLength(2));
      expect(payload['fusion'], isNotNull);
      expect(
        (payload['fusion'] as Map)['reciprocal_rank'],
        {'constant': 60},
      );
      expect(payload['table'], 'docs');
      expect(payload['limit'], 5);
      expect((retrievers[0] as Map)['name'], 'ann');
      expect((retrievers[1] as Map)['name'], 'sparse');
    });
  });
}
