import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/platform/backup_file_service_io.dart';

void main() {
  test('escapes values embedded in a PowerShell single-quoted string', () {
    expect(
      escapePowerShellSingleQuotedString("title'; Start-Process calc; '"),
      "title''; Start-Process calc; ''",
    );
  });

  test('escapes values embedded in an AppleScript string', () {
    expect(
      escapeAppleScriptString('title"\\name\nnext line'),
      r'title\"\\name next line',
    );
  });

  group('writeBackupFileAtomically', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('jianhe-atomic-write-');
    });

    tearDown(() {
      directory.deleteSync(recursive: true);
    });

    bool hasTempResidue() => directory
        .listSync()
        .where((entity) => entity.path.endsWith('.tmp'))
        .isNotEmpty;

    test('writes a new file and leaves no temp residue', () async {
      final target = File('${directory.path}/backup.jianhe');

      await writeBackupFileAtomically(target, '备份内容');

      expect(target.readAsStringSync(), '备份内容');
      expect(hasTempResidue(), isFalse);
    });

    test('replaces an existing file in one step', () async {
      final target = File('${directory.path}/backup.jianhe');
      target.writeAsStringSync('旧备份');

      await writeBackupFileAtomically(target, '新备份');

      expect(target.readAsStringSync(), '新备份');
      expect(hasTempResidue(), isFalse);
    });

    test('rethrows and leaves the target untouched when the write fails',
        () async {
      final target = File('${directory.path}/missing-dir/backup.jianhe');

      await expectLater(
        writeBackupFileAtomically(target, 'x'),
        throwsA(isA<FileSystemException>()),
      );
      expect(target.existsSync(), isFalse);
    });

    test('cleans the temp file when the rename fails', () async {
      final occupied = Directory('${directory.path}/occupied')..createSync();

      await expectLater(
        writeBackupFileAtomically(File(occupied.path), 'x'),
        throwsA(isA<FileSystemException>()),
      );
      expect(occupied.existsSync(), isTrue);
      expect(hasTempResidue(), isFalse);
    });
  });
}
