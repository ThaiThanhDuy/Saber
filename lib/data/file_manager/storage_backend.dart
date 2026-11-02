import 'dart:typed_data';

/// A single entry returned by [StorageBackend.list].
class StorageEntity {
  /// The leaf name of this entity (not a full path).
  final String name;

  final bool isDirectory;

  /// The last-modified time of this entity, if the backend can report it
  /// without an extra round-trip. May be null for directories.
  final DateTime? lastModified;

  const new({required this.name, required this.isDirectory, this.lastModified});
}

/// Backs [FileManager]'s file operations, so that the notes root can be
/// either a real filesystem directory ([LocalStorageBackend]) or an Android
/// Storage Access Framework tree ([SafStorageBackend]).
///
/// All paths passed to these methods are relative to the notes root and
/// start with a slash (the same convention [FileManager] already uses
/// internally), e.g. `/Folder/note.sbn2`.
abstract class StorageBackend {
  Future<Uint8List?> readBytes(String relPath);

  /// Writes [bytes] to [relPath], creating parent directories as needed.
  Future<void> writeBytes(
    String relPath,
    List<int> bytes, {
    DateTime? lastModified,
  });

  /// Deletes the file at [relPath]. Does nothing if it doesn't exist.
  Future<void> delete(String relPath);

  /// Creates the directory at [relPath] (and any missing parents).
  /// Does nothing if it already exists.
  Future<void> createDirectory(String relPath);

  /// Deletes the directory at [relPath]. Does nothing if it doesn't exist.
  Future<void> deleteDirectory(String relPath, {bool recursive = true});

  /// Moves/renames the file or directory at [fromRelPath] to [toRelPath].
  /// Assumes [fromRelPath] exists and [toRelPath]'s parent directory exists.
  Future<void> rename(String fromRelPath, String toRelPath);

  /// Lists the immediate children of the directory at [relPath].
  /// Returns null if [relPath] doesn't exist.
  Future<List<StorageEntity>?> list(String relPath);

  Future<bool> exists(String relPath);

  Future<bool> isDirectory(String relPath);

  /// Returns [DateTime](2023) if [relPath] doesn't exist.
  Future<DateTime> lastModified(String relPath);
}
