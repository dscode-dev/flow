import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecureStore {
  Future<String?> readSession();
  Future<void> writeSession(String value);
  Future<void> clearSession();
}

class PlatformSecureStore implements SecureStore {
  const PlatformSecureStore(this._storage);
  final FlutterSecureStorage _storage;
  static const _sessionKey = 'flow.session.v1';
  @override
  Future<String?> readSession() => _storage.read(key: _sessionKey);
  @override
  Future<void> writeSession(String value) =>
      _storage.write(key: _sessionKey, value: value);
  @override
  Future<void> clearSession() => _storage.delete(key: _sessionKey);
}

final secureStoreProvider = Provider<SecureStore>(
  (ref) => const PlatformSecureStore(
    FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    ),
  ),
);
