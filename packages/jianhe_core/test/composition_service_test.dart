import 'package:jianhe_core/jianhe_core.dart';
import 'package:test/test.dart';

void main() {
  const service = CompositionService();

  group('CompositionService', () {
    test('replaces every input token', () {
      final result = service.compose(
        prompt: '原文：{{input}}\n再次引用：{{input}}',
        input: '测试内容',
      );

      expect(result, '原文：测试内容\n再次引用：测试内容');
    });

    test('uses the default separator when the prompt has no token', () {
      final result = service.compose(prompt: '请总结', input: '第一段');

      expect(result, '请总结\n\n---\n待处理内容：\n第一段');
    });

    test('uses the English separator in English', () {
      const english = CompositionService(language: AppLanguage.en);

      expect(
        english.compose(prompt: 'Summarize', input: 'First paragraph'),
        'Summarize\n\n---\nInput:\nFirst paragraph',
      );
      // The token path adds no Jianhe text, so it is the same in any language.
      expect(
        english.compose(prompt: 'Text: {{input}}', input: 'body'),
        service.compose(prompt: 'Text: {{input}}', input: 'body'),
      );
    });

    test('returns prompt only when input is empty', () {
      final result = service.compose(prompt: '请总结：\n{{input}}', input: '  ');

      expect(result, '请总结：');
    });

    test('returns empty output when prompt is blank', () {
      expect(service.compose(prompt: ' ', input: '正文'), isEmpty);
    });

    test('rejects a non-prompt item', () {
      final skill = JianheItem.create(
        type: ItemType.skill,
        title: '测试 Skill',
        content: '# Skill',
      );

      expect(
        () => service.composeItem(prompt: skill, input: '正文'),
        throwsArgumentError,
      );
    });
  });

  group('AppLanguage', () {
    test('parses storage values and installer language names', () {
      expect(AppLanguage.tryParse('en'), AppLanguage.en);
      expect(AppLanguage.tryParse(' English '), AppLanguage.en);
      expect(AppLanguage.tryParse('zh'), AppLanguage.zh);
      expect(AppLanguage.tryParse('chinesesimplified'), AppLanguage.zh);
      expect(AppLanguage.tryParse('fr'), isNull);
      expect(AppLanguage.tryParse(null), isNull);
    });

    test('falls back to Chinese for installations without a setting', () {
      expect(AppLanguage.fromStorage(null), AppLanguage.zh);
      expect(AppLanguage.fromStorage('garbage'), AppLanguage.zh);
      expect(AppLanguage.fromStorage('en'), AppLanguage.en);
    });
  });
}
