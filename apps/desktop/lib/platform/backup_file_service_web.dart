// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import '../l10n/app_strings.dart';

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
    if (utf8.encode(content).length > maximumBackupBytes) {
      throw FormatException(AppStrings.current.backupTooLarge);
    }
    final blob = html.Blob(<Object>[
      Uint8List.fromList(utf8.encode(content)),
    ], 'application/json;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..download = suggestedName
      ..click();
    Timer.run(() => html.Url.revokeObjectUrl(url));
    return true;
  }

  Future<({String name, String content})?> open() async {
    final input = html.FileUploadInputElement()
      ..accept = '.jianhe,.json,application/json';
    final cancelEvents = const html.EventStreamProvider<html.Event>(
      'cancel',
    ).forTarget(input);
    final selected = Future.any<bool>(<Future<bool>>[
      input.onChange.first.then((_) => true),
      cancelEvents.first.then((_) => false),
    ]);
    input.click();
    if (!await selected) return null;
    final files = input.files;
    if (files == null || files.isEmpty) return null;
    final file = files.single;
    if (file.size > maximumBackupBytes) {
      throw FormatException(AppStrings.current.backupTooLarge);
    }
    final reader = html.FileReader()..readAsArrayBuffer(file);
    // A failed read (file vanished, permission revoked) never fires onLoad;
    // without racing onError the await would hang forever.
    final loaded = await Future.any<bool>(<Future<bool>>[
      reader.onLoad.first.then((_) => true),
      reader.onError.first.then((_) => false),
    ]);
    if (!loaded) {
      throw FormatException(AppStrings.current.backupReadFailed);
    }
    final result = reader.result;
    final bytes = result is ByteBuffer
        ? result.asUint8List()
        : result as Uint8List;
    return (name: file.name, content: utf8.decode(bytes));
  }
}
