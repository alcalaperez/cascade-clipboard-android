import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// SHA3-512 hash returning lowercase hex string.
String sha3_512Hash(String input) {
  final digest = SHA3Digest(512);
  final bytes = Uint8List.fromList(utf8.encode(input));
  final output = digest.process(bytes);
  return output.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

/// Generate cryptographically secure random bytes.
Uint8List generateRandomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List.generate(length, (_) => random.nextInt(256)),
  );
}

/// Derive a 32-byte key using PBKDF2-SHA256.
Uint8List deriveKey(String password, String salt, {int iterations = 664937}) {
  final generator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(
      Uint8List.fromList(utf8.encode(salt)),
      iterations,
      32, // 256 bits
    ));
  return generator.process(Uint8List.fromList(utf8.encode(password)));
}

/// AES-256-GCM encrypt. Returns iv + ciphertext + tag.
Uint8List aesGcmEncrypt(Uint8List plaintext, Uint8List key) {
  final iv = generateRandomBytes(16);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
  final output = cipher.process(plaintext);
  return Uint8List.fromList([...iv, ...output]);
}

/// AES-256-GCM decrypt. Input is iv + ciphertext + tag.
Uint8List aesGcmDecrypt(Uint8List data, Uint8List key) {
  final iv = data.sublist(0, 16);
  final ciphertext = data.sublist(16);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
  return cipher.process(ciphertext);
}
