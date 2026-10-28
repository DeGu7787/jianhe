import '../items/item_type.dart';
import '../items/jianhe_item.dart';
import '../locale/app_language.dart';

class CompositionService {
  const CompositionService({this.language = AppLanguage.fallback});

  /// Decides the separator placed between a prompt without [inputToken] and
  /// the input. The desktop app and the CLI both pass the device's
  /// `ui_language` setting so they compose identical output.
  final AppLanguage language;

  static const inputToken = '{{input}}';

  /// Chinese separator; the only one before the English interface existed.
  static const defaultSeparator = '\n\n---\n待处理内容：\n';
  static const englishSeparator = '\n\n---\nInput:\n';

  static String separatorFor(AppLanguage language) => switch (language) {
    AppLanguage.zh => defaultSeparator,
    AppLanguage.en => englishSeparator,
  };

  String compose({required String prompt, required String input}) {
    if (prompt.length > JianheItem.maxContentLength) {
      throw ArgumentError.value(
        prompt.length,
        'prompt',
        'Prompt cannot exceed ${JianheItem.maxContentLength} characters.',
      );
    }
    if (input.length > JianheItem.maxContentLength) {
      throw ArgumentError.value(
        input.length,
        'input',
        'Input cannot exceed ${JianheItem.maxContentLength} characters.',
      );
    }

    final normalizedPrompt = prompt.trim();
    final normalizedInput = input.trim();
    if (normalizedPrompt.isEmpty) return '';

    if (normalizedPrompt.contains(inputToken)) {
      return normalizedPrompt
          .replaceAll(inputToken, normalizedInput)
          .trimRight();
    }
    if (normalizedInput.isEmpty) return normalizedPrompt;

    return '$normalizedPrompt${separatorFor(language)}$normalizedInput';
  }

  String composeItem({required JianheItem prompt, required String input}) {
    if (prompt.type != ItemType.prompt) {
      throw ArgumentError.value(
        prompt.type,
        'prompt',
        'Only Prompt items can be composed.',
      );
    }
    return compose(prompt: prompt.content, input: input);
  }
}
