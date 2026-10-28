import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'package:jianhe_core/jianhe_core.dart';

import '../../l10n/app_strings.dart';
import 'app_update_models.dart';

/// Desktop implementation of [AppUpdatePlatform].
///
/// The manifest comes from `<site>/download.json` (always over HTTPS). The
/// installer is fetched through `<site>/download/windows`, which redirects to
/// the healthy mirror (a Gitee release, else this site's own copy). Integrity
/// rests on the size and SHA-256 published in the manifest on our own domain,
/// never on the mirror.
class IoAppUpdatePlatform implements AppUpdatePlatform {
  IoAppUpdatePlatform({
    required Uri siteUri,
    http.Client? client,
    Directory? downloadDirectory,
    this.manifestTimeout = const Duration(seconds: 15),
    this.downloadIdleTimeout = const Duration(seconds: 60),
  }) : _site = siteUri.replace(path: '', query: null, fragment: null),
       _client = client ?? http.Client(),
       _directory =
           downloadDirectory ??
           Directory(
             '${Directory.systemTemp.path}${Platform.pathSeparator}JianHeUpdate',
           ) {
    if (_site.scheme != 'https' || _site.host.isEmpty) {
      throw ArgumentError.value(siteUri, 'siteUri', 'must be an https origin');
    }
  }

  final Uri _site;
  final http.Client _client;
  final Directory _directory;
  final Duration manifestTimeout;
  final Duration downloadIdleTimeout;

  @override
  Future<UpdateManifest?> fetchManifest() async {
    final http.Response response;
    try {
      response = await _client
          .get(
            _site.replace(path: '/download.json'),
            headers: const <String, String>{
              'Accept': 'application/json',
              'Cache-Control': 'no-cache',
            },
          )
          .timeout(manifestTimeout);
    } on TimeoutException {
      throw AppUpdateException(AppStrings.current.updateCheckTimeout);
    } on Object {
      throw AppUpdateException(AppStrings.current.updateServerUnreachable);
    }
    if (response.statusCode != 200) {
      throw AppUpdateException(
        AppStrings.current.updateServerUnavailable(response.statusCode),
      );
    }
    try {
      return UpdateManifest.fromDownloadJson(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
    } on FormatException {
      throw AppUpdateException(AppStrings.current.updateManifestInvalid);
    }
  }

  File _installerFile(UpdateManifest manifest) => File(
    '${_directory.path}${Platform.pathSeparator}'
    'JianHe-Setup-${manifest.version}.exe',
  );

  @override
  Future<String?> findDownloaded(UpdateManifest manifest) async {
    final file = _installerFile(manifest);
    if (!await file.exists()) return null;
    if (await verify(file.path, manifest)) return file.path;
    await _deleteQuietly(file);
    return null;
  }

  @override
  Future<String> download(
    UpdateManifest manifest, {
    required void Function(int receivedBytes) onProgress,
  }) async {
    await _directory.create(recursive: true);
    final target = _installerFile(manifest);
    final partial = File('${target.path}.part');
    await _deleteQuietly(partial);

    final http.StreamedResponse response;
    try {
      response = await _client
          .send(
            http.Request('GET', _site.replace(path: '/download/windows'))
              ..followRedirects = true
              ..maxRedirects = 5,
          )
          .timeout(downloadIdleTimeout);
    } on Object {
      throw AppUpdateException(AppStrings.current.updateDownloadUnreachable);
    }
    if (response.statusCode != 200) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      throw AppUpdateException(
        AppStrings.current.updateDownloadUnavailable(response.statusCode),
      );
    }

    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    final output = partial.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(downloadIdleTimeout)) {
        received += chunk.length;
        if (received > manifest.size) {
          throw AppUpdateException(AppStrings.current.updateSizeMismatch);
        }
        hasher.add(chunk);
        output.add(chunk);
        onProgress(received);
      }
      await output.flush();
    } on AppUpdateException {
      await output.close();
      await _deleteQuietly(partial);
      rethrow;
    } on Object {
      await output.close();
      await _deleteQuietly(partial);
      throw AppUpdateException(AppStrings.current.updateDownloadInterrupted);
    }
    await output.close();
    hasher.close();

    if (received != manifest.size ||
        digestSink.value?.toString() != manifest.sha256) {
      await _deleteQuietly(partial);
      throw AppUpdateException(AppStrings.current.updateChecksumFailed);
    }
    await _deleteQuietly(target);
    await partial.rename(target.path);
    return target.path;
  }

  @override
  Future<bool> verify(String path, UpdateManifest manifest) async {
    final file = File(path);
    if (!await file.exists() || await file.length() != manifest.size) {
      return false;
    }
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == manifest.sha256;
  }

  @override
  Future<bool> isCliRunning() async {
    if (!Platform.isWindows) return false;
    final result = await Process.run('tasklist', const <String>[
      '/FI',
      'IMAGENAME eq jianhe.exe',
      '/FO',
      'CSV',
      '/NH',
    ]);
    if (result.exitCode != 0) return false;
    return '${result.stdout}'.toLowerCase().contains('"jianhe.exe"');
  }

  @override
  Future<void> launchInstaller(String path) async {
    if (!Platform.isWindows) {
      throw AppUpdateException(AppStrings.current.updateWindowsOnly);
    }
    try {
      // /JIANHEUPDATE makes the installer wait for this process to exit and
      // reopen the app afterwards (apps/desktop/installer/jianhe_installer.iss).
      await Process.start(
        path,
        <String>[
          '/VERYSILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/JIANHEUPDATE',
          // A silent install picks no language itself; keep the installed
          // shortcuts and uninstall entry in the language the app shows.
          installerLanguageArgument(AppStrings.current.language),
        ],
        mode: ProcessStartMode.detached,
      );
    } on ProcessException {
      throw AppUpdateException(AppStrings.current.updateCannotLaunch);
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A leftover temp file is harmless; the next download overwrites it.
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// The Inno Setup `/LANG=` switch for [language] (language names from
/// installer/jianhe_installer.iss).
String installerLanguageArgument(AppLanguage language) => switch (language) {
  AppLanguage.zh => '/LANG=chinesesimplified',
  AppLanguage.en => '/LANG=english',
};
