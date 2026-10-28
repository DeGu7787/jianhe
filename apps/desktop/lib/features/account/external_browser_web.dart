import 'dart:js_interop';

@JS('window.open')
external JSAny? _openWindow(JSString url, JSString target);

Future<void> openExternalBrowser(Uri uri) async {
  _openWindow(uri.toString().toJS, '_blank'.toJS);
}
