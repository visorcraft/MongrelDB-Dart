/// Structural durable-recovery types for MongrelDB 0.64+.
///
/// These parse server JSON from `GET /queries/{id}` and cancel responses
/// without string-scraping free-form status text. Fields mirror the server
/// `DurableOutcome` / `QueryStatus` wire shapes.
library;

/// Structural hybrid logical clock from durable recovery (0.64+).
class CommitHlc {
  /// Wall-clock component in microseconds.
  final int physicalMicros;

  /// Logical counter for same-physical ties.
  final int logical;

  /// Node tiebreaker for distributed clocks.
  final int nodeTiebreaker;

  const CommitHlc({
    required this.physicalMicros,
    required this.logical,
    required this.nodeTiebreaker,
  });

  /// Parse `{"physical_micros", "logical", "node_tiebreaker"}` or return null.
  static CommitHlc? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final map = raw is Map<String, dynamic>
        ? raw
        : Map<String, dynamic>.from(raw);
    final phys = map['physical_micros'];
    if (phys is! num) {
      return null;
    }
    final logical = map['logical'];
    final tie = map['node_tiebreaker'];
    return CommitHlc(
      physicalMicros: phys.toInt(),
      logical: logical is num ? logical.toInt() : 0,
      nodeTiebreaker: tie is num ? tie.toInt() : 0,
    );
  }

  @override
  String toString() =>
      'CommitHlc(physicalMicros: $physicalMicros, logical: $logical, '
      'nodeTiebreaker: $nodeTiebreaker)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommitHlc &&
          physicalMicros == other.physicalMicros &&
          logical == other.logical &&
          nodeTiebreaker == other.nodeTiebreaker;

  @override
  int get hashCode => Object.hash(physicalMicros, logical, nodeTiebreaker);
}

/// Nested durable recovery payload on query status/cancel responses.
class DurableOutcome {
  final bool? committed;
  final int? committedStatements;
  final int? lastCommitEpoch;
  final String? lastCommitEpochText;
  final CommitHlc? lastCommitHlc;
  final int? firstCommitStatementIndex;
  final int? lastCommitStatementIndex;
  final int? completedStatements;
  final int? statementIndex;
  final String serialization;
  final String? serializationState;
  final String? terminalState;

  const DurableOutcome({
    this.committed,
    this.committedStatements,
    this.lastCommitEpoch,
    this.lastCommitEpochText,
    this.lastCommitHlc,
    this.firstCommitStatementIndex,
    this.lastCommitStatementIndex,
    this.completedStatements,
    this.statementIndex,
    this.serialization = '',
    this.serializationState,
    this.terminalState,
  });

  /// Parse a server outcome/durable object; empty map yields defaults.
  static DurableOutcome fromJson(Object? raw) {
    if (raw is! Map) {
      return const DurableOutcome();
    }
    final map = raw is Map<String, dynamic>
        ? raw
        : Map<String, dynamic>.from(raw);
    return DurableOutcome(
      committed: map.containsKey('committed') ? map['committed'] as bool? : null,
      committedStatements: _asInt(map['committed_statements']),
      lastCommitEpoch: _asInt(map['last_commit_epoch']),
      lastCommitEpochText: map['last_commit_epoch_text']?.toString(),
      lastCommitHlc: CommitHlc.fromJson(map['last_commit_hlc']),
      firstCommitStatementIndex: _asInt(map['first_commit_statement_index']),
      lastCommitStatementIndex: _asInt(map['last_commit_statement_index']),
      completedStatements: _asInt(map['completed_statements']),
      statementIndex: _asInt(map['statement_index']),
      serialization: map['serialization']?.toString() ?? '',
      serializationState: map['serialization_state']?.toString(),
      terminalState: map['terminal_state']?.toString(),
    );
  }

  static int? _asInt(Object? v) => v is num ? v.toInt() : null;
}

/// Decoded `GET /queries/{query_id}` status for durable recovery.
class QueryStatus {
  final String queryId;
  final String status;
  final String state;
  final String serverState;
  final String? terminalState;
  final bool? committed;
  final DurableOutcome outcome;
  final DurableOutcome? durable;
  final CommitHlc? lastCommitHlc;

  /// Original decoded JSON map (may include extra server fields).
  final Map<String, dynamic> raw;

  const QueryStatus({
    required this.queryId,
    required this.status,
    required this.state,
    required this.serverState,
    this.terminalState,
    this.committed,
    required this.outcome,
    this.durable,
    this.lastCommitHlc,
    required this.raw,
  });

  /// Parse a full query-status JSON object.
  factory QueryStatus.fromJson(Map<String, dynamic> raw) {
    final outcome = DurableOutcome.fromJson(raw['outcome']);
    final durableRaw = raw['durable'];
    final DurableOutcome? durable =
        durableRaw is Map ? DurableOutcome.fromJson(durableRaw) : null;
    return QueryStatus(
      queryId: raw['query_id']?.toString() ?? '',
      status: raw['status']?.toString() ?? '',
      state: raw['state']?.toString() ?? '',
      serverState:
          (raw['server_state'] ?? raw['state'])?.toString() ?? '',
      terminalState: raw['terminal_state']?.toString(),
      committed:
          raw.containsKey('committed') ? raw['committed'] as bool? : null,
      outcome: outcome,
      durable: durable,
      lastCommitHlc: CommitHlc.fromJson(raw['last_commit_hlc']),
      raw: raw,
    );
  }

  /// Authoritative HLC: nested durable, then outcome, then top-level.
  CommitHlc? commitHlc() {
    if (durable?.lastCommitHlc != null) {
      return durable!.lastCommitHlc;
    }
    if (outcome.lastCommitHlc != null) {
      return outcome.lastCommitHlc;
    }
    return lastCommitHlc;
  }

  /// Prefer nested durable/outcome `serialization_state`, then `serialization`.
  String serializationState() {
    final dState = durable?.serializationState;
    if (dState != null && dState.isNotEmpty) {
      return dState;
    }
    final dSer = durable?.serialization;
    if (dSer != null && dSer.isNotEmpty) {
      return dSer;
    }
    final oState = outcome.serializationState;
    if (oState != null && oState.isNotEmpty) {
      return oState;
    }
    return outcome.serialization;
  }
}

/// Result of `POST /kit/retrieve_text` (0.64+).
class TextRetrieveResult {
  final List<Map<String, dynamic>> hits;
  final Map<String, dynamic> provenance;

  const TextRetrieveResult({
    required this.hits,
    required this.provenance,
  });

  factory TextRetrieveResult.fromJson(Object? raw) {
    if (raw is! Map) {
      return const TextRetrieveResult(hits: [], provenance: {});
    }
    final map = raw is Map<String, dynamic>
        ? raw
        : Map<String, dynamic>.from(raw);
    final hitsRaw = map['hits'];
    final hits = <Map<String, dynamic>>[];
    if (hitsRaw is List) {
      for (final h in hitsRaw) {
        if (h is Map) {
          hits.add(h is Map<String, dynamic>
              ? h
              : Map<String, dynamic>.from(h));
        }
      }
    }
    final provRaw = map['provenance'];
    final provenance = provRaw is Map
        ? (provRaw is Map<String, dynamic>
            ? provRaw
            : Map<String, dynamic>.from(provRaw))
        : <String, dynamic>{};
    return TextRetrieveResult(hits: hits, provenance: provenance);
  }
}
