import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/desktop/single_instance.dart';

void main() {
  test('SingleInstanceGuard: a second instance is rejected and pings the '
      'primary so it can surface its window', () async {
    var activated = 0;

    // First caller binds the lock and becomes the primary.
    final first = await SingleInstanceGuard.ensureSingle(
      onActivate: () async => activated++,
    );
    expect(first, isTrue);

    // Second caller can't bind, so it bails out — and its connect attempt wakes
    // the primary's onActivate.
    final second = await SingleInstanceGuard.ensureSingle(
      onActivate: () async {},
    );
    expect(second, isFalse);

    // Give the primary's socket listener a moment to fire.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(activated, greaterThanOrEqualTo(1));
  });
}
