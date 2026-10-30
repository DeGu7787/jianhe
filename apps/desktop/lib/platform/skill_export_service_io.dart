import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_skill_io/jianhe_skill_io.dart';

import '../l10n/app_strings.dart';
import 'backup_file_service_io.dart' show escapeAppleScriptString;
import 'skill_export_service.dart';
import 'windows_dialog_powershell.dart';

/// Windows Save As dialog for a Skill ZIP. Its suggested file name comes
/// from the Skill title, i.e. from an imported SKILL.md, so like every
/// dialog script it takes its text from the environment only (see
/// windows_dialog_powershell.dart).
///
/// It opens in the user's Downloads folder (wherever it was relocated to),
/// falling back to the dialog's own default if that cannot be resolved.
const windowsSkillExportDialogScript = r'''
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName PresentationFramework
$dialog = New-Object Microsoft.Win32.SaveFileDialog
$dialog.Title = $env:JIANHE_DIALOG_TITLE
$dialog.Filter = $env:JIANHE_DIALOG_FILTER
$dialog.DefaultExt = '.zip'
$dialog.AddExtension = $true
$dialog.OverwritePrompt = $true
$dialog.FileName = $env:JIANHE_DIALOG_FILE_NAME
$downloads = $null
try {
  $downloads = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
} catch {}
if (-not $downloads) { $downloads = Join-Path $env:USERPROFILE 'Downloads' }
if ($downloads -and (Test-Path -LiteralPath $downloads -PathType Container)) {
  $dialog.InitialDirectory = $downloads
}
if ($dialog.ShowDialog()) { [Console]::Write($dialog.FileName) }
''';

class NativeSkillExportService implements SkillExportService {
  const NativeSkillExportService({
    this.packageIo = const SkillPackageIo(),
    this.runProcess = Process.run,
  });

  final SkillPackageIo packageIo;

  /// Runs the dialog subprocesses; tests pass a fake.
  final DialogProcessRunner runProcess;

  @override
  Future<String?> exportZip({
    required JianheItem skill,
    required SkillPackage? package,
  }) async {
    final suggestedName = SkillPackageIo.suggestedZipFileName(skill.title);
    String? chosen;
    try {
      chosen = await _chooseSavePath(suggestedName);
    } on FileSystemException catch (error) {
      throw SkillExportException(error.message);
    } on ProcessException catch (error) {
      throw SkillExportException(error.message);
    }
    if (chosen == null) return null;
    // The save dialogs confirm overwriting the name they return, so that
    // path may be replaced. A `.zip` appended here was never confirmed and
    // must not silently replace an existing file.
    final hasZipExtension = chosen.toLowerCase().endsWith('.zip');
    final outputPath = hasZipExtension ? chosen : '$chosen.zip';
    await packageIo.exportZip(
      skill: skill,
      package: package,
      outputPath: outputPath,
      force: hasZipExtension,
    );
    return outputPath;
  }

  Future<String?> _chooseSavePath(String suggestedName) {
    if (Platform.isWindows) return runWindowsDialog(suggestedName);
    if (Platform.isMacOS) return _runMacDialog(suggestedName);
    return _runLinuxDialog(suggestedName);
  }

  /// Shows the Windows Save As dialog and returns the chosen path, or null
  /// when the user cancelled.
  @visibleForTesting
  Future<String?> runWindowsDialog(String suggestedName) {
    final strings = AppStrings.current;
    return runPowerShellDialog(
      runProcess: runProcess,
      script: windowsSkillExportDialogScript,
      environment: <String, String>{
        dialogTitleVariable: strings.skillExportDialogTitle,
        dialogFilterVariable: strings.skillZipDialogFilter,
        dialogFileNameVariable: suggestedName,
      },
      unavailableMessage: strings.fileDialogUnavailable,
    );
  }

  Future<String?> _runMacDialog(String suggestedName) async {
    final strings = AppStrings.current;
    final prompt = escapeAppleScriptString(strings.skillExportDialogTitle);
    final name = escapeAppleScriptString(suggestedName);
    final script =
        'POSIX path of (choose file name with prompt "$prompt" '
        'default name "$name" default location (path to downloads folder))';
    final result = await Process.run('osascript', <String>['-e', script]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  }

  Future<String?> _runLinuxDialog(String suggestedName) async {
    final strings = AppStrings.current;
    final home = Platform.environment['HOME'];
    final downloads = home == null ? null : Directory('$home/Downloads');
    final initial = downloads != null && downloads.existsSync()
        ? '${downloads.path}/$suggestedName'
        : suggestedName;
    final result = await Process.run('zenity', <String>[
      '--file-selection',
      '--save',
      '--confirm-overwrite',
      '--title=${strings.skillExportDialogTitle}',
      '--filename=$initial',
      '--file-filter=${strings.skillZipZenityFilter}',
    ]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  }
}
