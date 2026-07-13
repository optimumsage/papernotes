import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/core/constants.dart';
import 'package:papernote/data/auth/app_lock_service.dart';

void main() {
  group('PIN hashing', () {
    test('correct PIN verifies, wrong PIN fails', () {
      final stored = AppLockService.hashPin('1234', AppLockService.newSalt());
      expect(AppLockService.verifyPin('1234', stored), isTrue);
      expect(AppLockService.verifyPin('4321', stored), isFalse);
      expect(AppLockService.verifyPin('12345', stored), isFalse);
    });

    test('null / malformed stored value never verifies', () {
      expect(AppLockService.verifyPin('1234', null), isFalse);
      expect(AppLockService.verifyPin('1234', ''), isFalse);
      expect(AppLockService.verifyPin('1234', 'no-separator'), isFalse);
    });

    test('same PIN under distinct salts yields distinct hashes', () {
      final a = AppLockService.hashPin('1234', AppLockService.newSalt());
      final b = AppLockService.hashPin('1234', AppLockService.newSalt());
      expect(a, isNot(equals(b)));
      // ...yet each still verifies its own PIN.
      expect(AppLockService.verifyPin('1234', a), isTrue);
      expect(AppLockService.verifyPin('1234', b), isTrue);
    });

    test('newSalt is random', () {
      expect(AppLockService.newSalt(), isNot(equals(AppLockService.newSalt())));
    });
  });

  group('shouldAutoLock', () {
    test('locks once elapsed reaches the threshold', () {
      expect(
        AppLockService.shouldAutoLock(
            autoLockMinutes: 5, elapsed: const Duration(minutes: 4)),
        isFalse,
      );
      expect(
        AppLockService.shouldAutoLock(
            autoLockMinutes: 5, elapsed: const Duration(minutes: 5)),
        isTrue,
      );
      expect(
        AppLockService.shouldAutoLock(
            autoLockMinutes: 5, elapsed: const Duration(minutes: 30)),
        isTrue,
      );
    });

    test('"until app restart" sentinel never auto-locks', () {
      expect(
        AppLockService.shouldAutoLock(
          autoLockMinutes: AppConfig.appLockRestartSentinel,
          elapsed: const Duration(hours: 48),
        ),
        isFalse,
      );
    });
  });
}
