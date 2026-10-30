import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_skill_io/jianhe_skill_io.dart';
import 'package:jianhe_storage/jianhe_storage.dart';

import 'agent_skill_scanner.dart';

typedef StorageFactory =
    JianheStorageDatabase Function(String path, {bool readOnly});

class JianheCliRunner {
  JianheCliRunner({
    void Function(String value)? out,
    void Function(String value)? error,
    Future<String> Function()? readStdin,
    Future<String> Function(String path)? readFile,
    Future<void> Function(String path, String content)? writeFile,
    StorageFactory? storageFactory,
    SkillPackageIo? skillPackageIo,
    Map<String, String>? environment,
    String? workingDirectory,
  }) : _out = out ?? stdout.writeln,
       _error = error ?? stderr.writeln,
       _readStdin = readStdin ?? _defaultReadStdin,
       _readFile = readFile ?? _defaultReadFile,
       _writeFile = writeFile ?? _defaultWriteFile,
       _storageFactory = storageFactory ?? JianheStorageDatabase.open,
       _skillPackageIo = skillPackageIo ?? const SkillPackageIo(),
       _environment = environment ?? Platform.environment,
       _workingDirectory = workingDirectory ?? Directory.current.path;

  static const version = '0.1.12';

  final void Function(String value) _out;
  final void Function(String value) _error;
  final Future<String> Function() _readStdin;
  final Future<String> Function(String path) _readFile;
  final Future<void> Function(String path, String content) _writeFile;
  final StorageFactory _storageFactory;
  final SkillPackageIo _skillPackageIo;
  final Map<String, String> _environment;
  final String _workingDirectory;

  static const _agentSkillIndexId = 'jianhe-agent-skill-index-v1';

  late final ArgParser _parser = _buildParser();

  Future<int> run(List<String> arguments) async {
    try {
      final results = _parser.parse(arguments);
      if (results['version'] as bool) {
        _out(version);
        return 0;
      }
      if (_printRequestedCommandHelp(results)) return 0;
      if (results['help'] as bool || results.command == null) {
        _printUsage();
        return 0;
      }

      final commandResult = switch (results.command!.name) {
        'status' => _runStatus(results.command!),
        'item' => _runItem(results.command!),
        'compose' => _runCompose(results.command!),
        'skill' => _runSkill(results.command!),
        _ => throw const CliFailure(2, 'Unknown command.'),
      };
      return await commandResult;
    } on CliFailure catch (failure) {
      _error(failure.message);
      return failure.exitCode;
    } on SkillPackageFormatException catch (error) {
      _error(error.message);
      return 6;
    } on FormatException catch (error) {
      _error('Invalid command: ${error.message}');
      return 2;
    } on FileSystemException {
      _error('Local file or Jianhe storage could not be accessed.');
      return 5;
    } on StateError catch (error) {
      if (error.message.toString().startsWith(
        'Unsupported Jianhe database schema:',
      )) {
        _error(
          'The Jianhe database schema is incompatible. Start the latest '
          'Jianhe desktop app once to upgrade it, then retry.',
        );
        return 5;
      }
      _error('Jianhe CLI could not complete the local operation.');
      return 5;
    } on Object {
      _error('Jianhe CLI could not complete the local operation.');
      return 5;
    }
  }

  Future<int> _runStatus(ArgResults results) async {
    final asJson = results['json'] as bool;
    final path = JianheDataPaths.databaseFile(environment: _environment).path;
    final databaseFile = File(path);
    if (!databaseFile.existsSync()) {
      final payload = <String, Object?>{
        'access': CliAccessMode.disabled.storageValue,
        'skill_import_enabled': false,
        'version': version,
        'database_exists': false,
        'database_schema': null,
        'required_schema': JianheStorageDatabase.schemaVersion,
        'migration_required': false,
      };
      _out(asJson ? jsonEncode(payload) : 'CLI access: disabled');
      return 0;
    }

    final databaseSchema = JianheStorageDatabase.readSchemaVersion(path);
    if (databaseSchema != JianheStorageDatabase.schemaVersion) {
      final migrationRequired =
          databaseSchema < JianheStorageDatabase.schemaVersion;
      final payload = <String, Object?>{
        'access': 'unavailable',
        'skill_import_enabled': false,
        'version': version,
        'database_exists': true,
        'database_schema': databaseSchema,
        'required_schema': JianheStorageDatabase.schemaVersion,
        'migration_required': migrationRequired,
      };
      _out(
        asJson
            ? jsonEncode(payload)
            : migrationRequired
            ? 'Database upgrade required: schema v$databaseSchema -> '
                  'v${JianheStorageDatabase.schemaVersion}. Start Jianhe or '
                  'run an authorized Skill import.'
            : 'Database schema v$databaseSchema is newer than this CLI '
                  'supports.',
      );
      return 0;
    }

    JianheStorageDatabase? storage;
    try {
      storage = _storageFactory(path, readOnly: true);
      final mode = storage.settings.cliAccessMode;
      final payload = <String, Object?>{
        'access': mode.storageValue,
        'skill_import_enabled': storage.settings.cliSkillImportEnabled,
        'version': version,
        'database_exists': true,
        'database_schema': databaseSchema,
        'required_schema': JianheStorageDatabase.schemaVersion,
        'migration_required': false,
      };
      _out(asJson ? jsonEncode(payload) : 'CLI access: ${mode.storageValue}');
    } finally {
      storage?.close();
    }
    return 0;
  }

  Future<int> _runItem(ArgResults results) async {
    final command = results.command;
    if (command == null) {
      throw const CliFailure(2, 'Missing item command: list, search, or get.');
    }
    return switch (command.name) {
      'list' => _runItemList(command),
      'search' => _runItemSearch(command),
      'get' => _runItemGet(command),
      _ => throw const CliFailure(2, 'Unknown item command.'),
    };
  }

  Future<int> _runItemList(ArgResults results) async {
    final type = _parseOptionalType(results['type'] as String?);
    final limit = _parseLimit(results['limit'] as String);
    return _withReadOnlyStorage((storage) async {
      final items = await storage.items.list(type: type, limit: limit);
      _writeItems(items, asJson: results['json'] as bool);
      return 0;
    });
  }

  Future<int> _runItemSearch(ArgResults results) async {
    final query = results.rest.join(' ').trim();
    if (query.isEmpty) {
      throw const CliFailure(2, 'Search query is required.');
    }
    final type = _parseOptionalType(results['type'] as String?);
    final limit = _parseLimit(results['limit'] as String);
    return _withReadOnlyStorage((storage) async {
      final items = await storage.items.search(query, type: type, limit: limit);
      _writeItems(items, asJson: results['json'] as bool);
      return 0;
    });
  }

  Future<int> _runItemGet(ArgResults results) async {
    final id = _singleRestArgument(results, label: 'item id');
    final raw = results['raw'] as bool;
    final asJson = results['json'] as bool;
    if (raw && asJson) {
      throw const CliFailure(2, 'Choose either --raw or --json.');
    }

    return _withReadOnlyStorage((storage) async {
      final item = await storage.items.getById(id);
      if (item == null) throw const CliFailure(3, 'Item was not found.');
      _out(raw ? item.content : jsonEncode(item.toJson()));
      return 0;
    });
  }

  Future<int> _runCompose(ArgResults results) async {
    final promptId = (results['prompt'] as String?)?.trim();
    if (promptId == null || promptId.isEmpty) {
      throw const CliFailure(2, '--prompt <id> is required.');
    }
    final inlineInput = results['input'] as String?;
    final inputFile = results['input-file'] as String?;
    if (inlineInput != null && inputFile != null) {
      throw const CliFailure(2, 'Choose either --input or --input-file.');
    }
    if (inlineInput == null && inputFile == null) {
      throw const CliFailure(2, '--input or --input-file is required.');
    }

    final input =
        inlineInput ??
        (inputFile == '-' ? await _readStdin() : await _readFile(inputFile!));
    return _withReadOnlyStorage((storage) async {
      final prompt = await storage.items.getById(promptId);
      if (prompt == null) throw const CliFailure(3, 'Prompt was not found.');
      final output = CompositionService(
        language: storage.settings.uiLanguage,
      ).composeItem(
        prompt: prompt,
        input: input,
      );
      if (results['json'] as bool) {
        _out(
          jsonEncode(<String, Object?>{
            'prompt_id': prompt.id,
            'output': output,
          }),
        );
      } else {
        _out(output);
      }
      return 0;
    });
  }

  Future<int> _runSkill(ArgResults results) async {
    final command = results.command;
    if (command == null) {
      throw const CliFailure(
        2,
        'Missing skill command: import, inspect, files, read, context, scan, '
        'index, or export.',
      );
    }
    return switch (command.name) {
      'import' => _runSkillImport(command),
      'inspect' => _runSkillInspect(command),
      'files' => _runSkillFiles(command),
      'read' => _runSkillRead(command),
      'context' => _runSkillContext(command),
      'scan' => _runSkillScan(command),
      'index' => _runSkillIndex(command),
      'export' => _runSkillExport(command),
      _ => throw const CliFailure(2, 'Unknown skill command.'),
    };
  }

  Future<int> _runSkillImport(ArgResults results) async {
    final sourcePath = _singleRestArgument(results, label: 'Skill path');
    final titleOverride = (results['title'] as String?)?.trim();
    final category = (results['category'] as String?)?.trim() ?? '';
    final asJson = results['json'] as bool;

    Future<({JianheItem item, SkillPackage package, String packageHash})>
    prepare() async {
      final imported = await _skillPackageIo.importPath(sourcePath);
      final item = JianheItem.create(
        type: ItemType.skill,
        title: titleOverride == null || titleOverride.isEmpty
            ? imported.title
            : titleOverride,
        content: imported.entrypointContent,
        category: category,
      );
      final package = imported.toPackage(item.id);
      return (
        item: item,
        package: package,
        packageHash: package.packageHash(item.content),
      );
    }

    if (results['dry-run'] as bool) {
      final prepared = await prepare();
      _writeSkillImportResult(
        status: 'validated',
        item: prepared.item,
        package: prepared.package,
        packageHash: prepared.packageHash,
        asJson: asJson,
        includeId: false,
      );
      return 0;
    }

    return _withImportStorage((storage) async {
      // Read and validate the package (up to 64 MiB of ZIP) before taking the
      // write lock, so the desktop app is not blocked while files are parsed.
      final prepared = await prepare();
      // The duplicate check and the write share one BEGIN IMMEDIATE
      // transaction: two concurrent imports of the same package (parallel
      // Agent commands, or the CLI racing the desktop app) used to both see
      // "not found" and each create a Skill. replaceSkill nests as a
      // savepoint inside this transaction.
      final existingId = await storage.writeTransaction(() async {
        final found = await storage.skills.findSkillIdByPackageHash(
          prepared.packageHash,
        );
        if (found != null) return found;
        await storage.skills.replaceSkill(prepared.item, prepared.package);
        return null;
      });
      if (existingId != null) {
        final existing = await storage.items.getById(existingId);
        if (asJson) {
          _out(
            jsonEncode(<String, Object?>{
              'status': 'already_exists',
              'skill_id': existingId,
              'title': existing?.title,
              'package_hash': prepared.packageHash,
            }),
          );
        } else {
          _out('Skill already exists: ${existing?.title ?? existingId}');
        }
        return 0;
      }
      _writeSkillImportResult(
        status: 'imported',
        item: prepared.item,
        package: prepared.package,
        packageHash: prepared.packageHash,
        asJson: asJson,
      );
      return 0;
    });
  }

  Future<int> _runSkillInspect(ArgResults results) async {
    final id = _singleRestArgument(results, label: 'skill id');
    return _withReadOnlyStorage((storage) async {
      final skill = await _requireSkill(storage, id);
      final package = await storage.skills.getBySkillId(id);
      final fileHashes = <String, String>{
        if (package != null)
          for (final file in package.files) file.relativePath: file.contentHash,
      };
      final packageHash = SkillPackage.calculatePackageHash(
        skill.content,
        fileHashes,
      );
      final payload = <String, Object?>{
        'skill_id': skill.id,
        'title': skill.title,
        'category': skill.category,
        'entrypoint': SkillPackage.defaultEntrypoint,
        'source_format':
            package?.sourceFormat.storageValue ??
            SkillSourceFormat.markdown.storageValue,
        'file_count': (package?.files.length ?? 0) + 1,
        'total_bytes':
            package?.totalBytes(skill.content) ??
            utf8.encode(skill.content).length,
        'package_hash': packageHash,
        'imported_at': package?.importedAt.toIso8601String(),
        'updated_at': skill.updatedAt.toIso8601String(),
      };
      if (results['json'] as bool) {
        _out(jsonEncode(payload));
      } else {
        _out('${skill.id}\t${skill.title}\t${payload['file_count']} files');
      }
      return 0;
    });
  }

  Future<int> _runSkillFiles(ArgResults results) async {
    final id = _singleRestArgument(results, label: 'skill id');
    return _withReadOnlyStorage((storage) async {
      final skill = await _requireSkill(storage, id);
      final package = await storage.skills.getBySkillId(id);
      final files = _skillFileMetadata(skill, package);
      if (results['json'] as bool) {
        _out(jsonEncode(<String, Object?>{'skill_id': id, 'files': files}));
      } else {
        for (final file in files) {
          _out(
            '${file['path']}\t${file['byte_length']}\t'
            '${file['media_type'] ?? ''}',
          );
        }
      }
      return 0;
    });
  }

  Future<int> _runSkillRead(ArgResults results) async {
    if (results.rest.length != 2) {
      throw const CliFailure(
        2,
        'Exactly one skill id and one relative file path are required.',
      );
    }
    final id = results.rest[0];
    final relativePath = SkillPackage.normalizeRelativePath(results.rest[1]);
    final outputPath = (results['output'] as String?)?.trim();
    final raw = results['raw'] as bool;
    final force = results['force'] as bool;
    if (raw && outputPath != null && outputPath.isNotEmpty) {
      throw const CliFailure(2, 'Choose either --raw or --output.');
    }
    return _withReadOnlyStorage((storage) async {
      final skill = await _requireSkill(storage, id);
      late final List<int> bytes;
      if (relativePath == SkillPackage.defaultEntrypoint) {
        bytes = utf8.encode(skill.content);
      } else {
        final package = await storage.skills.getBySkillId(id);
        SkillFile? selected;
        if (package != null) {
          for (final file in package.files) {
            if (file.relativePath == relativePath) {
              selected = file;
              break;
            }
          }
        }
        if (selected == null) {
          throw const CliFailure(3, 'Skill file was not found.');
        }
        bytes = selected.content;
      }
      if (outputPath != null && outputPath.isNotEmpty) {
        // `read` only reads the database, but --output writes to disk: the
        // same overwrite and link rules as `skill export` apply.
        final output = await _skillPackageIo.prepareOutputFile(
          outputPath,
          force: force,
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes, flush: true);
        _out(outputPath);
        return 0;
      }
      try {
        _out(utf8.decode(bytes, allowMalformed: false));
      } on FormatException {
        throw const SkillPackageFormatException(
          'Binary Skill files must be read with --output <path>.',
        );
      }
      return 0;
    });
  }

  Future<int> _runSkillContext(ArgResults results) async {
    final id = _singleRestArgument(results, label: 'skill id');
    return _withReadOnlyStorage((storage) async {
      final skill = await _requireSkill(storage, id);
      final package = await storage.skills.getBySkillId(id);
      if (results['json'] as bool) {
        final fileHashes = <String, String>{
          if (package != null)
            for (final file in package.files)
              file.relativePath: file.contentHash,
        };
        _out(
          jsonEncode(<String, Object?>{
            'schema': 'jianhe.skill-context/v1',
            'skill': <String, Object?>{
              'id': skill.id,
              'title': skill.title,
              'category': skill.category,
              'entrypoint': SkillPackage.defaultEntrypoint,
              'source_format':
                  package?.sourceFormat.storageValue ??
                  SkillSourceFormat.markdown.storageValue,
              'package_hash': SkillPackage.calculatePackageHash(
                skill.content,
                fileHashes,
              ),
              'updated_at': skill.updatedAt.toIso8601String(),
            },
            'instructions': skill.content,
            'files': _skillFileMetadata(skill, package),
          }),
        );
      } else {
        _out(skill.content);
      }
      return 0;
    });
  }

  Future<int> _runSkillScan(ArgResults results) async {
    final scan = await _scanAgentSkills(results);
    if (results['json'] as bool) {
      _out(jsonEncode(scan.toJson()));
    } else {
      for (final skill in scan.skills) {
        _out(
          '${skill.provider}\t${skill.scope}\t${skill.name}\t'
          '${skill.packagePath}',
        );
      }
      _out(
        'Scanned ${scan.skills.length} Skills; '
        '${scan.importableCount} can be imported into Jianhe.',
      );
    }
    return 0;
  }

  Future<int> _runSkillIndex(ArgResults results) async {
    final shouldImport = results['import'] as bool;
    if (shouldImport && results['dry-run'] as bool) {
      throw const CliFailure(2, 'Choose either --dry-run or --import.');
    }
    // The index follows the desktop interface language. Updating an existing
    // index only touches --title/--category when the caller passed them; the
    // rest keep what the user set in Jianhe.
    final language = _readUiLanguage();
    final english = language == AppLanguage.en;
    final explicitTitle = (results['title'] as String?)?.trim();
    final explicitCategory = (results['category'] as String?)?.trim();
    final title =
        explicitTitle ??
        (english ? 'AI environment Skill index' : '当前 AI 环境 Skill 索引');
    final category = explicitCategory ?? (english ? 'AI environment' : 'AI 环境');
    final asJson = results['json'] as bool;
    final scan = await _scanAgentSkills(results);
    final content = scan.buildIndexMarkdown(language: language);
    final newItem = JianheItem.create(
      id: _agentSkillIndexId,
      type: ItemType.skill,
      title: title,
      content: content,
      category: category,
    );
    final newPackage = SkillPackage(
      skillId: newItem.id,
      sourceFormat: SkillSourceFormat.markdown,
      importedAt: DateTime.now().toUtc(),
    );
    final packageHash = newPackage.packageHash(newItem.content);

    if (!shouldImport) {
      _writeSkillIndexResult(
        status: 'validated',
        item: newItem,
        scan: scan,
        packageHash: packageHash,
        asJson: asJson,
        includeId: false,
      );
      return 0;
    }

    return _withImportStorage((storage) async {
      // Read, compare and write under one write transaction so concurrent
      // index imports cannot both decide "changed" from a stale read.
      final outcome = await storage.writeTransaction(() async {
        final existing = await storage.items.getById(_agentSkillIndexId);
        if (existing != null && existing.type != ItemType.skill) {
          throw const CliFailure(
            6,
            'The reserved environment Skill index id is already in use.',
          );
        }
        final JianheItem item;
        if (existing == null) {
          item = newItem;
        } else {
          // The content is generated and always follows the environment.
          // Title and category change only when passed explicitly.
          final nextTitle = explicitTitle ?? existing.title;
          final nextCategory = explicitCategory ?? existing.category;
          final existingPackage = await storage.skills.getBySkillId(
            existing.id,
          );
          final contentUnchanged =
              existingPackage != null &&
              existingPackage.packageHash(existing.content) == packageHash;
          if (contentUnchanged &&
              nextTitle == existing.title &&
              nextCategory == existing.category) {
            return (
              status: 'unchanged',
              item: existing,
              packageHash: packageHash,
            );
          }
          item = existing.copyWith(
            title: nextTitle,
            content: newItem.content,
            category: nextCategory,
          );
        }
        final package = SkillPackage(
          skillId: item.id,
          sourceFormat: SkillSourceFormat.markdown,
          importedAt: DateTime.now().toUtc(),
        );
        await storage.skills.replaceSkill(item, package);
        return (
          status: existing == null ? 'imported' : 'updated',
          item: item,
          packageHash: package.packageHash(item.content),
        );
      });
      _writeSkillIndexResult(
        status: outcome.status,
        item: outcome.item,
        scan: scan,
        packageHash: outcome.packageHash,
        asJson: asJson,
      );
      return 0;
    });
  }

  Future<AgentSkillScanResult> _scanAgentSkills(ArgResults results) {
    return AgentSkillScanner(
      environment: _environment,
      workingDirectory: _workingDirectory,
      skillPackageIo: _skillPackageIo,
    ).scan(
      provider: results['provider'] as String,
      scope: results['scope'] as String,
      explicitRoots: results['root'] as List<String>,
    );
  }

  void _writeSkillIndexResult({
    required String status,
    required JianheItem item,
    required AgentSkillScanResult scan,
    required String packageHash,
    required bool asJson,
    bool includeId = true,
  }) {
    if (asJson) {
      _out(
        jsonEncode(<String, Object?>{
          'schema': 'jianhe.skill-index-result/v1',
          'status': status,
          if (includeId) 'skill_id': item.id,
          'title': item.title,
          'category': item.category,
          'source_skill_count': scan.skills.length,
          'compatible_count': scan.compatibleCount,
          'importable_count': scan.importableCount,
          'warning_count': scan.warningCount,
          'package_hash': packageHash,
        }),
      );
    } else {
      _out('$status: ${item.title} (${scan.skills.length} indexed Skills)');
    }
  }

  Future<int> _runSkillExport(ArgResults results) async {
    final id = _singleRestArgument(results, label: 'skill id');
    final outputPath = (results['output'] as String?)?.trim();
    if (outputPath == null || outputPath.isEmpty) {
      throw const CliFailure(2, '--output <path> is required.');
    }

    final format = results['format'] as String;
    final force = results['force'] as bool;
    return _withReadOnlyStorage((storage) async {
      final skill = await _requireSkill(storage, id);
      final package = await storage.skills.getBySkillId(id);
      switch (format) {
        case 'markdown':
          // Also rejects a dangling symbolic link, which File.exists
          // reports as absent although the write would follow it.
          final output = await _skillPackageIo.prepareOutputFile(
            outputPath,
            force: force,
          );
          await _writeFile(output.path, skill.content);
          break;
        case 'directory':
          await _skillPackageIo.exportDirectory(
            skill: skill,
            package: package,
            outputPath: outputPath,
            force: force,
          );
          break;
        case 'zip':
          await _skillPackageIo.exportZip(
            skill: skill,
            package: package,
            outputPath: outputPath,
            force: force,
          );
          break;
      }
      if (results['json'] as bool) {
        _out(
          jsonEncode(<String, Object?>{
            'status': 'exported',
            'skill_id': id,
            'format': format,
            'output': outputPath,
          }),
        );
      } else {
        _out(outputPath);
      }
      return 0;
    });
  }

  Future<JianheItem> _requireSkill(
    JianheStorageDatabase storage,
    String id,
  ) async {
    final skill = await storage.items.getById(id);
    if (skill == null || skill.type != ItemType.skill) {
      throw const CliFailure(3, 'Skill was not found.');
    }
    return skill;
  }

  List<Map<String, Object?>> _skillFileMetadata(
    JianheItem skill,
    SkillPackage? package,
  ) {
    return <Map<String, Object?>>[
      <String, Object?>{
        'path': SkillPackage.defaultEntrypoint,
        'media_type': 'text/markdown',
        'byte_length': utf8.encode(skill.content).length,
        'sha256': skill.contentHash,
      },
      if (package != null)
        for (final file in package.files)
          <String, Object?>{
            'path': file.relativePath,
            'media_type': file.mediaType,
            'byte_length': file.byteLength,
            'sha256': file.contentHash,
          },
    ];
  }

  void _writeSkillImportResult({
    required String status,
    required JianheItem item,
    required SkillPackage package,
    required String packageHash,
    required bool asJson,
    bool includeId = true,
  }) {
    final cloudSyncable = !package.exceedsSyncBlobLimit(item.content);
    final syncWarning = cloudSyncable
        ? null
        : 'This Skill package is larger than the '
            '${SkillPackage.maximumSyncBlobBytes >> 20} MiB cloud sync limit '
            'once encoded; it stays on this device and will not sync.';
    if (asJson) {
      _out(
        jsonEncode(<String, Object?>{
          'status': status,
          if (includeId) 'skill_id': item.id,
          'title': item.title,
          'source_format': package.sourceFormat.storageValue,
          'file_count': package.fileCount,
          'total_bytes': package.totalBytes(item.content),
          'package_hash': packageHash,
          'cloud_syncable': cloudSyncable,
          if (syncWarning != null) 'warning': syncWarning,
        }),
      );
    } else {
      _out('$status: ${item.title} (${package.fileCount} files)');
      if (syncWarning != null) _error('warning: $syncWarning');
    }
  }

  /// The desktop interface language, read without opening the database for
  /// writes. A missing or unreadable database means the Chinese default.
  AppLanguage _readUiLanguage() {
    final path = JianheDataPaths.databaseFile(environment: _environment).path;
    if (!File(path).existsSync()) return AppLanguage.fallback;
    try {
      return JianheStorageDatabase.readUiLanguage(path);
    } on Object {
      return AppLanguage.fallback;
    }
  }

  Future<int> _withReadOnlyStorage(
    Future<int> Function(JianheStorageDatabase storage) action,
  ) async {
    final path = JianheDataPaths.databaseFile(environment: _environment).path;
    final storage = _storageFactory(path, readOnly: true);
    try {
      if (storage.settings.cliAccessMode != CliAccessMode.readWrite) {
        throw const CliFailure(
          4,
          'CLI access is disabled. Enable read-write access in Jianhe settings.',
        );
      }
      return await action(storage);
    } finally {
      storage.close();
    }
  }

  Future<int> _withImportStorage(
    Future<int> Function(JianheStorageDatabase storage) action,
  ) async {
    final path = JianheDataPaths.databaseFile(environment: _environment).path;
    const denied = CliFailure(
      4,
      'CLI Skill import is disabled. Enable AI Command Line Interface in '
      'Jianhe settings.',
    );
    if (!File(path).existsSync()) throw denied;
    // Authorize through a read-only connection first. Opening for writing
    // migrates the schema, so an unauthorized command must never get that
    // far: it would change the user's database (and could lock out an older
    // desktop app) even though the import itself is then refused.
    if (JianheStorageDatabase.readCliAccessMode(path) !=
        CliAccessMode.readWrite) {
      throw denied;
    }
    final storage = _storageFactory(path, readOnly: false);
    try {
      // Re-check on the migrated connection: the switch may have been
      // turned off between the pre-check and this open.
      if (storage.settings.cliAccessMode != CliAccessMode.readWrite) {
        throw denied;
      }
      return await action(storage);
    } finally {
      storage.close();
    }
  }

  void _writeItems(List<JianheItem> items, {required bool asJson}) {
    if (asJson) {
      _out(
        jsonEncode(<String, Object?>{
          'items': items
              .map((item) => item.toJson(includeContent: false))
              .toList(),
        }),
      );
      return;
    }
    for (final item in items) {
      _out('${item.id}\t${item.type.name}\t${item.title}');
    }
  }

  static ItemType? _parseOptionalType(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    try {
      return ItemType.parse(value);
    } on FormatException {
      throw const CliFailure(2, 'Type must be prompt, skill, or snippet.');
    }
  }

  static int _parseLimit(String value) {
    final limit = int.tryParse(value);
    if (limit == null || limit < 1 || limit > 1000) {
      throw const CliFailure(2, 'Limit must be between 1 and 1000.');
    }
    return limit;
  }

  static String _singleRestArgument(
    ArgResults results, {
    required String label,
  }) {
    if (results.rest.length != 1) {
      throw CliFailure(2, 'Exactly one $label is required.');
    }
    return results.rest.single;
  }

  void _printUsage() {
    _out('Jianhe CLI $version');
    _out('Usage: jianhe <command> [arguments]');
    _out('');
    _out('Commands:');
    _out(
      '  status                         Show CLI access and database status.',
    );
    _out('  item list|search|get           Find and read Jianhe items.');
    _out('  compose                        Compose input with a Prompt.');
    _out('  skill import|inspect|files|read|context|scan|index|export');
    _out('                                 Use and manage Skill packages.');
    _out('');
    _out('Global options:');
    _out(_parser.usage);
    _out('');
    _out('Run "jianhe item --help" or "jianhe skill --help" for details.');
  }

  bool _printRequestedCommandHelp(ArgResults results) {
    final command = results.command;
    if (command == null) return false;
    switch (command.name) {
      case 'status':
        if (!(command['help'] as bool)) return false;
        _out('Usage: jianhe status [--json]');
        _out(_parser.commands['status']!.usage);
        return true;
      case 'compose':
        if (!(command['help'] as bool)) return false;
        _out(
          'Usage: jianhe compose --prompt <id> '
          '(--input <text> | --input-file <path>) [--json]',
        );
        _out(_parser.commands['compose']!.usage);
        return true;
      case 'item':
        if (command['help'] as bool) {
          _printItemUsage();
          return true;
        }
        final itemCommand = command.command;
        if (itemCommand == null || !(itemCommand['help'] as bool)) return false;
        _printItemCommandUsage(itemCommand.name!);
        return true;
      case 'skill':
        if (command['help'] as bool) {
          _printSkillUsage();
          return true;
        }
        final skillCommand = command.command;
        if (skillCommand == null || !(skillCommand['help'] as bool)) {
          return false;
        }
        _printSkillCommandUsage(skillCommand.name!);
        return true;
      default:
        return false;
    }
  }

  void _printItemUsage() {
    _out('Usage: jianhe item <command> [arguments]');
    _out('');
    _out('Commands:');
    _out('  list                         List Jianhe items.');
    _out('  search <query>               Search Jianhe items.');
    _out('  get <id>                     Read one Jianhe item.');
    _out('');
    _out('Run "jianhe item <command> --help" for command options.');
  }

  void _printItemCommandUsage(String commandName) {
    final itemParser = _parser.commands['item']!;
    final commandParser = itemParser.commands[commandName]!;
    final positional = switch (commandName) {
      'search' => '<query>',
      'get' => '<id>',
      _ => '',
    };
    _out('Usage: jianhe item $commandName $positional [options]'.trim());
    _out(commandParser.usage);
  }

  void _printSkillUsage() {
    _out('Usage: jianhe skill <command> [arguments]');
    _out('');
    _out('Commands:');
    _out('  import <path>                 Import Markdown, directory, or ZIP.');
    _out('  inspect <id>                  Show Skill package metadata.');
    _out('  files <id>                    List files in a Skill package.');
    _out('  read <id> <relative-path>     Read or save one Skill file.');
    _out(
      '  context <id>                  Load instructions and file metadata.',
    );
    _out('  scan                          Discover local Agent Skills.');
    _out('  index                         Build or save an environment index.');
    _out('  export <id> --output <path>   Export Markdown, directory, or ZIP.');
    _out('');
    _out('Common workflows:');
    _out('  view/invoke: search for a Skill, then load it with context.');
    _out('  create/import: generate files, dry-run import, then import.');
    _out('  summarize environment: scan, dry-run index, then index --import.');
    _out('');
    _out('Run "jianhe skill <command> --help" for command options.');
  }

  void _printSkillCommandUsage(String commandName) {
    final skillParser = _parser.commands['skill']!;
    final commandParser = skillParser.commands[commandName]!;
    final positional = switch (commandName) {
      'import' => '<path>',
      'inspect' || 'files' || 'context' => '<id>',
      'read' => '<id> <relative-path>',
      'export' => '<id>',
      _ => '',
    };
    _out('Usage: jianhe skill $commandName $positional [options]'.trim());
    _out(commandParser.usage);
  }

  static ArgParser _buildParser() {
    final parser = ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addFlag('version', negatable: false);

    parser.addCommand(
      'status',
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false)
        ..addFlag('json', negatable: false),
    );

    final item = ArgParser()..addFlag('help', abbr: 'h', negatable: false);
    item.addCommand(
      'list',
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false)
        ..addOption('type', allowed: ItemType.values.map((type) => type.name))
        ..addOption('limit', defaultsTo: '100')
        ..addFlag('json', negatable: false),
    );
    item.addCommand(
      'search',
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false)
        ..addOption('type', allowed: ItemType.values.map((type) => type.name))
        ..addOption('limit', defaultsTo: '50')
        ..addFlag('json', negatable: false),
    );
    item.addCommand(
      'get',
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false)
        ..addFlag('raw', negatable: false)
        ..addFlag('json', negatable: false),
    );
    parser.addCommand('item', item);

    parser.addCommand(
      'compose',
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false)
        ..addOption('prompt')
        ..addOption('input')
        ..addOption('input-file')
        ..addFlag('json', negatable: false),
    );

    final skill = ArgParser()
      ..addFlag(
        'help',
        abbr: 'h',
        negatable: false,
        help: 'Show Skill command help.',
      );
    skill.addCommand(
      'import',
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false)
        ..addOption('title', help: 'Override the Skill title.')
        ..addOption('category', help: 'Assign a Jianhe category.')
        ..addFlag(
          'dry-run',
          negatable: false,
          help: 'Validate without reading or writing the Jianhe database.',
        )
        ..addFlag('json', negatable: false, help: 'Output JSON.'),
    );
    skill.addCommand(
      'inspect',
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false)
        ..addFlag('json', negatable: false, help: 'Output JSON.'),
    );
    skill.addCommand(
      'files',
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false)
        ..addFlag('json', negatable: false, help: 'Output JSON.'),
    );
    skill.addCommand(
      'read',
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false)
        ..addFlag(
          'raw',
          negatable: false,
          help: 'Write file content to stdout.',
        )
        ..addOption(
          'output',
          help:
              'Write the file to this path. Refuses an existing file, '
              'directory or symbolic link.',
        )
        ..addFlag(
          'force',
          negatable: false,
          help: 'Overwrite an existing --output file.',
        ),
    );
    skill.addCommand(
      'context',
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false)
        ..addFlag('json', negatable: false, help: 'Output JSON.'),
    );
    skill.addCommand('scan', _buildAgentSkillParser());
    skill.addCommand('index', _buildAgentSkillParser(forIndex: true));
    skill.addCommand(
      'export',
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false)
        ..addOption('output', help: 'Destination file or directory path.')
        ..addOption(
          'format',
          allowed: const <String>['markdown', 'directory', 'zip'],
          defaultsTo: 'markdown',
          help: 'Export format.',
        )
        ..addFlag(
          'force',
          negatable: false,
          help: 'Overwrite existing output files.',
        )
        ..addFlag('json', negatable: false, help: 'Output JSON.'),
    );
    parser.addCommand('skill', skill);
    return parser;
  }

  static ArgParser _buildAgentSkillParser({bool forIndex = false}) {
    final parser = ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption(
        'provider',
        allowed: const <String>['all', 'codex', 'claude'],
        defaultsTo: 'all',
        help: 'Agent environment to discover.',
      )
      ..addOption(
        'scope',
        allowed: const <String>['all', 'user', 'project'],
        defaultsTo: 'all',
        help: 'Standard Skill scope to discover.',
      )
      ..addMultiOption(
        'root',
        splitCommas: false,
        help: 'Additional Skill package or container path; repeat as needed.',
      )
      ..addFlag('json', negatable: false, help: 'Output JSON.');
    if (forIndex) {
      parser
        ..addOption(
          'title',
          help:
              'Jianhe item title (default: "当前 AI 环境 Skill 索引", or '
              '"AI environment Skill index" when Jianhe is in English).',
        )
        ..addOption(
          'category',
          help:
              'Jianhe item category (default: "AI 环境", or '
              '"AI environment" when Jianhe is in English).',
        )
        ..addFlag(
          'dry-run',
          negatable: false,
          help:
              'Build and validate the index without touching Jianhe items '
              '(only the interface language setting is read).',
        )
        ..addFlag(
          'import',
          negatable: false,
          help: 'Create or update the environment index in Jianhe.',
        );
    }
    return parser;
  }

  static Future<String> _defaultReadStdin() {
    return stdin.transform(utf8.decoder).join();
  }

  static Future<String> _defaultReadFile(String path) {
    return File(path).readAsString();
  }

  static Future<void> _defaultWriteFile(String path, String content) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
  }
}

class CliFailure implements Exception {
  const CliFailure(this.exitCode, this.message);

  final int exitCode;
  final String message;
}
