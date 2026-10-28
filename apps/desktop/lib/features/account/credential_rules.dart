import 'dart:convert';

import '../../l10n/app_strings.dart';

/// Client-side copies of the cloud service's account format rules
/// (server/internal/auth: normalizeEmail, validPassword,
/// validateLoginCredentials). Keeping them identical means malformed input
/// gets a precise local message instead of a generic server error.
abstract final class CredentialRules {
  /// Password bounds in Unicode code points, as the server counts them.
  static const int minPasswordLength = 10;
  static const int maxPasswordLength = 128;
  static const int maxEmailBytes = 320;

  // Messages follow the interface language.
  static String get invalidEmailMessage => AppStrings.current.invalidEmail;
  static String get newPasswordLengthMessage =>
      AppStrings.current.passwordLength(minPasswordLength, maxPasswordLength);

  /// The same rule worded for a password being set (reset, change).
  static String get newPasswordRuleMessage => AppStrings.current
      .newPasswordLength(minPasswordLength, maxPasswordLength);
  static String get loginPasswordMessage => AppStrings.current.enterPassword;
  static String get loginPasswordTooLongMessage =>
      AppStrings.current.passwordTooLong(maxPasswordLength);

  /// Trims and lowercases, like the server does before storing or looking up.
  static String normalizeEmail(String value) => value.trim().toLowerCase();

  /// Whether [value] is an address the server accepts: after normalization it
  /// must be a bare `local@domain` addr-spec whose two halves are RFC 5322
  /// dot-atoms (what Go's `mail.ParseAddress` returns unchanged). Display
  /// names (`张三 <a@x.com>`), quoted local parts, spaces, leading, trailing
  /// or doubled dots are all rejected there, so they are rejected here.
  /// The one deliberate difference: IP domain literals (`a@[127.0.0.1]`),
  /// which Go accepts, are rejected as not a real mailbox for an account.
  static bool isValidEmail(String value) {
    final email = normalizeEmail(value);
    if (email.isEmpty || utf8.encode(email).length > maxEmailBytes) {
      return false;
    }
    final at = email.indexOf('@');
    if (at <= 0 || at != email.lastIndexOf('@')) return false;
    return _isDotAtom(email.substring(0, at)) &&
        _isDotAtom(email.substring(at + 1));
  }

  /// Policy for passwords being set (register, reset, change).
  static bool isValidNewPassword(String password) {
    final length = password.runes.length;
    return length >= minPasswordLength && length <= maxPasswordLength;
  }

  /// A login only needs a non-empty password within the hashing cap: the
  /// minimum length is a policy for new passwords and must not lock out
  /// accounts whose password predates a stricter rule.
  static bool isAcceptableLoginPassword(String password) =>
      password.isNotEmpty && password.runes.length <= maxPasswordLength;

  static bool _isDotAtom(String value) {
    if (value.isEmpty || value.startsWith('.') || value.endsWith('.')) {
      return false;
    }
    if (value.contains('..')) return false;
    for (final rune in value.runes) {
      if (rune != 0x2E && !_isAtext(rune)) return false;
    }
    return true;
  }

  // RFC 5322 atext plus any non-ASCII code point (RFC 6532), matching Go's
  // net/mail isAtext: visible ASCII except the specials ()<>[]:;@\,". and
  // whitespace/control characters.
  static bool _isAtext(int rune) {
    if (rune >= 0x80) return true;
    if (rune < 0x21 || rune > 0x7E) return false;
    return !'()<>[]:;@\\,".'.codeUnits.contains(rune);
  }
}
