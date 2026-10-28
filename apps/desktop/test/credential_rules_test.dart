import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/features/account/credential_rules.dart';

void main() {
  group('CredentialRules.isValidEmail matches the server', () {
    const accepted = <String>[
      'user@example.com',
      ' User@Example.COM ',
      'a.b+tag@x.co',
      "o'brien_1@mail.example.cn",
      'a@localhost',
      '用户@例子.中国',
    ];
    const rejected = <String>[
      '',
      'no-at-sign',
      '@x.com',
      'a@',
      'a b@x.com',
      '张三 <a@x.com>',
      'a@x.com.',
      '.a@x.com',
      'a..b@x.com',
      '"ab"@x.com',
      'a@b@x.com',
      'a,b@x.com',
    ];
    for (final email in accepted) {
      test('accepts "$email"', () {
        expect(CredentialRules.isValidEmail(email), isTrue);
      });
    }
    for (final email in rejected) {
      test('rejects "$email"', () {
        expect(CredentialRules.isValidEmail(email), isFalse);
      });
    }
    test('rejects addresses over 320 bytes', () {
      expect(
        CredentialRules.isValidEmail('${'a' * 310}@example.com'),
        isFalse,
      );
    });
  });

  test('new passwords need 10–128 code points', () {
    expect(CredentialRules.isValidNewPassword('a' * 9), isFalse);
    expect(CredentialRules.isValidNewPassword('a' * 10), isTrue);
    expect(CredentialRules.isValidNewPassword('密' * 10), isTrue);
    expect(CredentialRules.isValidNewPassword('a' * 128), isTrue);
    expect(CredentialRules.isValidNewPassword('a' * 129), isFalse);
  });

  test('login passwords only need to be non-empty and within the cap', () {
    expect(CredentialRules.isAcceptableLoginPassword(''), isFalse);
    expect(CredentialRules.isAcceptableLoginPassword('short'), isTrue);
    expect(CredentialRules.isAcceptableLoginPassword('a' * 128), isTrue);
    expect(CredentialRules.isAcceptableLoginPassword('a' * 129), isFalse);
  });
}
