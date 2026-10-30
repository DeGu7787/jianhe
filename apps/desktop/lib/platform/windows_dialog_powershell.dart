/// Native Windows file dialogs run as a PowerShell script.
///
/// Every dialog script is a compile-time constant. The text a dialog shows
/// (title, filter, suggested file name) reaches PowerShell only through the
/// environment variables below and is read with `$env:`, so it is never
/// parsed as code. Do not splice values into a script, escaped or not: a
/// suggested file name can come from an imported Skill, and PowerShell also
/// treats ‘ ’ ‚ ‛ as single quotes, which no ASCII-only escaping covers.
library;

import 'dart:convert';
import 'dart:io';

/// Dialog title (or a folder dialog's description).
const dialogTitleVariable = 'JIANHE_DIALOG_TITLE';

/// File type filter, in `Description|*.ext` form.
const dialogFilterVariable = 'JIANHE_DIALOG_FILTER';

/// File name a Save As dialog suggests.
const dialogFileNameVariable = 'JIANHE_DIALOG_FILE_NAME';

/// Runs a child process: [Process.run] in production, a fake in tests.
typedef DialogProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
      Encoding? stdoutEncoding,
    });

/// The powershell.exe arguments that run [script].
List<String> powerShellDialogArguments(String script) => <String>[
  '-NoProfile',
  '-STA',
  '-Command',
  script,
];

/// Runs a dialog [script] with [environment] and returns the path it
/// printed, or null when the user cancelled. Throws a [FileSystemException]
/// with [unavailableMessage] when PowerShell fails.
Future<String?> runPowerShellDialog({
  required DialogProcessRunner runProcess,
  required String script,
  required Map<String, String> environment,
  required String unavailableMessage,
}) async {
  final result = await runProcess(
    'powershell.exe',
    powerShellDialogArguments(script),
    environment: environment,
    stdoutEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw FileSystemException(unavailableMessage);
  }
  final path = (result.stdout as String).trim();
  return path.isEmpty ? null : path;
}
