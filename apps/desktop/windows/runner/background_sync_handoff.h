#ifndef RUNNER_BACKGROUND_SYNC_HANDOFF_H_
#define RUNNER_BACKGROUND_SYNC_HANDOFF_H_

// Stores one coalesced background-sync request in the current user's
// registry hive. The marker survives a slow or failed foreground startup and
// contains no account or sync payload data.
bool MarkBackgroundSyncPending();

// Checks whether the durable marker still awaits foreground consumption.
bool IsBackgroundSyncPending();

// Returns true when a marker existed. A successful read consumes the marker.
bool ConsumeBackgroundSyncPending();

// Best-effort cleanup used when a standalone worker takes ownership or the
// scheduled task is disabled/uninstalled.
void ClearBackgroundSyncPending();

#endif  // RUNNER_BACKGROUND_SYNC_HANDOFF_H_
