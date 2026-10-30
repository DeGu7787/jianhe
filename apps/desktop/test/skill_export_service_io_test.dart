import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/platform/skill_export_service_io.dart';
import 'package:jianhe_desktop/platform/windows_dialog_powershell.dart';

import 'fake_dialog_process_runner.dart';

void main() {
  test('passes a hostile suggested name as data', () async {
    final runner = FakeDialogProcessRunner(
      stdout: 'C:\\Users\\me\\Downloads\\x.zip\r\n',
    );
    final service = NativeSkillExportService(runProcess: runner.call);

    final path = await service.runWindowsDialog('$hostileDialogText.zip');

    expect(path, 'C:\\Users\\me\\Downloads\\x.zip');
    final call = runner.calls.single;
    expect(call.executable, 'powershell.exe');
    expect(call.script, windowsSkillExportDialogScript);
    expect(call.arguments.join('\n'), isNot(contains('Set-Content')));
    expect(
      call.environment?[dialogFileNameVariable],
      '$hostileDialogText.zip',
    );
    expect(call.environment?[dialogTitleVariable], isNotEmpty);
    expect(call.environment?[dialogFilterVariable], isNotEmpty);
  });

  test('returns null when the dialog is cancelled', () async {
    final service = NativeSkillExportService(
      runProcess: FakeDialogProcessRunner().call,
    );

    expect(await service.runWindowsDialog('skill.zip'), isNull);
  });

  test('reports a dialog PowerShell cannot show', () async {
    final service = NativeSkillExportService(
      runProcess: FakeDialogProcessRunner(exitCode: 1).call,
    );

    await expectLater(
      service.runWindowsDialog('skill.zip'),
      throwsA(isA<FileSystemException>()),
    );
  });
}
