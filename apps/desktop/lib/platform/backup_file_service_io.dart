import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../l10n/app_strings.dart';
import 'windows_dialog_powershell.dart';

/// Windows Save As dialog for backups and other exported files; its text
/// comes from the environment (see windows_dialog_powershell.dart).
const windowsBackupSaveDialogScript = r'''
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName PresentationFramework
$dialog = New-Object Microsoft.Win32.SaveFileDialog
$dialog.Title = $env:JIANHE_DIALOG_TITLE
$dialog.Filter = $env:JIANHE_DIALOG_FILTER
$dialog.FileName = $env:JIANHE_DIALOG_FILE_NAME
if ($dialog.ShowDialog()) { [Console]::Write($dialog.FileName) }
''';

/// Windows Open dialog for backups.
const windowsBackupOpenDialogScript = r'''
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName PresentationFramework
$dialog = New-Object Microsoft.Win32.OpenFileDialog
$dialog.Title = $env:JIANHE_DIALOG_TITLE
$dialog.Filter = $env:JIANHE_DIALOG_FILTER
if ($dialog.ShowDialog()) { [Console]::Write($dialog.FileName) }
''';

/// Writes [content] to [target] via a same-directory temp file and an
/// atomic rename, so a crash mid-write can never leave the user's backup
/// file half-written.
Future<void> writeBackupFileAtomically(File target, String content) async {
  final temp = File(
    '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    await temp.writeAsString(content, encoding: utf8, flush: true);
    await temp.rename(target.path);
  } on Object {
    try {
      if (temp.existsSync()) temp.deleteSync();
    } on FileSystemException {
      // Best effort only; the original error matters more.
    }
    rethrow;
  }
}

String escapeAppleScriptString(String value) {
  return value
      .replaceAll(RegExp(r'[\r\n]+'), ' ')
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"');
}

class BackupFileService {
  const BackupFileService({this.runProcess = Process.run});

  /// Runs the dialog subprocesses; tests pass a fake.
  final DialogProcessRunner runProcess;

  static const maximumBackupBytes = 100 * 1024 * 1024;

  Future<bool> save(
    String content, {
    required String suggestedName,
    // Empty means the localized default (AppStrings.current).
    String dialogTitle = '',
    String filter = '',
  }) async {
    final strings = AppStrings.current;
    if (utf8.encode(content).length > maximumBackupBytes) {
      throw FormatException(strings.backupTooLarge);
    }
    final path = await _chooseSavePath(
      suggestedName,
      dialogTitle: dialogTitle.isEmpty
          ? strings.backupSaveDialogTitle
          : dialogTitle,
      filter: filter.isEmpty ? strings.backupDialogFilter : filter,
    );
    if (path == null) return false;
    await writeBackupFileAtomically(File(path), content);
    return true;
  }

  Future<({String name, String content})?> open() async {
    final path = await _chooseOpenPath();
    if (path == null) return null;
    final file = File(path);
    if (await file.length() > maximumBackupBytes) {
      throw FormatException(AppStrings.current.backupTooLarge);
    }
    return (
      name: file.uri.pathSegments.last,
      content: await file.readAsString(encoding: utf8),
    );
  }

  Future<String?> _chooseSavePath(
    String suggestedName, {
    required String dialogTitle,
    required String filter,
  }) {
    if (Platform.isWindows) {
      return runWindowsDialog(
        save: true,
        suggestedName: suggestedName,
        dialogTitle: dialogTitle,
        filter: filter,
      );
    }
    if (Platform.isMacOS) {
      return _runMacDialog(
        save: true,
        suggestedName: suggestedName,
        dialogTitle: dialogTitle,
      );
    }
    return _runLinuxDialog(
      save: true,
      suggestedName: suggestedName,
      dialogTitle: dialogTitle,
      filter: filter,
    );
  }

  Future<String?> _chooseOpenPath() {
    if (Platform.isWindows) {
      return runWindowsDialog(save: false);
    }
    if (Platform.isMacOS) {
      return _runMacDialog(save: false);
    }
    return _runLinuxDialog(save: false);
  }

  /// Shows the Windows Save As ([save]) or Open dialog and returns the
  /// chosen path, or null when the user cancelled.
  @visibleForTesting
  Future<String?> runWindowsDialog({
    required bool save,
    String? suggestedName,
    String? dialogTitle,
    String? filter,
  }) {
    final strings = AppStrings.current;
    final defaultTitle = save
        ? strings.backupSaveDialogTitle
        : strings.backupOpenDialogTitle;
    return runPowerShellDialog(
      runProcess: runProcess,
      script: save
          ? windowsBackupSaveDialogScript
          : windowsBackupOpenDialogScript,
      environment: <String, String>{
        dialogTitleVariable: dialogTitle ?? defaultTitle,
        dialogFilterVariable: filter ?? strings.backupDialogFilter,
        if (save) dialogFileNameVariable: suggestedName ?? '',
      },
      unavailableMessage: strings.fileDialogUnavailable,
    );
  }

  Future<String?> _runMacDialog({
    required bool save,
    String? suggestedName,
    String? dialogTitle,
  }) async {
    final strings = AppStrings.current;
    final escapedTitle = escapeAppleScriptString(
      dialogTitle ??
          (save ? strings.backupSaveDialogTitle : strings.backupOpenDialogTitle),
    );
    final escapedName = escapeAppleScriptString(
      suggestedName ?? strings.backupDefaultFileName,
    );
    final script = save
        ? 'POSIX path of (choose file name with prompt '
              '"$escapedTitle" default name "$escapedName")'
        : 'POSIX path of (choose file with prompt "$escapedTitle")';
    final result = await Process.run('osascript', <String>['-e', script]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  }

  Future<String?> _runLinuxDialog({
    required bool save,
    String? suggestedName,
    String? dialogTitle,
    String? filter,
  }) async {
    final strings = AppStrings.current;
    final arguments = <String>[
      '--file-selection',
      if (save) '--save',
      if (save) '--confirm-overwrite',
      '--title=${dialogTitle ?? (save ? strings.backupSaveDialogTitle : strings.backupOpenDialogTitle)}',
      if (save) '--filename=${suggestedName ?? strings.backupDefaultFileName}',
      '--file-filter=${filter ?? strings.backupZenityFilter}',
    ];
    final result = await Process.run('zenity', arguments);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  }
}
