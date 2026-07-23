import 'dart:io';

/// Native implementation of readFileBytes — reads file bytes from a file path.
/// Used on Windows, macOS, Linux, Android, iOS.
Future<List<int>?> readFileBytes(String path) async {
  try {
    final file = File(path);
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}
