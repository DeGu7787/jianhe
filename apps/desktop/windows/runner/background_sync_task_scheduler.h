#ifndef RUNNER_BACKGROUND_SYNC_TASK_SCHEDULER_H_
#define RUNNER_BACKGROUND_SYNC_TASK_SCHEDULER_H_

#include <string>

struct BackgroundSyncSchedule {
  bool daily = false;
  int interval_minutes = 15;
  int daily_hour = 21;
  int daily_minute = 0;
};

bool ConfigureBackgroundSyncTask(const BackgroundSyncSchedule& schedule,
                                 std::wstring* next_run,
                                 std::wstring* error_message);
bool CancelBackgroundSyncTask(std::wstring* error_message);

// Writes the scheduled task's description (shown in Task Scheduler) in
// English from the next ConfigureBackgroundSyncTask on; Chinese otherwise.
void SetBackgroundSyncTaskEnglish(bool english);

#endif  // RUNNER_BACKGROUND_SYNC_TASK_SCHEDULER_H_
