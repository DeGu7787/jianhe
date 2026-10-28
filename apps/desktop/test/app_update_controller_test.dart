import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/features/app_update/app_update_controller.dart';

UpdateManifest manifest(String version, {String? sha, int size = 100}) =>
    UpdateManifest(
      version: AppVersion.tryParse(version)!,
      sha256: sha ?? 'a' * 64,
      size: size,
      notes: '修复同步',
    );

class FakeUpdatePlatform implements AppUpdatePlatform {
  UpdateManifest? published;
  Object? fetchError;
  Object? downloadError;
  String? alreadyDownloaded;
  bool cliRunning = false;
  bool intact = true;
  Object? launchError;
  int fetchCalls = 0;
  int downloadCalls = 0;
  final launched = <String>[];
  Completer<void>? downloadGate;

  @override
  Future<UpdateManifest?> fetchManifest() async {
    fetchCalls++;
    if (fetchError != null) throw fetchError!;
    return published;
  }

  @override
  Future<String?> findDownloaded(UpdateManifest manifest) async =>
      alreadyDownloaded;

  @override
  Future<String> download(
    UpdateManifest manifest, {
    required void Function(int receivedBytes) onProgress,
  }) async {
    downloadCalls++;
    onProgress(manifest.size ~/ 2);
    await downloadGate?.future;
    if (downloadError != null) throw downloadError!;
    onProgress(manifest.size);
    return 'C:/tmp/JianHe-Setup-${manifest.version}.exe';
  }

  @override
  Future<bool> verify(String path, UpdateManifest manifest) async => intact;

  @override
  Future<bool> isCliRunning() async => cliRunning;

  @override
  Future<void> launchInstaller(String path) async {
    if (launchError != null) throw launchError!;
    launched.add(path);
  }
}

void main() {
  group('AppVersion', () {
    test('orders numerically and ignores build metadata', () {
      final v = AppVersion.tryParse;
      expect(v('0.1.10')! > v('0.1.9')!, isTrue);
      expect(v('0.2')! > v('0.1.99')!, isTrue);
      expect(v('0.1.7+8'), v('0.1.7'));
      expect(v('v0.1.7'), v('0.1.7'));
      expect(v('0.1'), v('0.1.0'));
      expect(v('0.1').hashCode, v('0.1.0').hashCode);
      expect(v('abc'), isNull);
      expect(v(''), isNull);
      expect(v(null), isNull);
    });
  });

  group('UpdateManifest.fromDownloadJson', () {
    Map<String, Object?> json(Map<String, Object?> windows) =>
        <String, Object?>{'windows': windows};
    final valid = <String, Object?>{
      'primary': 'https://example.com/a.exe',
      'fallback': '/downloads/a.exe',
      'version': '0.1.8',
      'sha256': 'AB' * 32,
      'size': 1234,
      'notes': ' 修复同步 ',
    };

    test('reads the update fields of the windows entry', () {
      final parsed = UpdateManifest.fromDownloadJson(json(valid))!;
      expect(parsed.version, AppVersion.tryParse('0.1.8'));
      expect(parsed.sha256, 'ab' * 32);
      expect(parsed.size, 1234);
      expect(parsed.notes, '修复同步');
    });

    test('a manifest without update fields offers nothing', () {
      expect(
        UpdateManifest.fromDownloadJson(json(<String, Object?>{
          'primary': 'https://example.com/a.exe',
        })),
        isNull,
      );
      expect(UpdateManifest.fromDownloadJson(<String, Object?>{}), isNull);
      expect(UpdateManifest.fromDownloadJson('x'), isNull);
    });

    test('rejects malformed digests and sizes', () {
      expect(
        UpdateManifest.fromDownloadJson(json({...valid, 'sha256': 'abc'})),
        isNull,
      );
      expect(
        UpdateManifest.fromDownloadJson(json({...valid, 'size': 0})),
        isNull,
      );
      expect(
        UpdateManifest.fromDownloadJson(json({...valid, 'size': '1234'})),
        isNull,
      );
      expect(
        UpdateManifest.fromDownloadJson(json({...valid, 'version': 'next'})),
        isNull,
      );
    });
  });

  group('AppUpdateController', () {
    late FakeUpdatePlatform platform;
    late AppUpdateController controller;
    var syncing = false;

    setUp(() {
      syncing = false;
      platform = FakeUpdatePlatform();
      controller = AppUpdateController(
        platform: platform,
        currentVersion: '0.1.7',
        isSyncing: () => syncing,
      );
    });

    tearDown(() => controller.dispose());

    test('reports up to date when nothing newer is published', () async {
      platform.published = manifest('0.1.7');
      await controller.checkNow(userInitiated: true);
      expect(controller.status, AppUpdateStatus.upToDate);

      platform.published = null;
      await controller.checkNow(userInitiated: true);
      expect(controller.status, AppUpdateStatus.upToDate);
    });

    test('offers a newer version without downloading it', () async {
      platform.published = manifest('0.1.8');
      await controller.checkNow();
      expect(controller.status, AppUpdateStatus.available);
      expect(controller.manifest!.version.toString(), '0.1.8');
      expect(platform.downloadCalls, 0);
    });

    test('a background check failure stays quiet', () async {
      platform.fetchError = Exception('offline');
      await controller.checkNow();
      expect(controller.status, AppUpdateStatus.idle);
      expect(controller.message, isNull);
    });

    test('a background check failure keeps an offered update', () async {
      platform.published = manifest('0.1.8');
      await controller.checkNow();
      platform.fetchError = Exception('offline');
      await controller.checkNow();
      expect(controller.status, AppUpdateStatus.available);
    });

    test('a user check failure is shown and can be retried', () async {
      platform.fetchError = const AppUpdateException('无法连接更新服务器，请检查网络后重试。');
      await controller.checkNow(userInitiated: true);
      expect(controller.status, AppUpdateStatus.error);
      expect(controller.message, contains('无法连接'));

      // A quiet periodic check does not hide the error.
      platform.fetchError = null;
      platform.published = manifest('0.1.8');
      await controller.checkNow();
      expect(controller.status, AppUpdateStatus.error);

      await controller.checkNow(userInitiated: true);
      expect(controller.status, AppUpdateStatus.available);
    });

    test('downloads in the background, then waits for the user', () async {
      platform.published = manifest('0.1.8');
      await controller.checkNow();
      platform.downloadGate = Completer<void>();

      final download = controller.download();
      await Future<void>.delayed(Duration.zero);
      expect(controller.status, AppUpdateStatus.downloading);
      expect(controller.progress, closeTo(.5, .001));

      platform.downloadGate!.complete();
      await download;
      expect(controller.status, AppUpdateStatus.ready);
      expect(platform.launched, isEmpty);
    });

    test('a failed download can be retried', () async {
      platform.published = manifest('0.1.8');
      await controller.checkNow();
      platform.downloadError = const AppUpdateException('安装包校验失败，已删除，请重新下载。');
      await controller.download();
      expect(controller.status, AppUpdateStatus.error);
      expect(controller.message, contains('校验失败'));
      expect(controller.manifest, isNotNull);

      platform.downloadError = null;
      await controller.download();
      expect(controller.status, AppUpdateStatus.ready);
    });

    test('reuses an installer downloaded in an earlier session', () async {
      platform.published = manifest('0.1.8');
      platform.alreadyDownloaded = 'C:/tmp/JianHe-Setup-0.1.8.exe';
      await controller.checkNow();
      expect(controller.status, AppUpdateStatus.ready);
      expect(platform.downloadCalls, 0);
    });

    test('a later check keeps a ready installer for the same release', () async {
      platform.published = manifest('0.1.8');
      await controller.checkNow();
      await controller.download();
      await controller.checkNow();
      expect(controller.status, AppUpdateStatus.ready);
    });

    test('a newer release replaces a ready installer', () async {
      platform.published = manifest('0.1.8');
      await controller.checkNow();
      await controller.download();
      platform.published = manifest('0.1.9');
      await controller.checkNow();
      expect(controller.status, AppUpdateStatus.available);
      expect(controller.manifest!.version.toString(), '0.1.9');
    });

    Future<void> readyToInstall() async {
      platform.published = manifest('0.1.8');
      await controller.checkNow();
      await controller.download();
      expect(controller.status, AppUpdateStatus.ready);
    }

    test('installs, then quits so the installer can replace the app', () async {
      await readyToInstall();
      var quits = 0;
      final started = await controller.install(quit: () async => quits++);
      expect(started, isTrue);
      expect(platform.launched, <String>['C:/tmp/JianHe-Setup-0.1.8.exe']);
      expect(quits, 1);
      expect(controller.status, AppUpdateStatus.installing);
    });

    test('waits while a sync is running', () async {
      await readyToInstall();
      syncing = true;
      var quits = 0;
      expect(await controller.install(quit: () async => quits++), isFalse);
      expect(controller.status, AppUpdateStatus.ready);
      expect(controller.message, contains('正在同步'));
      expect(platform.launched, isEmpty);
      expect(quits, 0);
    });

    test('waits while the CLI is running', () async {
      await readyToInstall();
      platform.cliRunning = true;
      expect(await controller.install(quit: () async {}), isFalse);
      expect(controller.status, AppUpdateStatus.ready);
      expect(controller.message, contains('命令行'));
      expect(platform.launched, isEmpty);
    });

    test('a damaged installer is offered for download again', () async {
      await readyToInstall();
      platform.intact = false;
      expect(await controller.install(quit: () async {}), isFalse);
      expect(controller.status, AppUpdateStatus.available);
      expect(controller.message, contains('重新下载'));
      expect(platform.launched, isEmpty);
    });

    test('an installer that fails to start keeps the app running', () async {
      await readyToInstall();
      platform.launchError = const AppUpdateException('无法启动安装程序，请稍后重试。');
      var quits = 0;
      expect(await controller.install(quit: () async => quits++), isFalse);
      expect(controller.status, AppUpdateStatus.ready);
      expect(controller.message, contains('无法启动'));
      expect(quits, 0);
    });

    test('start schedules a delayed first check and a periodic one', () {
      fakeAsync((async) {
        final scheduled = AppUpdateController(
          platform: platform,
          currentVersion: '0.1.7',
          firstCheckDelay: const Duration(minutes: 1),
          checkInterval: const Duration(hours: 24),
        )..start();
        platform.published = manifest('0.1.8');

        async.elapse(const Duration(seconds: 59));
        expect(platform.fetchCalls, 0);
        async.elapse(const Duration(seconds: 1));
        expect(platform.fetchCalls, 1);
        expect(scheduled.status, AppUpdateStatus.available);

        async.elapse(const Duration(hours: 24));
        expect(platform.fetchCalls, 2);

        scheduled.dispose();
        async.elapse(const Duration(hours: 48));
        expect(platform.fetchCalls, 2);
      });
    });
  });
}
