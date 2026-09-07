/// Stub for web — on web, dart:io is unavailable, so we never call this.
/// Bytes always come from FilePicker's .bytes field on web.
Future<List<int>?> readFileBytes(String path) async {
  return null;
}
