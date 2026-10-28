enum CliAccessMode {
  disabled('disabled'),
  readWrite('read_write');

  const CliAccessMode(this.storageValue);

  final String storageValue;

  /// [legacySkillImportEnabled] is the persisted value of the old, separate
  /// `cli_skill_import_enabled` switch.
  static CliAccessMode fromStorage(
    String? value, {
    String? legacySkillImportEnabled,
  }) {
    // Installations from before the unified switch could store `read_only`.
    // That user consented to reads only, so it must not silently become
    // read-write. It only maps to read-write when the old, separate Skill
    // import switch was also on (the user had granted both halves);
    // otherwise CLI access stays off until the user enables it again.
    if (value == 'read_only') {
      return legacySkillImportEnabled == 'true'
          ? CliAccessMode.readWrite
          : CliAccessMode.disabled;
    }
    return CliAccessMode.values.firstWhere(
      (mode) => mode.storageValue == value,
      orElse: () => CliAccessMode.disabled,
    );
  }
}
