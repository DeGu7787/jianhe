/// Resolves the bundled CLI executable shown in the in-app command guide.
/// Desktop builds probe the install layout; web builds have no CLI.
library;

export 'cli_executable_path_io.dart'
    if (dart.library.html) 'cli_executable_path_web.dart';
