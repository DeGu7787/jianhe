import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_desktop/l10n/app_strings.dart';
import 'package:jianhe_desktop/l10n/server_error_text.dart';

void main() {
  tearDown(() => AppStrings.setCurrentLanguage(AppLanguage.zh));

  test('the Chinese interface shows server messages unchanged', () {
    AppStrings.setCurrentLanguage(AppLanguage.zh);
    expect(
      localizeServerError(code: 'EMAIL_CODE_INVALID', serverMessage: '验证码不正确'),
      '验证码不正确',
    );
    expect(cloudAcceptLanguage(), 'zh-CN');
  });

  test('the English interface maps known codes and never shows Chinese', () {
    AppStrings.setCurrentLanguage(AppLanguage.en);
    expect(cloudAcceptLanguage(), 'en');
    expect(
      localizeServerError(code: 'EMAIL_CODE_INVALID', serverMessage: '验证码不正确'),
      'The code is incorrect. Check it and try again.',
    );
    expect(
      localizeServerError(code: 'SOMETHING_NEW', serverMessage: '新错误'),
      'The cloud service returned an error (SOMETHING_NEW). Please try again '
      'later.',
    );
  });

  test('English login and rate-limit errors carry the wait', () {
    AppStrings.setCurrentLanguage(AppLanguage.en);
    expect(
      localizeServerError(
        code: 'INVALID_CREDENTIALS',
        serverMessage: '邮箱或密码错误。',
        retryAfter: const Duration(seconds: 90),
      ),
      'Incorrect email or password. Try again in 2 minutes.',
    );
    expect(
      localizeServerError(
        code: 'INVALID_CREDENTIALS',
        serverMessage: '邮箱或密码错误。',
        remainingAttempts: 1,
      ),
      contains('After 1 more wrong attempt'),
    );
    expect(
      localizeServerError(
        code: 'EMAIL_CODE_COOLDOWN',
        serverMessage: '验证码发送过于频繁',
        retryAfter: const Duration(seconds: 42),
      ),
      'Codes are being requested too often. Try again in 42 seconds.',
    );
  });
}
