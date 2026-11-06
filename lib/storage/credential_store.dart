/// Secrets are stored separately from state.json.
abstract interface class CredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}
