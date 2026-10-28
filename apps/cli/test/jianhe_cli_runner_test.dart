import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:jianhe_cli/jianhe_cli.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_storage/jianhe_storage.dart';
import 'package:test/test.dart';

void main() {
  test('help discovers Skill import and export commands and options', () async {
    final topLevelOutput = <String>[];
    final topLevelCode = await JianheCliRunner(
      out: topLevelOutput.add,
      error: fail,
    ).run(<String>['--help']);

    expect(topLevelCode, 0);
    expect(
      topLevelOutput.join('\n'),
      contains('skill import|inspect|files|read|context|scan|index|export'),
    );
    expect(topLevelOutput.join('\n'), contains('jianhe skill --help'));

    final skillOutput = <String>[];
    final skillCode = await JianheCliRunner(
      out: skillOutput.add,
      error: fail,
    ).run(<String>['skill', '--help']);

    expect(skillCode, 0);
    expect(skillOutput.join('\n'), contains('import <path>'));
    expect(skillOutput.join('\n'), contains('context <id>'));
    expect(skillOutput.join('\n'), contains('scan'));
    expect(skillOutput.join('\n'), contains('index'));
    expect(skillOutput.join('\n'), contains('export <id> --output <path>'));
    expect(skillOutput.join('\n'), contains('view/invoke:'));
    expect(skillOutput.join('\n'), contains('create/import:'));
    expect(skillOutput.join('\n'), contains('summarize environment:'));

    final importOutput = <String>[];
    final importCode = await JianheCliRunner(
      out: importOutput.add,
      error: fail,
    ).run(<String>['skill', 'import', '--help']);

    expect(importCode, 0);
    expect(importOutput.first, contains('skill import <path>'));
    expect(importOutput.join('\n'), contains('--dry-run'));
    expect(importOutput.join('\n'), contains('--category'));

    final exportOutput = <String>[];
    final exportCode = await JianheCliRunner(
      out: exportOutput.add,
      error: fail,
    ).run(<String>['skill', 'export', '--help']);

    expect(exportCode, 0);
    expect(exportOutput.first, contains('skill export <id>'));
    expect(exportOutput.join('\n'), contains('--format'));
    expect(exportOutput.join('\n'), contains('--force'));

    final scanOutput = <String>[];
    final scanCode = await JianheCliRunner(
      out: scanOutput.add,
      error: fail,
    ).run(<String>['skill', 'scan', '--help']);
    expect(scanCode, 0);
    expect(scanOutput.join('\n'), contains('--provider'));
    expect(scanOutput.join('\n'), contains('--root'));

    final indexOutput = <String>[];
    final indexCode = await JianheCliRunner(
      out: indexOutput.add,
      error: fail,
    ).run(<String>['skill', 'index', '--help']);
    expect(indexCode, 0);
    expect(indexOutput.join('\n'), contains('--dry-run'));
    expect(indexOutput.join('\n'), contains('--import'));
  });

  test('help describes status, item, and compose commands', () async {
    Future<String> helpFor(List<String> arguments) async {
      final output = <String>[];
      final code = await JianheCliRunner(
        out: output.add,
        error: fail,
      ).run(arguments);
      expect(code, 0);
      return output.join('\n');
    }

    expect(await helpFor(['status', '--help']), contains('status [--json]'));
    expect(await helpFor(['item', '--help']), contains('search <query>'));
    expect(
      await helpFor(['item', 'search', '--help']),
      allOf(contains('item search <query>'), contains('--type')),
    );
    expect(
      await helpFor(['compose', '--help']),
      allOf(contains('--prompt <id>'), contains('--input-file')),
    );
  });

  test('content commands are denied while CLI access is disabled', () async {
    final output = <String>[];
    final errors = <String>[];
    final storage = await _seedStorage(enabled: false);
    final runner = JianheCliRunner(
      out: output.add,
      error: errors.add,
      storageFactory: (_, {readOnly = false}) => storage,
      environment: const {'JIANHE_DATA_DIR': 'test-data'},
    );

    final exitCode = await runner.run(['item', 'list', '--json']);

    expect(exitCode, 4);
    expect(output, isEmpty);
    expect(errors.single, contains('disabled'));
  });

  test('search returns machine-readable summaries without content', () async {
    final output = <String>[];
    final storage = await _seedStorage(enabled: true);
    final runner = JianheCliRunner(
      out: output.add,
      error: fail,
      storageFactory: (_, {readOnly = false}) => storage,
      environment: const {'JIANHE_DATA_DIR': 'test-data'},
    );

    final exitCode = await runner.run([
      'item',
      'search',
      '会议',
      '--type',
      'prompt',
      '--json',
    ]);
    final payload = jsonDecode(output.single) as Map<String, Object?>;
    final items = payload['items'] as List<Object?>;
    final first = items.single as Map<String, Object?>;

    expect(exitCode, 0);
    expect(first['title'], '会议总结');
    expect(first, isNot(contains('content')));
  });

  test('compose reads stdin and uses the shared composition engine', () async {
    final output = <String>[];
    final storage = await _seedStorage(enabled: true);
    final runner = JianheCliRunner(
      out: output.add,
      error: fail,
      readStdin: () async => '完成 MVP 原型',
      storageFactory: (_, {readOnly = false}) => storage,
      environment: const {'JIANHE_DATA_DIR': 'test-data'},
    );

    final exitCode = await runner.run([
      'compose',
      '--prompt',
      'prompt-1',
      '--input-file',
      '-',
    ]);

    expect(exitCode, 0);
    expect(output.single, '请总结：\n完成 MVP 原型');
  });

  test('compose uses the separator of the device interface language', () async {
    Future<String> composeWith(AppLanguage? language) async {
      final output = <String>[];
      final storage = await _seedStorage(enabled: true);
      await storage.items.save(
        JianheItem.create(
          id: 'prompt-2',
          type: ItemType.prompt,
          title: 'Summary',
          content: 'Summarize',
        ),
      );
      if (language != null) storage.settings.setUiLanguage(language);
      final exitCode = await JianheCliRunner(
        out: output.add,
        error: fail,
        storageFactory: (_, {readOnly = false}) => storage,
        environment: const {'JIANHE_DATA_DIR': 'test-data'},
      ).run(['compose', '--prompt', 'prompt-2', '--input', 'Body']);
      expect(exitCode, 0);
      return output.single;
    }

    expect(await composeWith(null), 'Summarize\n\n---\n待处理内容：\nBody');
    expect(await composeWith(AppLanguage.zh), 'Summarize\n\n---\n待处理内容：\nBody');
    expect(await composeWith(AppLanguage.en), 'Summarize\n\n---\nInput:\nBody');
  });

  test('imports, reads, and exports a complete Skill package', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-cli-skill-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final dataDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}data',
    )..createSync();
    final source = Directory('${directory.path}${Platform.pathSeparator}source')
      ..createSync();
    File(
      '${source.path}${Platform.pathSeparator}SKILL.md',
    ).writeAsStringSync('---\nname: Package Test\n---\n# Instructions');
    final reference = File(
      '${source.path}${Platform.pathSeparator}references'
      '${Platform.pathSeparator}guide.md',
    );
    reference.parent.createSync(recursive: true);
    reference.writeAsStringSync('# Guide');
    final asset = File(
      '${source.path}${Platform.pathSeparator}assets'
      '${Platform.pathSeparator}icon.bin',
    );
    asset.parent.createSync(recursive: true);
    asset.writeAsBytesSync(<int>[0, 1, 2, 255]);

    final database = JianheStorageDatabase.open(
      '${dataDirectory.path}${Platform.pathSeparator}jianhe.db',
    );
    database.settings.setCliAccessMode(CliAccessMode.readWrite);
    // Simulate a database written by the former split-permission model.
    database.settings.write('cli_skill_import_enabled', 'false');
    database.close();

    final importOutput = <String>[];
    final importRunner = JianheCliRunner(
      out: importOutput.add,
      error: fail,
      environment: <String, String>{'JIANHE_DATA_DIR': dataDirectory.path},
    );
    final importCode = await importRunner.run(<String>[
      'skill',
      'import',
      source.path,
      '--json',
    ]);
    final imported = jsonDecode(importOutput.single) as Map<String, Object?>;
    final skillId = imported['skill_id'] as String;

    expect(importCode, 0);
    expect(imported['title'], 'Package Test');
    expect(imported['file_count'], 3);
    expect(imported['cloud_syncable'], isTrue);
    expect(imported.containsKey('warning'), isFalse);

    final duplicateOutput = <String>[];
    final duplicateCode = await JianheCliRunner(
      out: duplicateOutput.add,
      error: fail,
      environment: <String, String>{'JIANHE_DATA_DIR': dataDirectory.path},
    ).run(<String>['skill', 'import', source.path, '--json']);
    expect(duplicateCode, 0);
    expect(
      (jsonDecode(duplicateOutput.single) as Map<String, Object?>)['status'],
      'already_exists',
    );

    final filesOutput = <String>[];
    final filesCode = await JianheCliRunner(
      out: filesOutput.add,
      error: fail,
      environment: <String, String>{'JIANHE_DATA_DIR': dataDirectory.path},
    ).run(<String>['skill', 'files', skillId, '--json']);
    final filesPayload = jsonDecode(filesOutput.single) as Map<String, Object?>;

    expect(filesCode, 0);
    expect(filesPayload['files'], hasLength(3));

    final contextOutput = <String>[];
    final contextCode = await JianheCliRunner(
      out: contextOutput.add,
      error: fail,
      environment: <String, String>{'JIANHE_DATA_DIR': dataDirectory.path},
    ).run(<String>['skill', 'context', skillId, '--json']);
    final contextPayload =
        jsonDecode(contextOutput.single) as Map<String, Object?>;

    expect(contextCode, 0);
    expect(contextPayload['schema'], 'jianhe.skill-context/v1');
    expect(contextPayload['instructions'], contains('# Instructions'));
    expect(contextPayload['files'], hasLength(3));

    final readOutput = <String>[];
    final readCode = await JianheCliRunner(
      out: readOutput.add,
      error: fail,
      environment: <String, String>{'JIANHE_DATA_DIR': dataDirectory.path},
    ).run(<String>['skill', 'read', skillId, 'references/guide.md', '--raw']);

    expect(readCode, 0);
    expect(readOutput.single, '# Guide');

    final zipPath = '${directory.path}${Platform.pathSeparator}export.zip';
    final exportCode =
        await JianheCliRunner(
          out: (_) {},
          error: fail,
          environment: <String, String>{'JIANHE_DATA_DIR': dataDirectory.path},
        ).run(<String>[
          'skill',
          'export',
          skillId,
          '--output',
          zipPath,
          '--format',
          'zip',
        ]);
    final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());

    expect(exportCode, 0);
    expect(
      archive.files.where((file) => file.isFile).map((file) => file.name),
      containsAll(<String>[
        'SKILL.md',
        'references/guide.md',
        'assets/icon.bin',
      ]),
    );

    final directoryOutput =
        '${directory.path}${Platform.pathSeparator}exported-directory';
    final directoryCode =
        await JianheCliRunner(
          out: (_) {},
          error: fail,
          environment: <String, String>{'JIANHE_DATA_DIR': dataDirectory.path},
        ).run(<String>[
          'skill',
          'export',
          skillId,
          '--output',
          directoryOutput,
          '--format',
          'directory',
        ]);

    expect(directoryCode, 0);
    expect(
      File(
        '$directoryOutput${Platform.pathSeparator}references'
        '${Platform.pathSeparator}guide.md',
      ).readAsStringSync(),
      '# Guide',
    );

    final binaryOutput =
        '${directory.path}${Platform.pathSeparator}read-icon.bin';
    final binaryReadCode =
        await JianheCliRunner(
          out: (_) {},
          error: fail,
          environment: <String, String>{'JIANHE_DATA_DIR': dataDirectory.path},
        ).run(<String>[
          'skill',
          'read',
          skillId,
          'assets/icon.bin',
          '--output',
          binaryOutput,
        ]);

    expect(binaryReadCode, 0);
    expect(File(binaryOutput).readAsBytesSync(), <int>[0, 1, 2, 255]);
  });

  test(
    'dry-run validates packages without database write permission',
    () async {
      final directory = Directory.systemTemp.createTempSync('jianhe-cli-dry-');
      addTearDown(() => directory.deleteSync(recursive: true));
      File(
        '${directory.path}${Platform.pathSeparator}SKILL.md',
      ).writeAsStringSync('# Dry run');
      final output = <String>[];

      final exitCode = await JianheCliRunner(
        out: output.add,
        error: fail,
        environment: <String, String>{
          'JIANHE_DATA_DIR':
              '${directory.path}${Platform.pathSeparator}missing',
        },
      ).run(<String>['skill', 'import', directory.path, '--dry-run', '--json']);

      expect(exitCode, 0);
      expect(
        (jsonDecode(output.single) as Map<String, Object?>)['status'],
        'validated',
      );
    },
  );

  test(
    'reports schema v4 and migrates it before an authorized import',
    () async {
      final directory = Directory.systemTemp.createTempSync('jianhe-cli-v4-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final dataDirectory = Directory(
        '${directory.path}${Platform.pathSeparator}data',
      )..createSync();
      final databasePath =
          '${dataDirectory.path}${Platform.pathSeparator}jianhe.db';
      final source = Directory(
        '${directory.path}${Platform.pathSeparator}local-skill',
      )..createSync();
      File(
        '${source.path}${Platform.pathSeparator}SKILL.md',
      ).writeAsStringSync('# Migrated Skill');

      final database = JianheStorageDatabase.open(databasePath);
      database.settings.setCliAccessMode(CliAccessMode.readWrite);
      database.settings.setCliSkillImportEnabled(true);
      _downgradeToSchemaV4(database);
      database.close();

      final statusOutput = <String>[];
      final statusCode = await JianheCliRunner(
        out: statusOutput.add,
        error: fail,
        environment: <String, String>{'JIANHE_DATA_DIR': dataDirectory.path},
      ).run(<String>['status', '--json']);
      final status = jsonDecode(statusOutput.single) as Map<String, Object?>;

      expect(statusCode, 0);
      expect(status['database_schema'], 4);
      expect(status['required_schema'], JianheStorageDatabase.schemaVersion);
      expect(status['migration_required'], isTrue);

      final importOutput = <String>[];
      final importCode = await JianheCliRunner(
        out: importOutput.add,
        error: fail,
        environment: <String, String>{'JIANHE_DATA_DIR': dataDirectory.path},
      ).run(<String>['skill', 'import', source.path, '--json']);

      expect(importCode, 0);
      expect(
        (jsonDecode(importOutput.single) as Map<String, Object?>)['status'],
        'imported',
      );
      final migrated = JianheStorageDatabase.open(databasePath, readOnly: true);
      addTearDown(migrated.close);
      expect(
        migrated.database.select('PRAGMA user_version;').first['user_version'],
        JianheStorageDatabase.schemaVersion,
      );
      expect(await migrated.items.list(type: ItemType.skill), hasLength(1));
    },
  );

  test(
    'scans Codex and Claude Skill roots without executing package files',
    () async {
      final directory = Directory.systemTemp.createTempSync('jianhe-cli-scan-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final home = Directory('${directory.path}${Platform.pathSeparator}home')
        ..createSync();
      final repository = Directory(
        '${directory.path}${Platform.pathSeparator}repo',
      )..createSync();
      Directory('${repository.path}${Platform.pathSeparator}.git').createSync();
      final workingDirectory = Directory(
        '${repository.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}app',
      )..createSync(recursive: true);

      final codexSkill = Directory(
        '${home.path}${Platform.pathSeparator}.agents'
        '${Platform.pathSeparator}skills${Platform.pathSeparator}summarize',
      )..createSync(recursive: true);
      File(
        '${codexSkill.path}${Platform.pathSeparator}SKILL.md',
      ).writeAsStringSync(
        '---\nname: summarize\ndescription: Summarize project changes.\n---\n'
        '# Instructions',
      );

      final claudeSkill = Directory(
        '${home.path}${Platform.pathSeparator}.claude'
        '${Platform.pathSeparator}skills${Platform.pathSeparator}review',
      )..createSync(recursive: true);
      File(
        '${claudeSkill.path}${Platform.pathSeparator}SKILL.md',
      ).writeAsStringSync(
        '---\ndescription: Review a change for risks.\n---\n# Review',
      );
      final sentinel = File(
        '${directory.path}${Platform.pathSeparator}must-not-exist.txt',
      );
      final script = File(
        '${claudeSkill.path}${Platform.pathSeparator}scripts'
        '${Platform.pathSeparator}do-not-run.ps1',
      );
      script.parent.createSync(recursive: true);
      script.writeAsStringSync(
        'Set-Content -Path "${sentinel.path}" -Value "executed"',
      );

      final projectSkill = Directory(
        '${repository.path}${Platform.pathSeparator}.claude'
        '${Platform.pathSeparator}skills${Platform.pathSeparator}project-docs',
      )..createSync(recursive: true);
      File(
        '${projectSkill.path}${Platform.pathSeparator}SKILL.md',
      ).writeAsStringSync(
        '---\nname: project-docs\n'
        'description: Maintain repository documentation.\n---\n# Docs',
      );

      final invalidSkill = Directory(
        '${directory.path}${Platform.pathSeparator}invalid-skill',
      )..createSync();
      File(
        '${invalidSkill.path}${Platform.pathSeparator}SKILL.md',
      ).writeAsStringSync('---\nname: [invalid\n---\n# Invalid');

      final output = <String>[];
      final exitCode = await JianheCliRunner(
        out: output.add,
        error: fail,
        workingDirectory: workingDirectory.path,
        environment: <String, String>{
          'HOME': home.path,
          'USERPROFILE': home.path,
          'JIANHE_DATA_DIR':
              '${directory.path}${Platform.pathSeparator}missing-data',
        },
      ).run(<String>['skill', 'scan', '--root', invalidSkill.path, '--json']);
      final payload = jsonDecode(output.single) as Map<String, Object?>;
      final summary = payload['summary'] as Map<String, Object?>;
      final skills = payload['skills'] as List<Object?>;

      expect(exitCode, 0);
      expect(payload['schema'], 'jianhe.skill-scan/v1');
      expect(summary['skill_count'], 4);
      expect(summary['importable_count'], 3);
      expect(
        skills.cast<Map<String, Object?>>().map(
          (skill) => skill['name'] as String,
        ),
        containsAll(<String>['summarize', 'review', 'project-docs']),
      );
      expect(
        skills.cast<Map<String, Object?>>().singleWhere(
          (skill) => skill['provider'] == 'custom',
        )['importable_by_jianhe'],
        isFalse,
      );
      expect(sentinel.existsSync(), isFalse);

      final indexOutput = <String>[];
      final indexCode =
          await JianheCliRunner(
            out: indexOutput.add,
            error: fail,
            workingDirectory: workingDirectory.path,
            environment: <String, String>{
              'HOME': home.path,
              'USERPROFILE': home.path,
              'JIANHE_DATA_DIR':
                  '${directory.path}${Platform.pathSeparator}missing-data',
            },
          ).run(<String>[
            'skill',
            'index',
            '--root',
            invalidSkill.path,
            '--dry-run',
            '--json',
          ]);
      final index = jsonDecode(indexOutput.single) as Map<String, Object?>;

      expect(indexCode, 0);
      expect(index['status'], 'validated');
      expect(index['source_skill_count'], 4);
      expect(
        File(
          '${directory.path}${Platform.pathSeparator}missing-data'
          '${Platform.pathSeparator}jianhe.db',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('imports and updates one stable environment Skill index', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-cli-index-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final home = Directory('${directory.path}${Platform.pathSeparator}home')
      ..createSync();
    final dataDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}data',
    )..createSync();
    final skill = Directory(
      '${home.path}${Platform.pathSeparator}.agents'
      '${Platform.pathSeparator}skills${Platform.pathSeparator}writer',
    )..createSync(recursive: true);
    final entrypoint = File('${skill.path}${Platform.pathSeparator}SKILL.md')
      ..writeAsStringSync(
        '---\nname: writer\ndescription: Draft clear prose.\n---\n# Write',
      );
    final databasePath =
        '${dataDirectory.path}${Platform.pathSeparator}jianhe.db';
    final database = JianheStorageDatabase.open(databasePath);
    database.settings.setCliAccessMode(CliAccessMode.readWrite);
    database.settings.setCliSkillImportEnabled(true);
    database.close();
    final environment = <String, String>{
      'HOME': home.path,
      'USERPROFILE': home.path,
      'JIANHE_DATA_DIR': dataDirectory.path,
    };

    Future<Map<String, Object?>> importIndex() async {
      final output = <String>[];
      final exitCode = await JianheCliRunner(
        out: output.add,
        error: fail,
        workingDirectory: directory.path,
        environment: environment,
      ).run(<String>['skill', 'index', '--import', '--json']);
      expect(exitCode, 0);
      return jsonDecode(output.single) as Map<String, Object?>;
    }

    final imported = await importIndex();
    expect(imported['status'], 'imported');
    expect(imported['skill_id'], 'jianhe-agent-skill-index-v1');

    final firstRead = JianheStorageDatabase.open(databasePath, readOnly: true);
    final firstItem = await firstRead.items.getById(
      'jianhe-agent-skill-index-v1',
    );
    firstRead.close();
    expect(firstItem, isNotNull);
    expect(firstItem!.content, contains('Draft clear prose.'));
    expect(firstItem.content, isNot(contains(home.path)));

    final unchanged = await importIndex();
    expect(unchanged['status'], 'unchanged');

    entrypoint.writeAsStringSync(
      '---\nname: writer\ndescription: Draft and revise clear prose.\n---\n'
      '# Write',
    );
    final updated = await importIndex();
    expect(updated['status'], 'updated');

    final finalRead = JianheStorageDatabase.open(databasePath, readOnly: true);
    addTearDown(finalRead.close);
    final items = await finalRead.items.list(type: ItemType.skill);
    expect(items, hasLength(1));
    expect(items.single.content, contains('Draft and revise clear prose.'));
  });

  test('writes the environment index in English for English Jianhe', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-cli-en-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final home = Directory('${directory.path}${Platform.pathSeparator}home')
      ..createSync();
    final dataDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}data',
    )..createSync();
    final skill = Directory(
      '${home.path}${Platform.pathSeparator}.agents'
      '${Platform.pathSeparator}skills${Platform.pathSeparator}writer',
    )..createSync(recursive: true);
    File('${skill.path}${Platform.pathSeparator}SKILL.md').writeAsStringSync(
      '---\nname: writer\ndescription: Draft clear prose.\n---\n# Write',
    );
    final databasePath =
        '${dataDirectory.path}${Platform.pathSeparator}jianhe.db';
    final database = JianheStorageDatabase.open(databasePath);
    database.settings.setCliAccessMode(CliAccessMode.readWrite);
    database.settings.setUiLanguage(AppLanguage.en);
    database.close();

    final output = <String>[];
    final exitCode = await JianheCliRunner(
      out: output.add,
      error: fail,
      workingDirectory: directory.path,
      environment: <String, String>{
        'HOME': home.path,
        'USERPROFILE': home.path,
        'JIANHE_DATA_DIR': dataDirectory.path,
      },
    ).run(<String>['skill', 'index', '--import', '--json']);
    expect(exitCode, 0);

    final read = JianheStorageDatabase.open(databasePath, readOnly: true);
    addTearDown(read.close);
    final item = (await read.items.getById('jianhe-agent-skill-index-v1'))!;
    expect(item.title, 'AI environment Skill index');
    expect(item.category, 'AI environment');
    expect(item.content, contains('# AI environment Skill index'));
    expect(item.content, contains('Draft clear prose.'));
    expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(item.content), isFalse);
  });

  test(
    'index updates keep user title and category unless passed explicitly',
    () async {
      final directory = Directory.systemTemp.createTempSync('jianhe-cli-keep-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final home = Directory('${directory.path}${Platform.pathSeparator}home')
        ..createSync();
      final dataDirectory = Directory(
        '${directory.path}${Platform.pathSeparator}data',
      )..createSync();
      final skill = Directory(
        '${home.path}${Platform.pathSeparator}.agents'
        '${Platform.pathSeparator}skills${Platform.pathSeparator}writer',
      )..createSync(recursive: true);
      final entrypoint = File('${skill.path}${Platform.pathSeparator}SKILL.md')
        ..writeAsStringSync(
          '---\nname: writer\ndescription: Draft clear prose.\n---\n# Write',
        );
      final databasePath =
          '${dataDirectory.path}${Platform.pathSeparator}jianhe.db';
      final database = JianheStorageDatabase.open(databasePath);
      database.settings.setCliAccessMode(CliAccessMode.readWrite);
      database.close();
      final environment = <String, String>{
        'HOME': home.path,
        'USERPROFILE': home.path,
        'JIANHE_DATA_DIR': dataDirectory.path,
      };

      Future<Map<String, Object?>> importIndex([
        List<String> extra = const <String>[],
      ]) async {
        final output = <String>[];
        final exitCode = await JianheCliRunner(
          out: output.add,
          error: fail,
          workingDirectory: directory.path,
          environment: environment,
        ).run(<String>['skill', 'index', '--import', '--json', ...extra]);
        expect(exitCode, 0);
        return jsonDecode(output.single) as Map<String, Object?>;
      }

      Future<JianheItem> readIndex() async {
        final read = JianheStorageDatabase.open(databasePath, readOnly: true);
        try {
          return (await read.items.getById('jianhe-agent-skill-index-v1'))!;
        } finally {
          read.close();
        }
      }

      final imported = await importIndex();
      expect(imported['status'], 'imported');
      expect(imported['category'], 'AI 环境');

      // The user renames, recategorizes and rates the index in Jianhe.
      final edit = JianheStorageDatabase.open(databasePath);
      final original = await edit.items.getById('jianhe-agent-skill-index-v1');
      await edit.items.save(
        original!.copyWith(title: '我的 Skill 目录', category: '工具', rating: 4),
      );
      edit.close();

      // The environment changes; a plain re-index keeps the user's settings.
      entrypoint.writeAsStringSync(
        '---\nname: writer\ndescription: Draft and revise prose.\n---\n'
        '# Write',
      );
      final updated = await importIndex();
      expect(updated['status'], 'updated');
      expect(updated['title'], '我的 Skill 目录');
      expect(updated['category'], '工具');
      var item = await readIndex();
      expect(item.title, '我的 Skill 目录');
      expect(item.category, '工具');
      expect(item.rating, 4);
      expect(item.content, contains('Draft and revise prose.'));

      // An explicit --category applies even when the environment is unchanged.
      final recategorized = await importIndex(<String>['--category', '整理']);
      expect(recategorized['status'], 'updated');
      item = await readIndex();
      expect(item.category, '整理');
      expect(item.title, '我的 Skill 目录');

      // Same explicit value, or no options at all: nothing to change.
      expect(
        (await importIndex(<String>['--category', '整理']))['status'],
        'unchanged',
      );
      expect((await importIndex())['status'], 'unchanged');
    },
  );

  group('skill output files follow the export overwrite rules', () {
    late Directory directory;
    late String dataPath;
    late String outputDirectory;
    const skillId = 'output-rules-skill';

    setUp(() async {
      directory = Directory.systemTemp.createTempSync('jianhe-cli-out-');
      final data = Directory('${directory.path}${Platform.pathSeparator}data')
        ..createSync();
      dataPath = data.path;
      outputDirectory = Directory(
        '${directory.path}${Platform.pathSeparator}out',
      ).path;
      final database = JianheStorageDatabase.open(
        '$dataPath${Platform.pathSeparator}jianhe.db',
      );
      database.settings.setCliAccessMode(CliAccessMode.readWrite);
      await database.skills.replaceSkill(
        JianheItem.create(
          id: skillId,
          type: ItemType.skill,
          title: 'Output rules',
          content: '# Entry',
        ),
        SkillPackage(
          skillId: skillId,
          sourceFormat: SkillSourceFormat.directory,
          importedAt: DateTime.utc(2026, 10, 22),
          files: <SkillFile>[
            SkillFile(
              relativePath: 'references/guide.md',
              mediaType: 'text/markdown',
              content: Uint8List.fromList(utf8.encode('# Guide')),
            ),
          ],
        ),
      );
      database.close();
    });

    tearDown(() => directory.deleteSync(recursive: true));

    String outPath(String name) =>
        '$outputDirectory${Platform.pathSeparator}$name';

    Future<({int code, List<String> errors})> run(List<String> args) async {
      final errors = <String>[];
      final code = await JianheCliRunner(
        out: (_) {},
        error: errors.add,
        environment: <String, String>{'JIANHE_DATA_DIR': dataPath},
      ).run(args);
      return (code: code, errors: errors);
    }

    Future<({int code, List<String> errors})> read(
      String target, {
      bool force = false,
    }) => run(<String>[
      'skill',
      'read',
      skillId,
      'references/guide.md',
      '--output',
      target,
      if (force) '--force',
    ]);

    /// Creates a symbolic link, or skips the test where the platform does
    /// not allow it (Windows without Developer Mode or elevation).
    bool tryCreateLink(String path, String target) {
      try {
        Link(path).createSync(target, recursive: true);
        return true;
      } on FileSystemException catch (error) {
        markTestSkipped('Cannot create symbolic links here: ${error.message}');
        return false;
      }
    }

    test('writes a new file and creates missing parent folders', () async {
      final target = outPath('nested${Platform.pathSeparator}guide.md');

      final result = await read(target);

      expect(result.code, 0, reason: result.errors.join('\n'));
      expect(File(target).readAsStringSync(), '# Guide');
    });

    test('refuses an existing file unless --force is passed', () async {
      final target = outPath('guide.md');
      File(target)
        ..createSync(recursive: true)
        ..writeAsStringSync('keep me');

      final refused = await read(target);
      expect(refused.code, 6);
      expect(refused.errors.single, contains('--force'));
      expect(File(target).readAsStringSync(), 'keep me');

      final forced = await read(target, force: true);
      expect(forced.code, 0, reason: forced.errors.join('\n'));
      expect(File(target).readAsStringSync(), '# Guide');
    });

    test('refuses a directory target with a clear message', () async {
      final target = outPath('folder');
      Directory(target).createSync(recursive: true);

      final result = await read(target, force: true);

      expect(result.code, 6);
      expect(result.errors.single, contains('is a directory'));
    });

    test('refuses symbolic links, including dangling ones', () async {
      final victim = File(outPath('victim.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('original');
      final link = outPath('link.md');
      if (!tryCreateLink(link, victim.path)) return;
      final missing = outPath('missing.txt');
      final dangling = outPath('dangling.md');
      if (!tryCreateLink(dangling, missing)) return;

      final viaLink = await read(link, force: true);
      expect(viaLink.code, 6);
      expect(victim.readAsStringSync(), 'original');

      final viaDangling = await read(dangling, force: true);
      expect(viaDangling.code, 6);
      expect(File(missing).existsSync(), isFalse);
    });

    test('markdown export refuses a dangling symbolic link', () async {
      final missing = outPath('missing-export.md');
      final dangling = outPath('dangling-export.md');
      if (!tryCreateLink(dangling, missing)) return;

      final result = await run(<String>[
        'skill',
        'export',
        skillId,
        '--output',
        dangling,
        '--format',
        'markdown',
      ]);

      expect(result.code, 6);
      expect(File(missing).existsSync(), isFalse);
    });
  });

  test('concurrent imports of one package create a single Skill', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-cli-race-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final dataDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}data',
    )..createSync();
    final databasePath =
        '${dataDirectory.path}${Platform.pathSeparator}jianhe.db';
    final source = Directory(
      '${directory.path}${Platform.pathSeparator}race-skill',
    )..createSync();
    File(
      '${source.path}${Platform.pathSeparator}SKILL.md',
    ).writeAsStringSync('# Race');
    final database = JianheStorageDatabase.open(databasePath);
    database.settings.setCliAccessMode(CliAccessMode.readWrite);
    database.close();

    // Separate isolates hold separate SQLite connections, like parallel
    // jianhe processes started by an Agent.
    const runs = 6;
    final results = await _runConcurrently(
      runs,
      environment: <String, String>{'JIANHE_DATA_DIR': dataDirectory.path},
      workingDirectory: directory.path,
      arguments: <String>['skill', 'import', source.path, '--json'],
    );

    for (final result in results) {
      expect(result.code, 0, reason: result.errors.join('\n'));
    }
    final statuses = results
        .map(
          (result) =>
              (jsonDecode(result.output.single) as Map<String, Object?>)['status'],
        )
        .toList();
    expect(statuses.where((status) => status == 'imported'), hasLength(1));
    expect(
      statuses.where((status) => status == 'already_exists'),
      hasLength(runs - 1),
    );
    final check = JianheStorageDatabase.open(databasePath, readOnly: true);
    addTearDown(check.close);
    expect(await check.items.list(type: ItemType.skill), hasLength(1));
  });

  test('concurrent index imports report one import and no stale updates', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-cli-irace-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final home = Directory('${directory.path}${Platform.pathSeparator}home')
      ..createSync();
    final dataDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}data',
    )..createSync();
    final skill = Directory(
      '${home.path}${Platform.pathSeparator}.agents'
      '${Platform.pathSeparator}skills${Platform.pathSeparator}writer',
    )..createSync(recursive: true);
    File('${skill.path}${Platform.pathSeparator}SKILL.md').writeAsStringSync(
      '---\nname: writer\ndescription: Draft clear prose.\n---\n# Write',
    );
    final databasePath =
        '${dataDirectory.path}${Platform.pathSeparator}jianhe.db';
    final database = JianheStorageDatabase.open(databasePath);
    database.settings.setCliAccessMode(CliAccessMode.readWrite);
    database.close();

    const runs = 6;
    final results = await _runConcurrently(
      runs,
      environment: <String, String>{
        'HOME': home.path,
        'USERPROFILE': home.path,
        'JIANHE_DATA_DIR': dataDirectory.path,
      },
      workingDirectory: directory.path,
      arguments: <String>['skill', 'index', '--import', '--json'],
    );

    for (final result in results) {
      expect(result.code, 0, reason: result.errors.join('\n'));
    }
    final statuses = results
        .map(
          (result) =>
              (jsonDecode(result.output.single) as Map<String, Object?>)['status'],
        )
        .toList();
    expect(statuses.where((status) => status == 'imported'), hasLength(1));
    expect(
      statuses.where((status) => status == 'unchanged'),
      hasLength(runs - 1),
    );
    final check = JianheStorageDatabase.open(databasePath, readOnly: true);
    addTearDown(check.close);
    expect(await check.items.list(type: ItemType.skill), hasLength(1));
  });

  test('rejects ZIP path traversal before writing any files', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-cli-zip-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final archive = Archive()
      ..addFile(ArchiveFile.string('SKILL.md', '# Safe'))
      ..addFile(
        ArchiveFile('../escape.txt', 4, Uint8List.fromList(<int>[1, 2, 3, 4])),
      );
    final zip = File('${directory.path}${Platform.pathSeparator}unsafe.zip')
      ..writeAsBytesSync(ZipEncoder().encode(archive)!);
    final errors = <String>[];

    final exitCode = await JianheCliRunner(
      out: fail,
      error: errors.add,
    ).run(<String>['skill', 'import', zip.path, '--dry-run']);

    expect(exitCode, 6);
    expect(errors.single, contains('Unsafe Skill file path'));
  });

  test('actual Skill import requires command-line import permission', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-cli-perm-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final dataDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}data',
    )..createSync();
    final source = File('${directory.path}${Platform.pathSeparator}skill.md')
      ..writeAsStringSync('# Permission');
    final database = JianheStorageDatabase.open(
      '${dataDirectory.path}${Platform.pathSeparator}jianhe.db',
    );
    // Import permission is the unified CLI switch (cliSkillImportEnabled
    // mirrors cliAccessMode), so a disabled switch must deny the import.
    database.settings.setCliAccessMode(CliAccessMode.disabled);
    _downgradeToSchemaV4(database);
    database.close();
    final errors = <String>[];

    final exitCode = await JianheCliRunner(
      out: fail,
      error: errors.add,
      environment: <String, String>{'JIANHE_DATA_DIR': dataDirectory.path},
    ).run(<String>['skill', 'import', source.path]);

    expect(exitCode, 4);
    expect(errors.single, contains('Enable AI Command Line Interface'));
    // A refused import must leave the database untouched: no schema upgrade.
    expect(
      JianheStorageDatabase.readSchemaVersion(
        '${dataDirectory.path}${Platform.pathSeparator}jianhe.db',
      ),
      4,
    );
  });

  test('a legacy read-only consent does not authorize Skill import', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-cli-ro-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final dataDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}data',
    )..createSync();
    final databasePath =
        '${dataDirectory.path}${Platform.pathSeparator}jianhe.db';
    final source = File('${directory.path}${Platform.pathSeparator}skill.md')
      ..writeAsStringSync('# Read only');
    final database = JianheStorageDatabase.open(databasePath);
    database.settings.write('cli_access_mode', 'read_only');
    database.settings.write('cli_skill_import_enabled', 'false');
    database.close();
    final errors = <String>[];

    final exitCode = await JianheCliRunner(
      out: fail,
      error: errors.add,
      environment: <String, String>{'JIANHE_DATA_DIR': dataDirectory.path},
    ).run(<String>['skill', 'import', source.path]);

    expect(exitCode, 4);
    final check = JianheStorageDatabase.open(databasePath, readOnly: true);
    addTearDown(check.close);
    expect(await check.items.list(type: ItemType.skill), isEmpty);
  });

  test('unauthorized import does not create a Jianhe database', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-cli-no-db-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final source = File('${directory.path}${Platform.pathSeparator}skill.md')
      ..writeAsStringSync('# No database');
    final dataDirectoryPath =
        '${directory.path}${Platform.pathSeparator}missing-data';
    final errors = <String>[];

    final exitCode = await JianheCliRunner(
      out: fail,
      error: errors.add,
      environment: <String, String>{'JIANHE_DATA_DIR': dataDirectoryPath},
    ).run(<String>['skill', 'import', source.path]);

    expect(exitCode, 4);
    expect(
      File('$dataDirectoryPath${Platform.pathSeparator}jianhe.db').existsSync(),
      isFalse,
    );
  });
}

Future<JianheStorageDatabase> _seedStorage({required bool enabled}) async {
  final storage = JianheStorageDatabase.inMemory();
  await storage.items.save(
    JianheItem.create(
      id: 'prompt-1',
      type: ItemType.prompt,
      title: '会议总结',
      content: '请总结：\n{{input}}',
    ),
  );
  if (enabled) {
    storage.settings.setCliAccessMode(CliAccessMode.readWrite);
  }
  return storage;
}

void _downgradeToSchemaV4(JianheStorageDatabase storage) {
  storage.database.execute('DROP TABLE skill_files;');
  storage.database.execute('DROP TABLE skill_packages;');
  storage.database.execute('PRAGMA user_version = 4;');
}

typedef _CliRun = ({int code, List<String> output, List<String> errors});

/// Runs the same CLI command in [runs] isolates at once. Kept top-level so
/// the isolate closures capture only sendable strings.
Future<List<_CliRun>> _runConcurrently(
  int runs, {
  required Map<String, String> environment,
  required String workingDirectory,
  required List<String> arguments,
}) {
  return Future.wait(<Future<_CliRun>>[
    for (var i = 0; i < runs; i++)
      Isolate.run(() async {
        final output = <String>[];
        final errors = <String>[];
        final code = await JianheCliRunner(
          out: output.add,
          error: errors.add,
          environment: environment,
          workingDirectory: workingDirectory,
        ).run(arguments);
        return (code: code, output: output, errors: errors);
      }),
  ]);
}
