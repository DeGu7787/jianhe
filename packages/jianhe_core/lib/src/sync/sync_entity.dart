import '../items/item_type.dart';

/// Sync entity types as defined by the incremental sync protocol v1
/// (docs/cloud-sync-protocol-v1.md §3). The storage values must match the
/// server's `entity_type` strings exactly.
enum SyncEntityType {
  itemPrompt('item:prompt'),
  itemSkill('item:skill'),
  itemSnippet('item:snippet'),
  categoryPrompt('category:prompt'),
  categorySkill('category:skill'),
  categorySnippet('category:snippet'),
  skillPackage('skill_package');

  const SyncEntityType(this.storageValue);

  final String storageValue;

  static SyncEntityType parse(String value) {
    return SyncEntityType.values.firstWhere(
      (type) => type.storageValue == value,
      orElse: () =>
          throw FormatException('Unsupported sync entity type: $value'),
    );
  }

  static SyncEntityType forItem(ItemType type) => switch (type) {
    ItemType.prompt => itemPrompt,
    ItemType.skill => itemSkill,
    ItemType.snippet => itemSnippet,
  };

  static SyncEntityType forCategory(ItemType type) => switch (type) {
    ItemType.prompt => categoryPrompt,
    ItemType.skill => categorySkill,
    ItemType.snippet => categorySnippet,
  };

  /// The item-type half of this entity; item:* and category:* only.
  ItemType get itemType => switch (this) {
    itemPrompt || categoryPrompt => ItemType.prompt,
    itemSkill || categorySkill => ItemType.skill,
    itemSnippet || categorySnippet => ItemType.snippet,
    skillPackage => throw StateError('skill_package has no ItemType.'),
  };
}

enum SyncChangeOp {
  put('put'),
  delete('delete');

  const SyncChangeOp(this.storageValue);

  final String storageValue;

  static SyncChangeOp parse(String value) {
    return SyncChangeOp.values.firstWhere(
      (op) => op.storageValue == value,
      orElse: () => throw FormatException('Unsupported sync change op: $value'),
    );
  }
}
