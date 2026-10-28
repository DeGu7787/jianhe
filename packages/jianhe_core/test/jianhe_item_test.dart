import 'package:jianhe_core/jianhe_core.dart';
import 'package:test/test.dart';

void main() {
  test('creates an item with normalized metadata', () {
    final now = DateTime.utc(2026, 7, 20, 8);
    final item = JianheItem.create(
      id: 'item-1',
      type: ItemType.prompt,
      title: '  总结内容  ',
      content: '请总结：{{input}}',
      now: now,
    );

    expect(item.id, 'item-1');
    expect(item.title, '总结内容');
    expect(item.category, '');
    expect(item.sortOrder, 0);
    expect(item.rating, 0);
    expect(item.createdAt, now);
    expect(item.contentHash, hasLength(64));
  });

  test('markUsed increments usage without changing edited time', () {
    final createdAt = DateTime.utc(2026, 7, 20, 8);
    final usedAt = DateTime.utc(2026, 7, 20, 9);
    final item = JianheItem.create(
      type: ItemType.prompt,
      title: '总结内容',
      content: '请总结',
      now: createdAt,
    );

    final used = item.markUsed(now: usedAt);

    expect(used.useCount, 1);
    expect(used.lastUsedAt, usedAt);
    expect(used.updatedAt, createdAt);
  });

  test('rejects blank content', () {
    expect(
      () =>
          JianheItem.create(type: ItemType.snippet, title: '空内容', content: ' '),
      throwsArgumentError,
    );
  });

  test('normalizes category and preserves personal order when used', () {
    final item = JianheItem.create(
      type: ItemType.skill,
      title: '内容诊断',
      content: '# Skill',
      category: '  内容写作  ',
      sortOrder: 3,
    );

    final used = item.markUsed(now: DateTime.utc(2026, 7, 20, 9));

    expect(used.category, '内容写作');
    expect(used.sortOrder, 3);
    expect(used.toJson()['category'], '内容写作');
    expect(used.toJson()['sort_order'], 3);
  });

  test('category validation mirrors the cloud entity-id rules', () {
    final fortyNonBmpCharacters = List.filled(40, '😀').join();
    final valid = JianheItem.create(
      type: ItemType.prompt,
      title: '合法分类',
      content: '内容',
      category: fortyNonBmpCharacters,
    );

    expect(valid.category.runes, hasLength(40));
    expect(
      () => JianheItem.create(
        type: ItemType.prompt,
        title: '过长分类',
        content: '内容',
        category: '$fortyNonBmpCharacters😀',
      ),
      throwsArgumentError,
    );
    expect(
      () => JianheItem.create(
        type: ItemType.prompt,
        title: '控制字符',
        content: '内容',
        category: '工作\n复盘',
      ),
      throwsArgumentError,
    );
  });

  test('rejects an invalid personal order', () {
    expect(
      () => JianheItem.create(
        type: ItemType.prompt,
        title: '无效顺序',
        content: '内容',
        sortOrder: -1,
      ),
      throwsArgumentError,
    );
  });

  test('supports zero to five star ratings and legacy favorites', () {
    final favorite = JianheItem.create(
      type: ItemType.prompt,
      title: '旧收藏',
      content: '内容',
      isFavorite: true,
    );
    final rated = favorite.copyWith(rating: 3);
    final cleared = rated.copyWith(rating: 0);

    expect(favorite.rating, 5);
    expect(rated.rating, 3);
    expect(rated.isFavorite, isTrue);
    expect(rated.toJson()['rating'], 3);
    expect(cleared.rating, 0);
    expect(cleared.isFavorite, isFalse);
    expect(() => favorite.copyWith(rating: 6), throwsRangeError);
  });
}
