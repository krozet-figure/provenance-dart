import 'package:provenance_dart/src/wallet/crypto/encryption/crypto.dart';
import 'package:provenance_dart/src/wallet/crypto/hash/hash.dart';
import 'package:provenance_dart/src/wallet/encoding/encoding.dart';
import 'package:provenance_dart/src/wallet/coin.dart';

class PublicKey {
  final List<int> compressedPublicKey;
  final List<int> uncompressedPublicKey;
  final Coin coin;

  PublicKey._(this.compressedPublicKey, this.uncompressedPublicKey, this.coin);

  factory PublicKey.fromPrivateKey(List<int> privateKey, Coin coin) {
    final compressedPublicKey = Crypto.generatePublicKey(privateKey, true);
    final uncompressedPublicKey = Crypto.generatePublicKey(privateKey, false);
    return PublicKey._(compressedPublicKey, uncompressedPublicKey, coin);
  }

  factory PublicKey.fromBase58(List<int> base58, Coin coin) {
    final publicKey = Encoding.toBase58(base58);
    final compressedPublicKey = Encoding.fromHex(publicKey);
    final uncompressedPublicKey = Encoding.fromHex(publicKey);
    return PublicKey._(compressedPublicKey, uncompressedPublicKey, coin);
  }

  String get compressedPublicKeyHex => Encoding.toHex(compressedPublicKey);

  // NOTE: https://github.com/bitcoin/bips/blob/master/bip-0013.mediawiki
  String get address {
    switch (coin) {
      case Coin.mainNet:
        return _generateAddress("pb");
      case Coin.testNet:
        return _generateAddress("tp");
      default: throw Exception("Invalid coin type: $coin");
    }
  }

  String _generateAddress(String prefix) {
    final digest = Hash.sha256(compressedPublicKey);
    final payload = Hash.ripEmd160(digest);
    return Encoding.toBech32(payload, prefix, "1");
  }
}