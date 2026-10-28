import 'package:jianhe_core/jianhe_core.dart';

import 'app_strings.dart';

/// Text for an error the cloud service returned, in the interface language.
///
/// The server writes its messages in Chinese, so the Chinese interface shows
/// them unchanged. The English interface maps the stable error [code] to its
/// own copy; an unknown code falls back to a generic message that names the
/// code, rather than showing Chinese.
String localizeServerError({
  required String code,
  required String serverMessage,
  Duration? retryAfter,
  int? remainingAttempts,
}) {
  if (AppStrings.current.language != AppLanguage.en) return serverMessage;
  switch (code) {
    case 'INVALID_CREDENTIALS':
      final wait = retryAfter;
      if (wait != null && wait > Duration.zero) {
        return '${_serverErrorsEn[code]} Try again in ${_describeWait(wait)}.';
      }
      if (remainingAttempts != null &&
          remainingAttempts > 0 &&
          remainingAttempts < 3) {
        final attempts = remainingAttempts == 1
            ? '1 more wrong attempt'
            : '$remainingAttempts more wrong attempts';
        return '${_serverErrorsEn[code]} After $attempts you\'ll need to '
            'wait a moment before trying again.';
      }
    case 'EMAIL_CODE_COOLDOWN':
    case 'RATE_LIMITED':
    case 'FEEDBACK_RATE_LIMITED':
      final wait = retryAfter;
      if (wait != null && wait > Duration.zero) {
        return '${_serverErrorsEn[code]} Try again in ${_describeWait(wait)}.';
      }
  }
  return _serverErrorsEn[code] ??
      'The cloud service returned an error ($code). Please try again later.';
}

String _describeWait(Duration wait) {
  final seconds = (wait.inMilliseconds / 1000).ceil();
  if (seconds < 60) return seconds == 1 ? '1 second' : '$seconds seconds';
  final minutes = (seconds / 60).ceil();
  return minutes == 1 ? '1 minute' : '$minutes minutes';
}

/// English copy for every error code the cloud service sends
/// (server/internal: auth, cloudsync, billing, feedback, httpserver).
const _serverErrorsEn = <String, String>{
  // Requests and service health.
  'INVALID_REQUEST': 'The request was invalid.',
  'INTERNAL_ERROR': 'The cloud service ran into an error. Please try again.',
  'SERVICE_BUSY': 'The server is busy. Please try again later.',
  'METHOD_NOT_ALLOWED': 'This request isn\'t supported.',
  'NOT_FOUND': 'The requested resource wasn\'t found.',
  'RATE_LIMITED': 'Too many requests.',
  'IDEMPOTENCY_KEY_REUSED': 'This request ID was already used for a '
      'different request.',
  // Accounts and sign-in.
  'INVALID_CREDENTIALS': 'Incorrect email or password.',
  'AUTH_REQUIRED': 'Your session has expired. Please sign in again.',
  'REFRESH_TOKEN_REUSED': 'Your sign-in was used somewhere else. Please '
      'sign in again.',
  'EMAIL_ALREADY_REGISTERED': 'This email is already registered.',
  'ADMIN_REQUIRED': 'Administrator access is required.',
  'EXTERNAL_UNAVAILABLE': 'This sign-in method isn\'t available yet.',
  'EXTERNAL_PENDING': 'Waiting for authorization to finish.',
  'EXTERNAL_EXPIRED': 'The authorization expired. Please try again.',
  'EXTERNAL_CONFLICT': 'This identity or email already has a JianHe '
      'account. Sign in to that account first, then link it.',
  'EXTERNAL_DENIED': 'The authorization was cancelled or failed. Please '
      'try again.',
  // Email codes and account security.
  'EMAIL_UNAVAILABLE': 'Email isn\'t available yet. Please try again later.',
  'EMAIL_SEND_FAILED': 'The code email couldn\'t be sent. Please try again '
      'later.',
  'EMAIL_CODE_REQUIRED': 'Signing up needs an email code. If you don\'t see '
      'a code field, update JianHe to the latest version first.',
  'EMAIL_CODE_INVALID': 'The code is incorrect. Check it and try again.',
  'EMAIL_CODE_EXPIRED': 'The code has expired. Please request a new one.',
  'EMAIL_CODE_COOLDOWN': 'Codes are being requested too often.',
  'EMAIL_CODE_DAILY_LIMIT': 'This email has reached today\'s code limit. '
      'Please try again tomorrow.',
  'EMAIL_NOT_SET': 'This account has no email address.',
  'EMAIL_ALREADY_VERIFIED': 'Your email is already verified.',
  'PASSWORD_NOT_SET': 'This account has no password yet. Use “Forgot '
      'password?” on the sign-in page to set one by email.',
  'CURRENT_PASSWORD_INCORRECT': 'The current password is incorrect.',
  // Cloud sync.
  'UNSUPPORTED_BACKUP_FORMAT': 'The sync data format is invalid.',
  'VIP_REQUIRED': 'An active VIP membership is required to upload sync '
      'data.',
  'SYNC_DOWNLOAD_NOT_ALLOWED': 'This account can\'t download sync data.',
  'SYNC_PUSH_IN_PROGRESS': 'Another upload for this account is in progress.',
  'SYNC_QUOTA_EXCEEDED': 'Your sync space is full.',
  'SYNC_STORAGE_BUSY': 'The cloud is tidying up sync history. Please try '
      'again later.',
  'SYNC_BATCH_TOO_LARGE': 'This sync batch is over the size limit.',
  'SYNC_BLOB_TOO_LARGE': 'A single sync file is over 64 MiB.',
  'BLOB_HASH_MISMATCH': 'A sync file didn\'t match its checksum.',
  'BLOB_NOT_FOUND': 'A sync file wasn\'t found.',
  'CURSOR_EXPIRED': 'The sync position expired; a full sync is needed.',
  // VIP purchase.
  'INVALID_PLAN': 'The selected plan doesn\'t exist.',
  'PAYMENT_UNAVAILABLE': 'Payment isn\'t available yet. Please try again '
      'later.',
  'MOCK_PAYMENT_DISABLED': 'Test payments are turned off on this server.',
  'ORDER_NOT_FOUND': 'The order wasn\'t found.',
  'ORDER_CLOSED': 'The order is closed. Please place a new one.',
  'ORDER_ALREADY_PAID': 'The order has already been paid.',
  'ALREADY_LIFETIME': 'You already have lifetime VIP.',
  'TOO_MANY_PENDING_ORDERS': 'Too many unpaid orders. Complete or cancel '
      'an existing order first.',
  'PAYMENT_AMOUNT_MISMATCH': 'The payment amount doesn\'t match the order.',
  'PAYMENT_TRADE_CONFLICT': 'The payment reference doesn\'t match the '
      'order.',
  'MOCK_PAYMENT_FAILED': 'The test payment failed; the order is still '
      'unpaid and you can retry.',
  // Feedback.
  'INVALID_FEEDBACK_CONTENT': 'Feedback must be 1–2000 characters.',
  'INVALID_FEEDBACK_STATUS': 'Invalid feedback status.',
  'INVALID_FEEDBACK_STATUS_TRANSITION': 'This feedback status change isn\'t '
      'allowed.',
  'FEEDBACK_NOT_FOUND': 'The feedback wasn\'t found.',
  'FEEDBACK_RATE_LIMITED': 'Feedback is being sent too often.',
};

/// `Accept-Language` sent with every cloud request, so the server can mail
/// verification codes in the interface language.
String cloudAcceptLanguage() =>
    AppStrings.current.language == AppLanguage.en ? 'en' : 'zh-CN';
