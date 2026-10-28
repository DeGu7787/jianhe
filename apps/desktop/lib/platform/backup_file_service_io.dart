import 'dart:convert';
import 'dart:io';

import '../l10n/app_strings.dart';

String escapePowerShellSingleQuotedString(String value) {
  return value.replaceAll("'", "''");
}

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
  const BackupFileService();

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
      return _runWindowsDialog(
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
      return _runWindowsDialog(save: false);
    }
    if (Platform.isMacOS) {
      return _runMacDialog(save: false);
    }
    return _runLinuxDialog(save: false);
  }

  Future<String?> _runWindowsDialog({
    required bool save,
    String? suggestedName,
    String? dialogTitle,
    String? filter,
  }) async {
    final strings = AppStrings.current;
    final escapedName = escapePowerShellSingleQuotedString(suggestedName ?? '');
    final escapedTitle = escapePowerShellSingleQuotedString(
      dialogTitle ??
          (save ? strings.backupSaveDialogTitle : strings.backupOpenDialogTitle),
    );
    final escapedFilter = escapePowerShellSingleQuotedString(
      filter ?? strings.backupDialogFilter,
    );
    final dialogType = save ? 'SaveFileDialog' : 'OpenFileDialog';
    final script =
        '''
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding(\$false)
Add-Type -AssemblyName PresentationFramework
\$dialog = New-Object Microsoft.Win32.$dialogType
\$dialog.Title = '$escapedTitle'
\$dialog.Filter = '$escapedFilter'
${save ? "\$dialog.FileName = '$escapedName'" : ''}
if (\$dialog.ShowDialog()) { [Console]::Write(\$dialog.FileName) }
''';
    final result = await Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-STA',
      '-Command',
      script,
    ], stdoutEncoding: utf8);
    if (result.exitCode != 0) {
      throw FileSystemException(strings.fileDialogUnavailable);
    }
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
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
