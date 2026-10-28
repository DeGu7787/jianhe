import 'dart:io';

String resolveCliExecutablePath() {
  final executableDirectory = File(Platform.resolvedExecutable).parent;
  final separator = Platform.pathSeparator;
  final candidates = <String>[
    '${executableDirectory.path}${separator}cli${separator}bin${separator}jianhe.exe',
    '${executableDirectory.path}${separator}cli${separator}bundle${separator}bin${separator}jianhe.exe',
    '${executableDirectory.path}${separator}jianhe.exe',
    '${executableDirectory.parent.path}${separator}Release${separator}cli${separator}bundle${separator}bin${separator}jianhe.exe',
  ];
  return candidates.firstWhere(
    (path) => File(path).existsSync(),
    orElse: () => candidates.first,
  );
}
