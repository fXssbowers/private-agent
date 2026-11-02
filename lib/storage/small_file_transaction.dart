import 'dart:io';

/// Serializes small, synchronous file transactions across the app's Flutter
/// engines. POSIX advisory locks alone do not exclude same-process isolates.
Future<T> smallFileTransaction<T>(
  Directory directory,
  String name,
  T Function() transaction,
) async {
  await directory.create(recursive: true);
  // Android components in this app share one OS process, but have multiple
  // Dart isolates. PID-scoped exclusive creation also permits recovery after
  // a full process restart without stealing a live isolate's lock.
  final lock = File('${directory.path}/.$name.$pid.lock');
  final oldLocks = RegExp('^\\.$name\\.([0-9]+)\\.lock\$');
  for (final file in directory.listSync(followLinks: false).whereType<File>()) {
    if (oldLocks.hasMatch(file.uri.pathSegments.last) &&
        file.path != lock.path) {
      try {
        file.deleteSync();
      } on FileSystemException {
        /* Another engine cleaned it. */
      }
    }
  }
  for (var attempt = 0; attempt < 30; attempt++) {
    try {
      lock.createSync(exclusive: true);
    } on PathExistsException {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      continue;
    }
    try {
      // No await inside the critical section. A busy or abandoned lock fails
      // safely rather than stealing ownership from another Flutter engine.
      return transaction();
    } finally {
      lock.deleteSync();
    }
  }
  throw const FileSystemException(
    'Memory storage is busy; restart the app if it persists.',
  );
}
