import 'dart:convert';
import 'dart:io';

import 'package:jianhe_skill_io/jianhe_skill_io.dart';

import '../l10n/app_strings.dart';
import 'backup_file_service_io.dart'
    show escapeAppleScriptString, escapePowerShellSingleQuotedString;
import 'skill_import_service.dart';

class NativeSkillImportService implements SkillImportService {
  const NativeSkillImportService({this.packageIo = const SkillPackageIo()});

  final SkillPackageIo packageIo;

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
      return _runWindowsDialog(directory: false);
    }
    if (Platform.isMacOS) return _runMacDialog(directory: false);
    return _runLinuxDialog(directory: false);
  }

  Future<String?> _chooseDirectory() {
    if (Platform.isWindows) {
      return _runWindowsDialog(directory: true);
    }
    if (Platform.isMacOS) return _runMacDialog(directory: true);
    return _runLinuxDialog(directory: true);
  }

  Future<String?> _runWindowsDialog({required bool directory}) async {
    final strings = AppStrings.current;
    final folderTitle = escapePowerShellSingleQuotedString(
      strings.skillFolderDialogTitle,
    );
    final fileTitle = escapePowerShellSingleQuotedString(
      strings.skillFileDialogTitle,
    );
    final fileFilter = escapePowerShellSingleQuotedString(
      strings.skillFileDialogFilter,
    );
    final script = directory
        ? '''
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding(\$false)
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
\$dialog.Description = '$folderTitle'
\$dialog.ShowNewFolderButton = \$false
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Write(\$dialog.SelectedPath)
}
'''
        : '''
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding(\$false)
Add-Type -AssemblyName PresentationFramework
\$dialog = New-Object Microsoft.Win32.OpenFileDialog
\$dialog.Title = '$fileTitle'
\$dialog.Filter = '$fileFilter'
if (\$dialog.ShowDialog()) { [Console]::Write(\$dialog.FileName) }
''';
    final result = await Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-STA',
      '-Command',
      script,
    ], stdoutEncoding: utf8);
    if (result.exitCode != 0) {
      throw FileSystemException(strings.skillPickerUnavailable);
    }
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
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
