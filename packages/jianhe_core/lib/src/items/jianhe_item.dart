import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'item_type.dart';

class JianheItem {
  const JianheItem({
    required this.id,
    required this.type,
    required this.title,
    required this.content,
    required this.isFavorite,
    required this.useCount,
    required this.createdAt,
    required this.updatedAt,
    required this.contentHash,
    this.lastUsedAt,
    this.category = '',
    this.sortOrder = 0,
    this.rating = 0,
  });

  static const maxTitleLength = 100;
  static const maxContentLength = 100000;
  static const maxCategoryLength = 40;

  /// Mirrors the server's category-id rules (cloudsync validateCategoryID):
  /// non-empty, at most [maxCategoryLength] runes, no control characters.
  /// The category name doubles as the entity id on the wire, so these are
  /// hard requirements, not cosmetic limits.
  static bool isValidCategoryName(String name) {
    if (name.isEmpty || name.runes.length > maxCategoryLength) {
      return false;
    }
    for (final rune in name.runes) {
      if (rune <= 0x1F || rune == 0x7F) return false;
    }
    return true;
  }

  final String id;
  final ItemType type;
  final String title;
  final String content;
  final bool isFavorite;
  final int rating;
  final String category;
  final int sortOrder;
  final int useCount;
  final DateTime? lastUsedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String contentHash;

  factory JianheItem.create({
    required ItemType type,
    required String title,
    required String content,
    bool isFavorite = false,
    int? rating,
    String category = '',
    int sortOrder = 0,
    String? id,
    DateTime? now,
  }) {
    final normalizedTitle = title.trim();
    final normalizedCategory = category.trim();
    final normalizedRating = rating ?? (isFavorite ? 5 : 0);
    _validate(
      normalizedTitle,
      content,
      normalizedCategory,
      sortOrder,
      normalizedRating,
    );
    final timestamp = (now ?? DateTime.now()).toUtc();

    return JianheItem(
      id: id ?? const Uuid().v4(),
      type: type,
      title: normalizedTitle,
      content: content,
      isFavorite: normalizedRating > 0,
      rating: normalizedRating,
      category: normalizedCategory,
      sortOrder: sortOrder,
      useCount: 0,
      createdAt: timestamp,
      updatedAt: timestamp,
      contentHash: calculateContentHash(content),
    );
  }

  factory JianheItem.fromJson(Map<String, Object?> json) {
    final id = json['id'] as String? ?? '';
    final title = (json['title'] as String? ?? '').trim();
    final content = json['content'] as String? ?? '';
    final category = (json['category'] as String? ?? '').trim();
    final sortOrder = (json['sort_order'] as num?)?.toInt() ?? 0;
    final rating =
        (json['rating'] as num?)?.toInt() ??
        (json['is_favorite'] == true ? 5 : 0);
    final useCount = (json['use_count'] as num?)?.toInt() ?? 0;
    if (id.trim().isEmpty) {
      throw const FormatException('Item id cannot be empty.');
    }
    if (useCount < 0) {
      throw const FormatException('Item use count cannot be negative.');
    }
    _validate(title, content, category, sortOrder, rating);
    final lastUsedAt = json['last_used_at'] as String?;

    return JianheItem(
      id: id,
      type: ItemType.parse(json['type'] as String),
      title: title,
      content: content,
      isFavorite: rating > 0,
      rating: rating,
      category: category,
      sortOrder: sortOrder,
      useCount: useCount,
      lastUsedAt: lastUsedAt == null
          ? null
          : DateTime.parse(lastUsedAt).toUtc(),
      createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updated_at'] as String).toUtc(),
      contentHash: calculateContentHash(content),
    );
  }

  JianheItem copyWith({
    ItemType? type,
    String? title,
    String? content,
    bool? isFavorite,
    int? rating,
    String? category,
    int? sortOrder,
    int? useCount,
    DateTime? lastUsedAt,
    DateTime? updatedAt,
  }) {
    final nextTitle = (title ?? this.title).trim();
    final nextContent = content ?? this.content;
    final nextCategory = (category ?? this.category).trim();
    final nextSortOrder = sortOrder ?? this.sortOrder;
    final nextRating =
        rating ??
        (isFavorite == null
            ? this.rating
            : isFavorite
            ? (this.rating == 0 ? 5 : this.rating)
            : 0);
    _validate(nextTitle, nextContent, nextCategory, nextSortOrder, nextRating);

    return JianheItem(
      id: id,
      type: type ?? this.type,
      title: nextTitle,
      content: nextContent,
      isFavorite: nextRating > 0,
      rating: nextRating,
      category: nextCategory,
      sortOrder: nextSortOrder,
      useCount: useCount ?? this.useCount,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      createdAt: createdAt,
      updatedAt: (updatedAt ?? DateTime.now()).toUtc(),
      contentHash: calculateContentHash(nextContent),
    );
  }

  JianheItem markUsed({DateTime? now}) {
    return JianheItem(
      id: id,
      type: type,
      title: title,
      content: content,
      isFavorite: isFavorite,
      rating: rating,
      category: category,
      sortOrder: sortOrder,
      useCount: useCount + 1,
      lastUsedAt: (now ?? DateTime.now()).toUtc(),
      createdAt: createdAt,
      updatedAt: updatedAt,
      contentHash: contentHash,
    );
  }

  Map<String, Object?> toJson({bool includeContent = true}) {
    return <String, Object?>{
      'id': id,
      'type': type.name,
      'title': title,
      if (includeContent) 'content': content,
      'is_favorite': isFavorite,
      'rating': rating,
      'category': category,
      'sort_order': sortOrder,
      'use_count': useCount,
      'last_used_at': lastUsedAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'content_hash': contentHash,
    };
  }

  static String calculateContentHash(String content) {
    return sha256.convert(utf8.encode(content)).toString();
  }

  static void _validate(
    String title,
    String content,
    String category,
    int sortOrder,
    int rating,
  ) {
    if (title.isEmpty) {
      throw ArgumentError.value(title, 'title', 'Title cannot be empty.');
    }
    if (title.length > maxTitleLength) {
      throw ArgumentError.value(
        title.length,
        'title',
        'Title cannot exceed $maxTitleLength characters.',
      );
    }
    if (content.trim().isEmpty) {
      throw ArgumentError.value(content, 'content', 'Content cannot be empty.');
    }
    if (content.length > maxContentLength) {
      throw ArgumentError.value(
        content.length,
        'content',
        'Content cannot exceed $maxContentLength characters.',
      );
    }
    if (category.isNotEmpty && !isValidCategoryName(category)) {
      throw ArgumentError.value(
        category,
        'category',
        'Category must not exceed $maxCategoryLength characters or contain '
            'control characters.',
      );
    }
    if (sortOrder < 0) {
      throw ArgumentError.value(
        sortOrder,
        'sortOrder',
        'Sort order cannot be negative.',
      );
    }
    if (rating < 0 || rating > 5) {
      throw RangeError.range(rating, 0, 5, 'rating');
    }
  }
}
