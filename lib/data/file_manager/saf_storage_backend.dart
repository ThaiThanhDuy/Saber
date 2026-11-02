import 'dart:typed_data';

import 'package:saber/data/file_manager/storage_backend.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart' show SafDocumentFile;

/// A [StorageBackend] backed by an Android Storage Access Framework (SAF)
/// tree, identified by [rootUri] (a `content://...` tree URI with a
/// persisted read/write permission grant).
///
/// SAF has no path-based access — every nested file/directory must be
/// resolved to its own `content://` URI via [SafUtil.child] (which resolves
/// a whole relative path in one call, the same way [SafUtil.mkdirp] does).
/// [_cache] remembers already-resolved paths (populated by [list], and by
/// every write/mkdir/rename/delete) so repeated access to the same file
/// doesn't re-walk the tree.
class SafStorageBackend implements StorageBackend {
  final String rootUri;

  final _safUtil = SafUtil();
  final _safStream = SafStream();

  final Map<String, SafDocumentFile> _cache = {};

  new(this.rootUri);

  List<String> _segments(String relPath) =>
      relPath.split('/').where((s) => s.isNotEmpty).toList();

  String _parentOf(String relPath) {
    final idx = relPath.lastIndexOf('/');
    if (idx <= 0) return '/';
    return relPath.substring(0, idx);
  }

  String _leafOf(String relPath) => relPath.substring(relPath.lastIndexOf('/') + 1);

  Future<SafDocumentFile?> _resolveEntity(String relPath) async {
    if (relPath == '/' || relPath.isEmpty) return null;
    final cached = _cache[relPath];
    if (cached != null) return cached;

    final entity = await _safUtil.child(rootUri, _segments(relPath));
    if (entity != null) _cache[relPath] = entity;
    return entity;
  }

  Future<String> _resolveDirUri(String relPath) async {
    if (relPath == '/' || relPath.isEmpty) return rootUri;
    final cached = _cache[relPath];
    if (cached != null) return cached.uri;

    final entity = await _safUtil.mkdirp(rootUri, _segments(relPath));
    _cache[relPath] = entity;
    return entity.uri;
  }

  @override
  Future<Uint8List?> readBytes(String relPath) async {
    final entity = await _resolveEntity(relPath);
    if (entity == null) return null;
    return _safStream.readFileBytes(entity.uri);
  }

  @override
  Future<void> writeBytes(
    String relPath,
    List<int> bytes, {
    DateTime? lastModified,
  }) async {
    final existing = await _resolveEntity(relPath);
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final effectiveLastModified =
        (lastModified ?? DateTime.now()).millisecondsSinceEpoch;

    if (existing != null) {
      final result = await _safStream.writeFileUriBytes(existing.uri, data);
      _cache[relPath] = SafDocumentFile(
        uri: result.uri.toString(),
        name: existing.name,
        isDir: false,
        length: data.length,
        lastModified: effectiveLastModified,
      );
      return;
    }

    final parentUri = await _resolveDirUri(_parentOf(relPath));
    final fileName = _leafOf(relPath);
    final result = await _safStream.writeFileBytes(
      parentUri,
      fileName,
      'application/octet-stream',
      data,
      overwrite: true,
    );
    _cache[relPath] = SafDocumentFile(
      uri: result.uri.toString(),
      name: result.fileName ?? fileName,
      isDir: false,
      length: data.length,
      lastModified: effectiveLastModified,
    );
  }

  @override
  Future<void> delete(String relPath) async {
    final entity = await _resolveEntity(relPath);
    if (entity == null) return;
    await _safUtil.delete(entity.uri, entity.isDir);
    _cache.remove(relPath);
  }

  @override
  Future<void> createDirectory(String relPath) async {
    await _resolveDirUri(relPath);
  }

  @override
  Future<void> deleteDirectory(String relPath, {bool recursive = true}) async {
    final entity = await _resolveEntity(relPath);
    if (entity == null) return;
    await _safUtil.delete(entity.uri, true);
    _cache.removeWhere((key, _) => key == relPath || key.startsWith('$relPath/'));
  }

  @override
  Future<void> rename(String fromRelPath, String toRelPath) async {
    final entity = await _resolveEntity(fromRelPath);
    if (entity == null) return;

    final fromParent = _parentOf(fromRelPath);
    final toParent = _parentOf(toRelPath);
    final toName = _leafOf(toRelPath);

    SafDocumentFile result = entity;
    if (fromParent != toParent) {
      final fromParentUri = await _resolveDirUri(fromParent);
      final toParentUri = await _resolveDirUri(toParent);
      result = await _safUtil.moveTo(
        result.uri,
        entity.isDir,
        fromParentUri,
        toParentUri,
      );
    }
    if (_leafOf(fromRelPath) != toName) {
      result = await _safUtil.rename(result.uri, entity.isDir, toName);
    }

    _cache.remove(fromRelPath);
    _cache[toRelPath] = result;
  }

  @override
  Future<List<StorageEntity>?> list(String relPath) async {
    final String uri;
    if (relPath == '/' || relPath.isEmpty) {
      uri = rootUri;
    } else {
      final entity = await _resolveEntity(relPath);
      if (entity == null) return null;
      uri = entity.uri;
    }

    final children = await _safUtil.list(uri);
    final result = <StorageEntity>[];
    for (final child in children) {
      final childRelPath = relPath == '/' ? '/${child.name}' : '$relPath/${child.name}';
      _cache[childRelPath] = child;
      result.add(
        StorageEntity(
          name: child.name,
          isDirectory: child.isDir,
          lastModified: DateTime.fromMillisecondsSinceEpoch(child.lastModified),
        ),
      );
    }
    return result;
  }

  @override
  Future<bool> exists(String relPath) async => (await _resolveEntity(relPath)) != null;

  @override
  Future<bool> isDirectory(String relPath) async {
    if (relPath == '/' || relPath.isEmpty) return true;
    final entity = await _resolveEntity(relPath);
    return entity?.isDir ?? false;
  }

  @override
  Future<DateTime> lastModified(String relPath) async {
    final entity = await _resolveEntity(relPath);
    if (entity == null) return DateTime(2023);
    return DateTime.fromMillisecondsSinceEpoch(entity.lastModified);
  }
}
