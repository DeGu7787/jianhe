import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_desktop/features/app_update/app_update_platform_io.dart';

void main() {
  test('installer vendors every non-compiler language file it references', () {
    final installer = File('installer/jianhe_installer.iss');
    expect(installer.existsSync(), isTrue);

    final script = installer.readAsStringSync();
    final references = RegExp(
      r'MessagesFile:\s*"([^"]+\.isl)"',
      caseSensitive: false,
    ).allMatches(script).map((match) => match.group(1)!).toList();

    expect(references, contains(r'translations\ChineseSimplified.isl'));
    for (final reference in references.where(
      (path) => !path.toLowerCase().startsWith('compiler:'),
    )) {
      expect(
        File('installer/${reference.replaceAll(r'\', '/')}').existsSync(),
        isTrue,
        reason: 'Missing installer language file: $reference',
      );
    }
    expect(
      File('installer/translations/ChineseSimplified.LICENSE').existsSync(),
      isTrue,
    );
  });

  test('installer includes every Windows plugin DLL from Release', () {
    final script = File('installer/jianhe_installer.iss').readAsStringSync();

    expect(
      script,
      contains(
        r'Source: "..\build\windows\x64\runner\Release\*.dll"; DestDir: "{app}"',
      ),
      reason:
          'The secure-storage plugin is emitted as a Release-root DLL and must be installed.',
    );
  });

  test('self-update mode waits for the app, keeps setup alive and relaunches', () {
    final script = File('installer/jianhe_installer.iss').readAsStringSync();
    final runner = File('windows/runner/main.cpp').readAsStringSync();

    // The app launches setup as /JIANHEUPDATE (lib/features/app_update).
    expect(script, contains("'/JIANHEUPDATE'"));
    expect(
      script,
      contains(r'Filename: "{app}\{#MyAppExeName}"; Flags: nowait; Check: IsJianHeUpdate'),
      reason: 'A silent update must reopen the app (skipifsilent skips the normal entry).',
    );
    expect(script, contains('WaitForJianHeToExit();'));

    // The installer polls the same mutex the foreground app holds.
    final appId = RegExp(r'#define MyAppId "([^"]+)"').firstMatch(script)!.group(1)!;
    expect(script, contains(r"JianHeForegroundMutex = 'Local\JianHeDesktop-{#MyAppId}'"));
    expect(runner, contains('L"Local\\\\JianHeDesktop-$appId"'));
  });

  test('installer hands its language choice to the app once', () {
    final script = File(
      'installer/jianhe_installer.iss',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final handoff = File(
      'windows/runner/installer_language_handoff.cpp',
    ).readAsStringSync();

    // Every manual install shows the language dialog instead of silently
    // reusing the previous language.
    expect(script, contains('ShowLanguageDialog=yes'));
    expect(script, contains('UsePreviousLanguage=no'));
    // Self-update and scripted silent installs never override the in-app
    // language setting.
    expect(
      script,
      contains(
        "if (not IsJianHeUpdate()) and (not WizardSilent()) then\n"
        "      RegWriteStringValue(HKCU, JianHeRegistryKey, 'InstallerLanguage',\n"
        "                          ActiveLanguage());",
      ),
    );
    expect(handoff, contains('L"InstallerLanguage"'));
    expect(handoff, contains('L"Software\\\\JianHe"'));
    // Both languages define every custom message the script uses.
    const builtIn = {'CreateDesktopIcon', 'AdditionalIcons', 'LaunchProgram'};
    final used = RegExp(r"\{cm:(\w+)|CustomMessage\('(\w+)'\)")
        .allMatches(script)
        .map((match) => match.group(1) ?? match.group(2)!)
        .where((name) => !builtIn.contains(name))
        .toSet();
    expect(used, contains('AppDisplayName'));
    for (final name in used) {
      expect(script, contains('chinesesimplified.$name='), reason: name);
      expect(script, contains('english.$name='), reason: name);
    }
  });

  test('self-update passes the app language as an installer language', () {
    final script = File('installer/jianhe_installer.iss').readAsStringSync();
    final declared = RegExp(r'^Name: "(\w+)"; MessagesFile:', multiLine: true)
        .allMatches(script.replaceAll('\r\n', '\n'))
        .map((match) => match.group(1))
        .toSet();
    expect(declared, <String>{'chinesesimplified', 'english'});
    for (final language in AppLanguage.values) {
      final argument = installerLanguageArgument(language);
      expect(argument, startsWith('/LANG='));
      expect(declared, contains(argument.substring('/LANG='.length)));
    }
    expect(installerLanguageArgument(AppLanguage.en), '/LANG=english');
  });
}
