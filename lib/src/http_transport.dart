/// HTTP transport for the MongrelDB client, built on [dart:io HttpClient].
///
/// All requests carry JSON bodies with an explicit
/// `Content-Type: application/json` header. Status codes are mapped to the
/// typed exception hierarchy in [MongrelDB] before a response reaches a caller.
library;

import 'dart:convert';
import 'dart:io';

import 'mongreldb_exception.dart';

/// Raw HTTP response: status code, decoded body, and parsed JSON (when present).
class Response {
  /// HTTP status code.
  final int status;

  /// Raw response body.
  final String body;

  Response(this.status, this.body);

  /// Whether the status code is in the 2xx success range.
  bool get isSuccessful => status >= 200 && status < 300;

  /// Parsed JSON body, or `null` if the body is empty or not JSON.
  dynamic json() {
    if (body.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }
}

/// Low-level transport that issues HTTP requests with [HttpClient].
class HttpTransport {
  HttpClient? _client;

  /// Idle timeout for keep-alive connections.
  final Duration idleTimeout;

  /// Total request timeout.
  final Duration timeout;

  HttpTransport({Duration? idleTimeout, Duration? timeout})
    : idleTimeout = idleTimeout ?? const Duration(seconds: 30),
      timeout = timeout ?? const Duration(seconds: 60);

  /// Lazily build (and configure) the [HttpClient].
  HttpClient get _http {
    var client = _client;
    if (client != null) {
      return client;
    }
    client = HttpClient()
      ..idleTimeout = idleTimeout
      ..userAgent = 'mongreldb-dart/0.1';
    _client = client;
    return client;
  }

  /// Perform an HTTP request.
  ///
  /// [method] HTTP verb (GET, POST, PUT, DELETE).
  /// [url] Absolute URL.
  /// [headers] Request headers (auth + content type merged in by caller).
  /// [body] Raw request body for POST/PUT, or null.
  Future<Response> request(
    String method,
    String url,
    Map<String, String> headers, {
    String? body,
  }) async {
    final uri = Uri.parse(url);
    HttpClientRequest req;
    try {
      switch (method) {
        case 'GET':
          req = await _http.getUrl(uri);
          break;
        case 'POST':
          req = await _http.postUrl(uri);
          break;
        case 'PUT':
          req = await _http.putUrl(uri);
          break;
        case 'DELETE':
          req = await _http.deleteUrl(uri);
          break;
        default:
          throw QueryException('Unsupported HTTP method: $method');
      }
    } on SocketException catch (e) {
      throw ConnectionException(
        'Cannot reach MongrelDB daemon: ${e.message}',
        cause: e,
      );
    } on HttpException catch (e) {
      throw ConnectionException(
        'HTTP error talking to MongrelDB: $e',
        cause: e,
      );
    }

    headers.forEach((name, value) => req.headers.add(name, value));

    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(body);
    }

    HttpClientResponse resp;
    try {
      resp = await req.close().timeout(
        timeout,
        onTimeout: () => throw ConnectionException(
          'Timed out waiting for MongrelDB after $timeout',
        ),
      );
    } on SocketException catch (e) {
      throw ConnectionException('Connection broken: ${e.message}', cause: e);
    }

    final responseBody = await resp.transform(utf8.decoder).join();

    return Response(resp.statusCode, responseBody);
  }

  /// Release the pooled [HttpClient] and its connections.
  void close() {
    _client?.close(force: true);
    _client = null;
  }
}
