import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:saber/data/file_manager/storage_backend.dart';

/// A [StorageBackend] backed by a real filesystem directory, using
/// `dart:io`. This is the same logic [FileManager] used directly before
/// the [StorageBackend] abstraction was introduced.
class LocalStorageBackend implements StorageBackend {
  final String rootPath;

  const new(this.rootPath);

  String _fullPath(String relPath) => rootPath + relPath;

  @override
  Future<Uint8List?> readBytes(String relPath) async {
    final file = File(_fullPath(relPath));
    if (!file.existsSync()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> writeBytes(
    String relPath,
    List<int> bytes, {
    DateTime? lastModified,
  }) async {
    final file = File(_fullPath(relPath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    if (lastModified != null) await file.setLastModified(lastModified);
  }

  @override
  Future<void> delete(String relPath) async {
    final file = File(_fullPath(relPath));
    if (!file.existsSync()) return;
    await file.delete();
  }

  @override
  Future<void> createDirectory(String relPath) async {
    await Directory(_fullPath(relPath)).create(recursive: true);
  }

  @override
  Future<void> deleteDirectory(String relPath, {bool recursive = true}) async {
    final dir = Directory(_fullPath(relPath));
    if (!dir.existsSync()) return;
    await dir.delete(recursive: recursive);
  }

  @override
  Future<void> rename(String fromRelPath, String toRelPath) async {
    final from = _fullPath(fromRelPath);
    final to = _fullPath(toRelPath);
    final fromIsDir = Directory(from).existsSync();
    if (fromIsDir) {
      await Directory(from).rename(to);
    } else {
      await File(from).rename(to);
    }
  }

  @override
  Future<List<StorageEntity>?> list(String relPath) async {
    final dir = Directory(_fullPath(relPath));
    if (!dir.existsSync()) return null;

    final entities = <StorageEntity>[];
    await for (final entity in dir.list()) {
      final name = p.basename(entity.path);
      final isDir = entity is Directory;
      entities.add(
        StorageEntity(
          name: name,
          isDirectory: isDir,
          lastModified: isDir ? null : entity.statSync().modified,
        ),
      );
    }
    return entities;
  }

  @override
  Future<bool> exists(String relPath) async => File(_fullPath(relPath)).existsSync();

  @override
  Future<bool> isDirectory(String relPath) async =>
      Directory(_fullPath(relPath)).existsSync();

  @override
  Future<DateTime> lastModified(String relPath) async {
    final file = File(_fullPath(relPath));
    if (!file.existsSync()) return DateTime(2023);
    return file.lastModifiedSync();
  }
}
