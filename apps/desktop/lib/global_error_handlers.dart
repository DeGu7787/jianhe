import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'l10n/app_strings.dart';

/// Receives one formatted entry per caught error.
typedef GlobalErrorSink = void Function(String message);

String formatGlobalError(
  String origin,
  Object error,
  StackTrace? stack, {
  Iterable<DiagnosticsNode>? diagnostics,
}) {
  final buffer = StringBuffer()
    ..write('${DateTime.now().toIso8601String()} $origin: $error');
  if (diagnostics != null) {
    // 布局类异常（如 RenderFlex overflow）的组件创建链只存在于
    // informationCollector 里；不落盘的话 error.log 无法定位是哪个 widget。
    for (final node in diagnostics) {
      buffer.writeln();
      buffer.write(node.toStringDeep().trimRight());
    }
  }
  if (stack != null) {
    buffer.writeln();
    buffer.write(stack.toString());
  }
  buffer.writeln();
  return buffer.toString();
}

/// Installs the three global error nets:
///  - [FlutterError.onError]: framework build/layout/paint errors are logged
///    and still presented to the console in debug mode;
///  - [PlatformDispatcher.instance.onError]: uncaught async errors are logged
///    and reported as handled instead of tearing down the app;
///  - [ErrorWidget.builder]: a friendly placeholder replaces the grey screen
///    so a broken subtree no longer looks like a dead app.
void installGlobalErrorHandlers({GlobalErrorSink? log}) {
  final sink = log ?? (_) {};
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    sink(
      formatGlobalError(
        'framework',
        details.exception,
        details.stack,
        diagnostics: details.informationCollector?.call(),
      ),
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    sink(formatGlobalError('async', error, stack));
    return true;
  };
  ErrorWidget.builder = (details) => _ErrorPlaceholder(details: details);
}

class _ErrorPlaceholder extends StatelessWidget {
  const _ErrorPlaceholder({required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    // The placeholder can render above MaterialApp where no Directionality
    // or theme exists, so it brings its own and uses explicit styles. For
    // the same reason it reads the language without a BuildContext lookup.
    final strings = AppStrings.current;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF17191E),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Color(0xFFB48C5A),
                size: 40,
              ),
              const SizedBox(height: 12),
              Text(
                strings.uiErrorTitle,
                style: const TextStyle(color: Color(0xFFE6E1D6), fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text(
                strings.uiErrorBody,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: const Color(0xFFE6E1D6).withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
