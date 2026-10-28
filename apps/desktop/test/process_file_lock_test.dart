import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/platform/process_file_lock.dart';

void main() {
  test('separate lock instances serialize the same lock file', () async {
    final directory = await Directory.systemTemp.createTemp(
      'jianhe-process-lock-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}sync.lock';
    final firstLock = ProcessFileLock(File(path));
    final secondLock = ProcessFileLock(File(path));
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    var secondEntered = false;

    final first = firstLock.runExclusive(() async {
      firstEntered.complete();
      await releaseFirst.future;
    });
    await firstEntered.future;

    final second = secondLock.runExclusive(() async {
      secondEntered = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(secondEntered, isFalse);

    releaseFirst.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(secondEntered, isTrue);
  });

  test('an exception releases the file lock for the next caller', () async {
    final directory = await Directory.systemTemp.createTemp(
      'jianhe-process-lock-error-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}sync.lock';
    final firstLock = ProcessFileLock(File(path));
    final secondLock = ProcessFileLock(File(path));

    await expectLater(
      firstLock.runExclusive<void>(() async => throw StateError('failed')),
      throwsStateError,
    );

    var entered = false;
    await secondLock.runExclusive(() async => entered = true);
    expect(entered, isTrue);
  });
}
