import 'package:flutter/foundation.dart';

import '../../l10n/app_strings.dart';
import 'sync_models.dart';
import 'sync_schedule.dart';

typedef SyncCriticalSection =
    Future<T> Function<T>(Future<T> Function() action);

enum SyncControllerStatus { signedOut, idle, syncing }

/// Web-build stand-in with the real controller's public surface. The web
/// dev version has no local SQLite/journal to drive an engine, so every
/// member is inert; sync affordances render as permanently unavailable.
class SyncController extends ChangeNotifier {
  SyncController({SyncSchedule? initialSchedule})
    : schedule = initialSchedule ?? SyncSchedule.defaultSchedule;

  SyncControllerStatus get status => SyncControllerStatus.signedOut;

  bool get syncing => false;
  bool get engineRunning => false;
  String? get message => null;
  SyncRunResult? get lastResult => null;
  int get remoteDataEpoch => 0;
  bool get autoSyncEnabled => false;

  SyncSchedule schedule;

  DateTime? get nextScheduledAt => null;
  String? get scheduleError => null;

  ({int hour, int minute}) get preferredDailySyncTime => (hour: 9, minute: 0);

  void setAutoSyncEnabled(bool enabled) {}

  void setSchedule(SyncSchedule value) {
    schedule = value;
    notifyListeners();
  }

  String? get accountId => null;
  int get pendingCount => 0;
  DateTime? get lastSyncAt => null;
  bool get canUpload => false;
  bool get canDownload => false;
  bool get canSync => false;
  String? get missingPrerequisite => AppStrings.current.syncWebUnsupported;

  void notifyLocalChanged() {}

  void notifyForeground() {}

  Future<bool> requestAutomaticSync() async => false;

  Future<bool> synchronize({
    SyncMode mode = SyncMode.pushAndPull,
    bool automatic = false,
  }) async => false;
}
