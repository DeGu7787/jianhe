import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_schedule.dart';

void main() {
  test('interval schedules relative to the current time', () {
    final now = DateTime(2026, 9, 17, 10, 5);
    expect(
      const SyncSchedule.interval(30).nextRunAfter(now),
      DateTime(2026, 9, 17, 10, 35),
    );
  });

  test('daily schedule advances to tomorrow after its local time passed', () {
    final schedule = SyncSchedule.daily(hour: 21, minute: 30);
    expect(
      schedule.nextRunAfter(DateTime(2026, 9, 17, 21, 31)),
      DateTime(2026, 9, 18, 21, 30),
    );
  });

  test('daily schedule stays on today before its local time', () {
    final schedule = SyncSchedule.daily(hour: 21, minute: 30);
    expect(
      schedule.nextRunAfter(DateTime(2026, 9, 17, 8)),
      DateTime(2026, 9, 17, 21, 30),
    );
  });
}
