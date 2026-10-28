enum ItemType {
  prompt,
  skill,
  snippet;

  static ItemType parse(String value) {
    return ItemType.values.firstWhere(
      (type) => type.name == value.toLowerCase(),
      orElse: () => throw FormatException('Unsupported item type: $value'),
    );
  }
}
