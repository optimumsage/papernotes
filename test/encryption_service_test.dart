import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/core/constants.dart';
import 'package:papernote/data/crypto/encryption_service.dart';

void main() {
  late EncryptionService crypto;
  late String key;

  setUp(() {
    crypto = EncryptionService();
    key = EncryptionService.generateMasterKey();
    crypto.unlock(key);
  });

  test('generated key is a valid 256-bit key', () {
    expect(EncryptionService.isValidKey(key), isTrue);
    expect(EncryptionService.isValidKey('not-a-key'), isFalse);
    expect(EncryptionService.isValidKey(base64.encode(List.filled(16, 0))),
        isFalse); // 128-bit, too short
  });

  test('string round-trips and produces sentinel-prefixed ciphertext', () {
    final enc = crypto.encryptString('hello world');
    expect(enc, startsWith(EncryptionService.sentinel));
    expect(enc.contains('hello world'), isFalse);
    expect(crypto.decryptString(enc), 'hello world');
  });

  test('maybeDecrypt passes through legacy plaintext (no sentinel)', () {
    expect(crypto.maybeDecrypt('plain body'), 'plain body');
    expect(crypto.maybeDecrypt(null), isNull);
  });

  test('maybeDecrypt yields null on locked/wrong-key ciphertext, not garbage',
      () {
    final enc = crypto.encryptString('[{"insert":"x"}]');
    expect(EncryptionService().maybeDecrypt(enc), isNull); // locked
    final wrong = EncryptionService()
      ..unlock(EncryptionService.generateMasterKey());
    expect(wrong.maybeDecrypt(enc), isNull); // wrong key
    expect(crypto.maybeDecrypt(enc), '[{"insert":"x"}]'); // right key
  });

  test('maybeEncrypt is idempotent (does not double-encrypt)', () {
    final once = crypto.encryptString('hi');
    expect(crypto.maybeEncrypt(once), once);
  });

  test('maybeEncrypt is a no-op when locked (passthrough)', () {
    final locked = EncryptionService();
    expect(locked.maybeEncrypt('x'), 'x');
    expect(locked.maybeDecrypt('x'), 'x');
  });

  test('two encryptions of the same text differ (fresh nonce)', () {
    expect(crypto.encryptString('same'), isNot(crypto.encryptString('same')));
  });

  test('bytes round-trip and carry the magic header', () {
    final plain = utf8.encode('binary attachment payload');
    final enc = crypto.encryptBytes(plain);
    expect(utf8.decode(enc, allowMalformed: true).contains('binary attachment'),
        isFalse);
    expect(crypto.maybeDecryptBytes(enc), plain);
    // Legacy plaintext binary (no header) passes through untouched.
    expect(crypto.maybeDecryptBytes(plain), plain);
  });

  test('payload envelope wraps and unwraps note JSON', () {
    const json = '{"id":"n1","body":"secret"}';
    final wrapped = crypto.wrapPayload(json);
    final map = jsonDecode(wrapped) as Map<String, dynamic>;
    expect(map['pnenc'], 1);
    expect(wrapped.contains('secret'), isFalse);
    expect(crypto.unwrapPayload(map), {'id': 'n1', 'body': 'secret'});
    // A plain (un-migrated) remote map is returned unchanged.
    expect(crypto.unwrapPayload({'id': 'n2'}), {'id': 'n2'});
  });

  test('canary: correct key decrypts, wrong key does not', () {
    final check = crypto.encryptString(AppConfig.encryptionCanaryText);
    expect(EncryptionService.tryDecryptWith(key, check),
        AppConfig.encryptionCanaryText);
    final wrong = EncryptionService.generateMasterKey();
    expect(EncryptionService.tryDecryptWith(wrong, check),
        isNot(AppConfig.encryptionCanaryText));
    expect(EncryptionService.tryDecryptWith(wrong, check), isNull);
  });

  test('fingerprint is stable per key and differs across keys', () {
    expect(EncryptionService.fingerprint(key),
        EncryptionService.fingerprint(key));
    expect(EncryptionService.fingerprint(key),
        isNot(EncryptionService.fingerprint(EncryptionService.generateMasterKey())));
  });
}
