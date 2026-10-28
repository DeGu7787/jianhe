class BackupFileService {
  const BackupFileService();

  Future<bool> save(
    String content, {
    required String suggestedName,
    // Empty means the localized default (AppStrings.current).
    String dialogTitle = '',
    String filter = '',
  }) {
    throw UnsupportedError('This platform does not support file export yet.');
  }

  Future<({String name, String content})?> open() {
    throw UnsupportedError('This platform does not support file import yet.');
  }
}
