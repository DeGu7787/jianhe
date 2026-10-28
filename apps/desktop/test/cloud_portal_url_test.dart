import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_desktop/features/ball/ball_home_page.dart';

void main() {
  test('cloud console link carries the interface language', () {
    const base = 'https://jianhe.neodaas.com/jianhecloud/';
    expect(
      cloudPortalUrlFor(base, AppLanguage.en),
      'https://jianhe.neodaas.com/jianhecloud/?lang=en',
    );
    expect(
      cloudPortalUrlFor(base, AppLanguage.zh),
      'https://jianhe.neodaas.com/jianhecloud/?lang=zh',
    );
    expect(
      cloudPortalUrlFor('https://example.com/cloud/?lang=zh&x=1', AppLanguage.en),
      'https://example.com/cloud/?lang=en&x=1',
    );
  });
}
