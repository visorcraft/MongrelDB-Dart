/// Exception hierarchy for the MongrelDB Dart client.
///
/// All client errors implement [MongrelDBException]. Network problems map to
/// [ConnectionException], HTTP status codes map to [AuthException],
/// [NotFoundException], [ConstraintException], or [QueryException].
library;

/// Base class for every error raised by the MongrelDB client.
class MongrelDBException implements Exception {
  /// Human-readable detail message.
  final String message;

  /// Underlying cause, if any.
  final Object? cause;

  MongrelDBException(this.message, {this.cause});

  @override
  String toString() {
    final type = runtimeType.toString();
    return cause == null ? '$type: $message' : '$type: $message ($cause)';
  }
}

/// Authentication or authorization failure (HTTP 401/403).
class AuthException extends MongrelDBException {
  AuthException(super.message, {super.cause});
}

/// The requested resource (table, row, procedure) does not exist (HTTP 404).
class NotFoundException extends MongrelDBException {
  NotFoundException(super.message, {super.cause});
}

/// A database constraint was violated at commit time (HTTP 409).
class ConstraintException extends MongrelDBException {
  /// Server-reported error code (e.g. `UNIQUE_VIOLATION`).
  final String errorCode;

  /// Index of the offending operation within the batch, when reported.
  final int? opIndex;

  ConstraintException(
    super.message, {
    required this.errorCode,
    this.opIndex,
    super.cause,
  });
}

/// Network-level failure: connection refused, DNS error, broken socket.
class ConnectionException extends MongrelDBException {
  ConnectionException(super.message, {super.cause});
}

/// Any server-reported error that does not have a more specific type
/// (HTTP 400, 500, malformed payloads, JSON failures).
class QueryException extends MongrelDBException {
  QueryException(super.message, {super.cause});
}
