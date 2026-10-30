import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:jianhe_skill_io/jianhe_skill_io.dart';

import '../l10n/app_strings.dart';
import 'backup_file_service_io.dart' show escapeAppleScriptString;
import 'skill_import_service.dart';
import 'windows_dialog_powershell.dart';

/// Windows folder picker for Skill directories; its description comes from
/// the environment (see windows_dialog_powershell.dart).
const windowsSkillFolderDialogScript = r'''
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = $env:JIANHE_DIALOG_TITLE
$dialog.ShowNewFolderButton = $false
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Write($dialog.SelectedPath)
}
''';

/// Windows Open dialog for SKILL.md and Skill ZIP files.
const windowsSkillFileDialogScript = r'''
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName PresentationFramework
$dialog = New-Object Microsoft.Win32.OpenFileDialog
$dialog.Title = $env:JIANHE_DIALOG_TITLE
$dialog.Filter = $env:JIANHE_DIALOG_FILTER
if ($dialog.ShowDialog()) { [Console]::Write($dialog.FileName) }
''';

class NativeSkillImportService implements SkillImportService {
  const NativeSkillImportService({
    this.packageIo = const SkillPackageIo(),
    this.runProcess = Process.run,
  });

  final SkillPackageIo packageIo;

  /// Runs the dialog subprocesses; tests pass a fake.
  final DialogProcessRunner runProcess;

  @override
  Future<ImportedSkillPackage?> importFile() async {
    final path = await _guardIoErrors(_chooseFile);
    return path == null ? null : packageIo.importPath(path);
  }

  @override
  Future<ImportedSkillPackage?> importDirectory() async {
    final path = await _guardIoErrors(_chooseDirectory);
    return path == null ? null : packageIo.importPath(path);
  }

  /// Dialog subprocess failures surface as [SkillImportException] so callers
  /// stay platform-neutral (dart:io types do not exist on web builds).
  Future<String?> _guardIoErrors(Future<String?> Function() choose) async {
    try {
      return await choose();
    } on FileSystemException catch (error) {
      throw SkillImportException(error.message);
    } on ProcessException catch (error) {
      throw SkillImportException(error.message);
    }
  }

  Future<String?> _chooseFile() {
    if (Platform.isWindows) {
      return runWindowsDialog(directory: false);
    }
    if (Platform.isMacOS) return _runMacDialog(directory: false);
    return _runLinuxDialog(directory: false);
  }

  Future<String?> _chooseDirectory() {
    if (Platform.isWindows) {
      return runWindowsDialog(directory: true);
    }
    if (Platform.isMacOS) return _runMacDialog(directory: true);
    return _runLinuxDialog(directory: true);
  }

  /// Shows the Windows folder ([directory]) or file picker and returns the
  /// chosen path, or null when the user cancelled.
  @visibleForTesting
  Future<String?> runWindowsDialog({required bool directory}) {
    final strings = AppStrings.current;
    return runPowerShellDialog(
      runProcess: runProcess,
      script: directory
          ? windowsSkillFolderDialogScript
          : windowsSkillFileDialogScript,
      environment: directory
          ? <String, String>{
              dialogTitleVariable: strings.skillFolderDialogTitle,
            }
          : <String, String>{
              dialogTitleVariable: strings.skillFileDialogTitle,
              dialogFilterVariable: strings.skillFileDialogFilter,
            },
      unavailableMessage: strings.skillPickerUnavailable,
    );
  }

  Future<String?> _runMacDialog({required bool directory}) async {
    final strings = AppStrings.current;
    final prompt = escapeAppleScriptString(
      directory
          ? strings.skillFolderDialogTitle
          : strings.skillFileDialogMacPrompt,
    );
    final script = directory
        ? 'POSIX path of (choose folder with prompt "$prompt")'
        : 'POSIX path of (choose file with prompt "$prompt")';
    final result = await Process.run('osascript', <String>['-e', script]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  }

  Future<String?> _runLinuxDialog({required bool directory}) async {
    final strings = AppStrings.current;
    final result = await Process.run('zenity', <String>[
      '--file-selection',
      if (directory) '--directory',
      '--title=${directory ? strings.skillFolderDialogTitle : strings.skillFileDialogTitle}',
      if (!directory) '--file-filter=${strings.skillFileZenityFilter}',
    ]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  }
}
