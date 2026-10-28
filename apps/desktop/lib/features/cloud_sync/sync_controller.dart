/// Account-panel sync card controller. Desktop builds run the real engine
/// on SQLite; web builds compile against an inert stub (no local storage).
library;

export 'sync_controller_io.dart' if (dart.library.html) 'sync_controller_web.dart';
