import 'package:flutter/foundation.dart';

import '../../l10n/app_strings.dart';
import '../account/account_api.dart';
import '../account/account_session_controller.dart';
import 'feedback_api.dart';
import 'feedback_models.dart';

enum FeedbackSubmissionState { editing, submitting, success, error }

class FeedbackController extends ChangeNotifier {
  FeedbackController({
    required FeedbackRemoteDataSource api,
    required AccountSessionController account,
  }) : this._(api, account);

  FeedbackController._(this._api, this._account);

  static const maxContentRunes = 2000;

  final FeedbackRemoteDataSource _api;
  final AccountSessionController _account;

  FeedbackSubmissionState _state = FeedbackSubmissionState.editing;
  FeedbackCreated? _created;
  String? _message;

  FeedbackSubmissionState get state => _state;
  FeedbackCreated? get created => _created;
  String? get message => _message;
  bool get busy => _state == FeedbackSubmissionState.submitting;

  int runeCount(String content) => content.runes.length;

  bool canSubmit(String content) {
    final trimmed = content.trim();
    final count = runeCount(trimmed);
    return _account.signedIn && !busy && count >= 1 && count <= maxContentRunes;
  }

  Future<bool> submit(String content) async {
    // A second submit while one is in flight is a no-op; routing it through
    // the validation branch below would flip the state to error and flash a
    // misleading "请输入 1–2000 个字符" over perfectly valid input.
    if (busy) return false;
    final trimmed = content.trim();
    final count = runeCount(trimmed);
    if (!_account.signedIn || count < 1 || count > maxContentRunes) {
      _state = FeedbackSubmissionState.error;
      _message = AppStrings.current.feedbackLengthRange(maxContentRunes);
      notifyListeners();
      return false;
    }
    _state = FeedbackSubmissionState.submitting;
    _message = null;
    notifyListeners();
    try {
      _created = await _account.authorizedRequest(
        (token) => _api.create(accessToken: token, content: trimmed),
      );
      _state = FeedbackSubmissionState.success;
      notifyListeners();
      return true;
    } on AccountApiException catch (error) {
      _state = FeedbackSubmissionState.error;
      _message = error.message;
      notifyListeners();
      return false;
    } on Object {
      _state = FeedbackSubmissionState.error;
      _message = AppStrings.current.feedbackFailed;
      notifyListeners();
      return false;
    }
  }

  void startAnother() {
    _created = null;
    _message = null;
    _state = FeedbackSubmissionState.editing;
    notifyListeners();
  }
}
