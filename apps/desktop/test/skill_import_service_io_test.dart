import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/platform/skill_import_service_io.dart';
import 'package:jianhe_desktop/platform/windows_dialog_powershell.dart';

import 'fake_dialog_process_runner.dart';

void main() {
  test('the folder picker gets its description as data', () async {
    final runner = FakeDialogProcessRunner(stdout: 'C:\\skills\\writer\r\n');
    final service = NativeSkillImportService(runProcess: runner.call);

    expect(
      await service.runWindowsDialog(directory: true),
      'C:\\skills\\writer',
    );

    final call = runner.calls.single;
    expect(call.executable, 'powershell.exe');
    expect(call.script, windowsSkillFolderDialogScript);
    expect(call.environment?.keys, <String>[dialogTitleVariable]);
    expect(call.environment?[dialogTitleVariable], isNotEmpty);
  });

  test('the file picker gets its title and filter as data', () async {
    final runner = FakeDialogProcessRunner();
    final service = NativeSkillImportService(runProcess: runner.call);

    expect(await service.runWindowsDialog(directory: false), isNull);

    final call = runner.calls.single;
    expect(call.script, windowsSkillFileDialogScript);
    expect(call.environment?.keys, <String>[
      dialogTitleVariable,
      dialogFilterVariable,
    ]);
  });

  test('reports a picker PowerShell cannot show', () async {
    final service = NativeSkillImportService(
      runProcess: FakeDialogProcessRunner(exitCode: 1).call,
    );

    await expectLater(
      service.runWindowsDialog(directory: true),
      throwsA(isA<FileSystemException>()),
    );
  });
}
