import '../../l10n/app_strings.dart';

enum SyncScheduleMode { interval, daily }

class SyncSchedule {
  const SyncSchedule.interval(this.intervalMinutes)
    : mode = SyncScheduleMode.interval,
      dailyHour = null,
      dailyMinute = null;

  const SyncSchedule.daily({required int hour, required int minute})
    : mode = SyncScheduleMode.daily,
      intervalMinutes = null,
      dailyHour = hour,
      dailyMinute = minute;

  static const defaultSchedule = SyncSchedule.interval(15);
  static const supportedIntervals = <int>[15, 30, 60];

  final SyncScheduleMode mode;
  final int? intervalMinutes;
  final int? dailyHour;
  final int? dailyMinute;

  DateTime nextRunAfter(DateTime now) {
    if (mode == SyncScheduleMode.interval) {
      return now.add(Duration(minutes: intervalMinutes!));
    }
    var candidate = DateTime(
      now.year,
      now.month,
      now.day,
      dailyHour!,
      dailyMinute!,
    );
    if (!candidate.isAfter(now)) {
      candidate = candidate.add(const Duration(days: 1));
    }
    return candidate;
  }

  String get label => switch (mode) {
    SyncScheduleMode.interval => AppStrings.current.everyMinutes(
      intervalMinutes!,
    ),
    SyncScheduleMode.daily => AppStrings.current.dailyAt(
      '${dailyHour!.toString().padLeft(2, '0')}:'
      '${dailyMinute!.toString().padLeft(2, '0')}',
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is SyncSchedule &&
      other.mode == mode &&
      other.intervalMinutes == intervalMinutes &&
      other.dailyHour == dailyHour &&
      other.dailyMinute == dailyMinute;

  @override
  int get hashCode =>
      Object.hash(mode, intervalMinutes, dailyHour, dailyMinute);
}
