import 'dart:convert';
import 'dart:io';

/// A Skill title as a malicious SKILL.md could set it. PowerShell treats the
/// curly quotes as single quotes, so splicing this into a quoted literal
/// would end the string and run Set-Content in the working directory.
const hostileDialogText = 'x’; Set-Content -Path jianhe-injected -Value 1; ’';

/// One recorded dialog subprocess call.
class DialogProcessCall {
  DialogProcessCall(this.executable, this.arguments, this.environment);

  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;

  /// The PowerShell script passed after `-Command`.
  String get script => arguments.last;
}

/// Stands in for Process.run: records each call and answers with [stdout]
/// and [exitCode].
class FakeDialogProcessRunner {
  FakeDialogProcessRunner({this.stdout = '', this.exitCode = 0});

  final String stdout;
  final int exitCode;
  final calls = <DialogProcessCall>[];

  Future<ProcessResult> call(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    Encoding? stdoutEncoding,
  }) async {
    calls.add(DialogProcessCall(executable, arguments, environment));
    return ProcessResult(1, exitCode, stdout, '');
  }
}
