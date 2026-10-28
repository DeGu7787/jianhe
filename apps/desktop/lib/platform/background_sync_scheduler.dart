import 'package:flutter/services.dart';

import '../features/cloud_sync/sync_schedule.dart';

class BackgroundSyncScheduler {
  const BackgroundSyncScheduler();

  static const _channel = MethodChannel('jianhe/window');

  Future<DateTime?> configure(SyncSchedule schedule) async {
    final result = await _channel
        .invokeMethod<String>('configureBackgroundSync', <String, Object?>{
          'mode': schedule.mode.name,
          if (schedule.intervalMinutes != null)
            'intervalMinutes': schedule.intervalMinutes,
          if (schedule.dailyHour != null) 'dailyHour': schedule.dailyHour,
          if (schedule.dailyMinute != null) 'dailyMinute': schedule.dailyMinute,
        });
    return result == null ? null : DateTime.tryParse(result);
  }

  Future<void> cancel() => _channel.invokeMethod<void>('cancelBackgroundSync');

  Future<void> complete(int exitCode) => _channel.invokeMethod<void>(
    'completeBackgroundSync',
    <String, Object?>{'exitCode': exitCode},
  );
}
