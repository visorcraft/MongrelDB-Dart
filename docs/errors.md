# Error handling

Every error the Dart client can raise implements [MongrelDBException]. The
client maps HTTP status codes and network failures to specific subtypes so you
can catch exactly the failure modes you care about.

## Hierarchy

```
MongrelDBException (base, implements Exception)
  +-- AuthException        HTTP 401 / 403
  +-- NotFoundException    HTTP 404
  +-- ConstraintException  HTTP 409 (constraint violation at commit)
  +-- ConnectionException  network-level failure (refused, DNS, timeout)
  +-- QueryException       HTTP 400 / 500, malformed payloads
```

## Catching by category

```dart
import 'package:mongreldb/mongreldb.dart';

try {
  await db.put('orders', {1: 1}); // duplicate PK
} on ConstraintException catch (e) {
  print('Constraint: ${e.errorCode}'); // UNIQUE_VIOLATION
} on AuthException catch (e) {
  print('Not authorized: ${e.message}');
} on NotFoundException catch (e) {
  print('Not found: ${e.message}');
} on ConnectionException catch (e) {
  print("Can't reach daemon: ${e.message}");
} on MongrelDBException catch (e) {
  print('Error: ${e.message}');
}
```

## ConstraintException fields

- `message` - human-readable detail from the daemon.
- `errorCode` - the server's error code string, e.g. `UNIQUE_VIOLATION`.
- `opIndex` - when reported, the index of the offending operation within the
  batch (useful when a [Transaction](transactions.md) commit fails).

## Connection failures

`ConnectionException` is raised for any network-level problem: connection
refused, DNS lookup failure, a broken socket mid-request, or a timeout. The
`health()` helper swallows these and returns `false` instead, which is handy
for startup checks:

```dart
if (!await db.health()) {
  // daemon not reachable; degrade gracefully
}
```

## JSON edge cases

The client refuses to send values that have no valid JSON representation:
infinity, NaN, and recursive structures. These raise a `QueryException` at the
client boundary rather than corrupting data on the server. Malformed UTF-8 is
substituted with the replacement character so the surrounding data still lands.
