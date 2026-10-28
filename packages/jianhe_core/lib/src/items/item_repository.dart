import 'item_sort_mode.dart';
import 'item_type.dart';
import 'jianhe_item.dart';

abstract interface class ItemRepository {
  Future<JianheItem?> getById(String id);

  Future<List<JianheItem>> listAll();

  Future<List<JianheItem>> list({
    ItemType? type,
    bool favoritesOnly = false,
    int? rating,
    String? category,
    ItemSortMode sortMode = ItemSortMode.smart,
    int limit = 100,
  });

  Future<List<JianheItem>> search(
    String query, {
    ItemType? type,
    bool favoritesOnly = false,
    int? rating,
    String? category,
    ItemSortMode sortMode = ItemSortMode.smart,
    int limit = 50,
  });

  Future<void> save(JianheItem item);

  Future<void> delete(String id);

  /// Counts one use: bumps use_count and last_used_at only. These are
  /// device-local statistics, so updated_at stays and nothing is synced.
  /// Returns the item as stored afterwards, or null when it does not exist.
  Future<JianheItem?> markUsed(String id, {DateTime? now});

  /// Sets the 0–5 star rating and moves updated_at forward so the change
  /// syncs. Only the rating fields are written; title, content and the rest
  /// stay as stored, so a caller holding an outdated copy of the item cannot
  /// overwrite newer content. Returns the item as stored afterwards, or null
  /// when it does not exist.
  Future<JianheItem?> setRating(String id, int rating, {DateTime? now});

  /// Sets custom sort orders for items of [type] (id → order). Only
  /// sort_order and updated_at are written, and only for items whose order
  /// actually changes; ids that are missing or of another type are skipped.
  /// Returns the changed items as stored afterwards.
  Future<List<JianheItem>> setSortOrders(
    ItemType type,
    Map<String, int> sortOrders, {
    DateTime? now,
  });

  Future<List<String>> listCategories(ItemType type);

  Future<void> createCategory(ItemType type, String name);

  Future<void> renameCategory(ItemType type, String oldName, String newName);

  Future<void> deleteCategory(ItemType type, String name);
}
