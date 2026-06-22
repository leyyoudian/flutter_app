import 'package:app_gif/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps legacy flash-sized budget when SD is not available', () {
    expect(resolveBadgePackageBudget(sdAvailable: false), 10 * 1024 * 1024);
  });

  test('does not cap SD packages to the old preload budget', () {
    expect(resolveBadgePackageBudget(sdAvailable: true), 512 * 1024 * 1024);
  });
}
