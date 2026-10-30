import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/platform/backup_file_service_io.dart';
import 'package:jianhe_desktop/platform/windows_dialog_powershell.dart';

import 'fake_dialog_process_runner.dart';

void main() {
  group('Windows dialogs', () {
    test('Save As passes title, filter and file name as data', () async {
      final runner = FakeDialogProcessRunner(stdout: 'C:\\b\\x.jianhe');
      final service = BackupFileService(runProcess: runner.call);

      final path = await service.runWindowsDialog(
        save: true,
        suggestedName: hostileDialogText,
        dialogTitle: 'Save backup',
        filter: 'JianHe (*.jianhe)|*.jianhe',
      );

      expect(path, 'C:\\b\\x.jianhe');
      final call = runner.calls.single;
      expect(call.script, windowsBackupSaveDialogScript);
      expect(call.arguments.join('\n'), isNot(contains('Set-Content')));
      expect(call.environment, <String, String>{
        dialogTitleVariable: 'Save backup',
        dialogFilterVariable: 'JianHe (*.jianhe)|*.jianhe',
        dialogFileNameVariable: hostileDialogText,
      });
    });

    test('Open uses the localized defaults and no file name', () async {
      final runner = FakeDialogProcessRunner();
      final service = BackupFileService(runProcess: runner.call);

      expect(await service.runWindowsDialog(save: false), isNull);

      final call = runner.calls.single;
      expect(call.script, windowsBackupOpenDialogScript);
      expect(call.environment?.keys, <String>[
        dialogTitleVariable,
        dialogFilterVariable,
      ]);
      expect(call.environment?[dialogTitleVariable], isNotEmpty);
    });

    test('reports a dialog PowerShell cannot show', () async {
      final service = BackupFileService(
        runProcess: FakeDialogProcessRunner(exitCode: 1).call,
      );

      await expectLater(
        service.runWindowsDialog(save: false),
        throwsA(isA<FileSystemException>()),
      );
    });
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
