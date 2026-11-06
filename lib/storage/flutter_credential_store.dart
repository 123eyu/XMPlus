import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credential_store.dart';

/// The only credential adapter which depends on Flutter platform channels.
class FlutterCredentialStore implements CredentialStore {
  FlutterCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
