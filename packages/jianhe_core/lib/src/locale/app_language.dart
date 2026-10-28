/// The language Jianhe presents itself in: the desktop interface, and the
/// text Jianhe itself adds to composed output (see CompositionService).
///
/// Chosen in the installer and changeable in the desktop "More" panel; stored
/// per device, never synced or carried in a .jianhe transfer file.
enum AppLanguage {
  zh('zh'),
  en('en');

  const AppLanguage(this.storageValue);

  /// Value persisted in the `ui_language` setting.
  final String storageValue;

  /// Installations from before the English interface have no stored value
  /// and keep their Chinese behaviour.
  static const fallback = AppLanguage.zh;

  /// Parses a stored or installer-provided value. Accepts the storage values
  /// plus the Inno Setup language names (`chinesesimplified`, `english`).
  static AppLanguage? tryParse(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'zh':
      case 'zh-cn':
      case 'chinesesimplified':
        return AppLanguage.zh;
      case 'en':
      case 'english':
        return AppLanguage.en;
    }
    return null;
  }

  static AppLanguage fromStorage(String? raw) => tryParse(raw) ?? fallback;
}
