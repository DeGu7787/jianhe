import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jianhe_desktop/features/app_update/app_update_models.dart';
import 'package:jianhe_desktop/features/app_update/app_update_platform_io.dart';

void main() {
  late Directory directory;
  final installer = utf8.encode('MZ fake installer bytes ' * 50);
  final digest = sha256.convert(installer).toString();

  setUp(() {
    directory = Directory.systemTemp.createTempSync('jianhe-update-test');
  });
  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  UpdateManifest manifest({String? sha, int? size}) => UpdateManifest(
    version: AppVersion.tryParse('0.1.8')!,
    sha256: sha ?? digest,
    size: size ?? installer.length,
  );

  IoAppUpdatePlatform platformFor(
    Future<http.Response> Function(http.Request request) handler,
  ) => IoAppUpdatePlatform(
    siteUri: Uri.parse('https://jianhe.example.com'),
    client: MockClient(handler),
    downloadDirectory: directory,
  );

  test('requires an https site', () {
    expect(
      () => IoAppUpdatePlatform(siteUri: Uri.parse('http://example.com')),
      throwsArgumentError,
    );
  });

  test('fetches download.json without cache and parses it', () async {
    late http.Request captured;
    final platform = platformFor((request) async {
      captured = request;
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'windows': <String, Object?>{
              'primary': 'https://gitee.example/a.exe',
              'fallback': '/downloads/a.exe',
              'version': '0.1.8',
              'sha256': digest,
              'size': installer.length,
              'notes': '修复同步',
            },
          }),
        ),
        200,
      );
    });

    final fetched = await platform.fetchManifest();

    expect(captured.url.toString(), 'https://jianhe.example.com/download.json');
    expect(captured.headers['Cache-Control'], 'no-cache');
    expect(fetched!.version.toString(), '0.1.8');
    expect(fetched.notes, '修复同步');
  });

  test('a server error while checking is reported', () async {
    final platform = platformFor((_) async => http.Response('', 502));
    await expectLater(
      platform.fetchManifest(),
      throwsA(isA<AppUpdateException>()),
    );
  });

  test('downloads through /download/windows and verifies the file', () async {
    late Uri requested;
    final platform = platformFor((request) async {
      requested = request.url;
      return http.Response.bytes(installer, 200);
    });
    final progress = <int>[];

    final path = await platform.download(manifest(), onProgress: progress.add);

    expect(requested.toString(), 'https://jianhe.example.com/download/windows');
    expect(File(path).readAsBytesSync(), installer);
    expect(path, endsWith('JianHe-Setup-0.1.8.exe'));
    expect(progress.last, installer.length);
    expect(await platform.verify(path, manifest()), isTrue);
    expect(await platform.findDownloaded(manifest()), path);
    expect(File('$path.part').existsSync(), isFalse);
  });

  test('a checksum mismatch deletes the download', () async {
    final platform = platformFor(
      (_) async => http.Response.bytes(installer, 200),
    );
    await expectLater(
      platform.download(manifest(sha: '0' * 64), onProgress: (_) {}),
      throwsA(
        isA<AppUpdateException>().having(
          (error) => error.message,
          'message',
          contains('校验失败'),
        ),
      ),
    );
    expect(directory.listSync(), isEmpty);
  });

  test('a body larger than published is cut off', () async {
    final platform = platformFor(
      (_) async => http.Response.bytes(installer, 200),
    );
    await expectLater(
      platform.download(manifest(size: installer.length - 1), onProgress: (_) {}),
      throwsA(isA<AppUpdateException>()),
    );
    expect(directory.listSync(), isEmpty);
  });

  test('a truncated body fails verification', () async {
    final platform = platformFor(
      (_) async => http.Response.bytes(installer.sublist(0, 10), 200),
    );
    await expectLater(
      platform.download(manifest(), onProgress: (_) {}),
      throwsA(isA<AppUpdateException>()),
    );
    expect(directory.listSync(), isEmpty);
  });

  test('a tampered earlier download is discarded', () async {
    final stale = File(
      '${directory.path}${Platform.pathSeparator}JianHe-Setup-0.1.8.exe',
    )..writeAsBytesSync(List<int>.filled(installer.length, 0));
    final platform = platformFor((_) async => http.Response('', 404));

    expect(await platform.findDownloaded(manifest()), isNull);
    expect(stale.existsSync(), isFalse);
  });
}
