import 'dart:async';
import 'dart:io';

/// Serializes one critical section both inside this process and across other
/// JianHe processes that use the same lock file.
///
/// Windows releases the OS file lock when a process exits, so a crashed
/// background worker cannot leave a permanent lock behind.
class ProcessFileLock {
  ProcessFileLock(this.file);

  final File file;
  Future<void> _queue = Future<void>.value();

  Future<T> runExclusive<T>(Future<T> Function() action) {
    final result = _queue.then((_) => _runLocked(action));
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<T> _runLocked<T>(Future<T> Function() action) async {
    await file.parent.create(recursive: true);
    final handle = await file.open(mode: FileMode.append);
    var locked = false;
    try {
      await handle.lock(FileLock.blockingExclusive);
      locked = true;
      return await action();
    } finally {
      if (locked) await handle.unlock();
      await handle.close();
    }
  }
}
