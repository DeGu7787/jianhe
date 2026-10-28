import '../../l10n/app_strings.dart';
import '../../platform/external_url_launcher.dart';
import 'account_api.dart';

Future<void> openExternalBrowser(Uri uri) async {
  if (!await const ExternalUrlLauncher().open(uri.toString())) {
    throw AccountApiException(
      code: 'BROWSER_UNAVAILABLE',
      message: AppStrings.current.browserUnavailable,
    );
  }
}
