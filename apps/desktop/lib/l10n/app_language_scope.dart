import 'package:flutter/widgets.dart';
import 'package:jianhe_core/jianhe_core.dart';

import 'app_strings.dart';

/// Provides the interface language to the widget tree and a way to change it.
///
/// JianheApp places it above MaterialApp so dialogs and overlays see it too.
class AppLanguageScope extends InheritedWidget {
  const AppLanguageScope({
    super.key,
    required this.language,
    this.onLanguageChanged,
    required super.child,
  });

  final AppLanguage language;

  /// Switches the interface language; null where switching is not offered.
  final ValueChanged<AppLanguage>? onLanguageChanged;

  AppStrings get strings => AppStrings.forLanguage(language);

  static AppLanguageScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLanguageScope>();

  static AppLanguageScope? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppLanguageScope>();

  @override
  bool updateShouldNotify(AppLanguageScope oldWidget) =>
      oldWidget.language != language ||
      oldWidget.onLanguageChanged != onLanguageChanged;
}
