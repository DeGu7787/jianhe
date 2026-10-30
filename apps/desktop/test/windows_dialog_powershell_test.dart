import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/platform/backup_file_service_io.dart';
import 'package:jianhe_desktop/platform/skill_export_service_io.dart';
import 'package:jianhe_desktop/platform/skill_import_service_io.dart';
import 'package:jianhe_desktop/platform/windows_dialog_powershell.dart';

import 'fake_dialog_process_runner.dart';

const _scripts = <String, String>{
  'backup save': windowsBackupSaveDialogScript,
  'backup open': windowsBackupOpenDialogScript,
  'skill file': windowsSkillFileDialogScript,
  'skill folder': windowsSkillFolderDialogScript,
  'skill export': windowsSkillExportDialogScript,
};

void main() {
  group('runPowerShellDialog', () {
    test('runs the script with its text in the environment', () async {
      final runner = FakeDialogProcessRunner(stdout: 'C:\\out\\a.zip\r\n');

      final path = await runPowerShellDialog(
        runProcess: runner.call,
        script: 'the script',
        environment: <String, String>{dialogTitleVariable: hostileDialogText},
        unavailableMessage: 'unavailable',
      );

      expect(path, 'C:\\out\\a.zip');
      final call = runner.calls.single;
      expect(call.executable, 'powershell.exe');
      expect(call.arguments, powerShellDialogArguments('the script'));
      expect(call.environment, <String, String>{
        dialogTitleVariable: hostileDialogText,
      });
    });

    test('returns null when the dialog is cancelled', () async {
      expect(
        await runPowerShellDialog(
          runProcess: FakeDialogProcessRunner().call,
          script: 's',
          environment: const <String, String>{},
          unavailableMessage: 'unavailable',
        ),
        isNull,
      );
    });

    test('throws the given message when PowerShell fails', () async {
      await expectLater(
        runPowerShellDialog(
          runProcess: FakeDialogProcessRunner(exitCode: 1).call,
          script: 's',
          environment: const <String, String>{},
          unavailableMessage: 'unavailable',
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            'unavailable',
          ),
        ),
      );
    });
  });

  group('dialog scripts', () {
    for (final MapEntry(key: name, value: script) in _scripts.entries) {
      test('$name reads its text only from the dialog variables', () {
        final variables = RegExp(
          r'\$env:(\w+)',
        ).allMatches(script).map((match) => match.group(1)).toSet();
        expect(
          variables.difference(<String>{'USERPROFILE'}),
          everyElement(
            isIn(<String>[
              dialogTitleVariable,
              dialogFilterVariable,
              dialogFileNameVariable,
            ]),
          ),
        );
        expect(variables, contains(dialogTitleVariable));
        expect(
          script,
          isNot(matches(RegExp(r"\.(Title|Filter|FileName|Description) = '"))),
        );
      });
    }
  });

  test(
    'Windows PowerShell treats hostile dialog text as data',
    () async {
      final directory = Directory.systemTemp.createTempSync('jianhe-dialog-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final marker = File(
        '${directory.path}${Platform.pathSeparator}jianhe-injected',
      );
      for (final MapEntry(key: name, value: script) in _scripts.entries) {
        // Everything but the modal dialog itself: print what the dialog
        // would have been given instead of showing it.
        final showDialog = RegExp(r'if \(\$dialog\.ShowDialog\(\)[^)]*\)');
        expect(showDialog.allMatches(script), hasLength(1), reason: name);
        final result = await Process.run(
          'powershell.exe',
          powerShellDialogArguments(
            script.replaceFirst(showDialog, r'if ($true)'),
          ),
          workingDirectory: directory.path,
          environment: <String, String>{
            dialogTitleVariable: hostileDialogText,
            dialogFilterVariable: '$hostileDialogText (*.zip)|*.zip',
            dialogFileNameVariable: '$hostileDialogText.zip',
          },
          stdoutEncoding: utf8,
        );

        expect(result.exitCode, 0, reason: '$name: ${result.stderr}');
        expect(marker.existsSync(), isFalse, reason: '$name ran its text');
        if (script.contains('FileName = \$env:$dialogFileNameVariable')) {
          expect(
            (result.stdout as String).trim(),
            '$hostileDialogText.zip',
            reason: name,
          );
        }
      }
    },
    skip: Platform.isWindows ? false : 'needs Windows PowerShell',
  );
}
