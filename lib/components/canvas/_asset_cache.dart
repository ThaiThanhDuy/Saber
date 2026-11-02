import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:logging/logging.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/image/pdf_document_cache.dart';
import 'package:saber/data/file_manager/file_manager.dart';

/// A cache for assets that are loaded from disk.
///
/// This is the analogue to Flutter's image cache,
/// but for non-image assets.
///
/// There should be one instance of this class per
/// [EditorCoreInfo] instance.
class AssetCache {
  final log = Logger('AssetCache');

  final pdfDocumentCache = PdfDocumentCache();

  /// Maps a file's path (relative to [FileManager.documentsDirectory]) to
  /// its value.
  final Map<String, Object> _cache = {};

  /// Maps a file's relative path to the visible images that use it.
  final Map<String, Set<EditorImage>> _images = {};

  /// Whether items from the cache can be removed:
  /// set to false during file save.
  var allowRemovingAssets = true;

  /// Marks [image] as currently visible.
  ///
  /// It's safe to call this method multiple times.
  ///
  /// [relPath] is allowed to be null for convenience,
  /// in which case this function does nothing.
  void addImage<T extends Object>(EditorImage image, String? relPath, T value) {
    if (relPath == null) return;
    _images.putIfAbsent(relPath, () => {}).add(image);
    _cache[relPath] = value;
  }

  /// Returns null if [relPath] is not found.
  T? get<T extends Object>(String relPath) {
    return _cache[relPath] as T?;
  }

  /// Marks [image] as no longer visible.
  ///
  /// It's safe to call this method multiple times.
  ///
  /// If [image] is the last image using its file,
  /// the file is also removed from the cache.
  ///
  /// Returns whether the image was present in the cache.
  bool removeImage(EditorImage image) {
    if (!allowRemovingAssets) return false;

    for (final relPath in _images.keys) {
      final imagesUsingFile = _images[relPath]!;
      imagesUsingFile.remove(image);

      if (imagesUsingFile.isEmpty) {
        _images.remove(relPath);
        _cache.remove(relPath);
        return true;
      }
    }

    return false;
  }

  void dispose() {
    _images.clear();
    _cache.clear();
    pdfDocumentCache.dispose();
  }
}

class OrderedAssetCache {
  final log = Logger('OrderedAssetCache');

  final List<Object> _cache = [];

  /// Adds [value] to the cache if it is not already present and
  /// returns the index of the added item.
  int add<T extends Object>(T value) {
    int index = _cache.indexOf(value);
    if (index == -1 && value is List<int>) {
      // Lists need to be compared per item
      final listEq = const ListEquality().equals;
      for (int i = 0; i < _cache.length; i++) {
        final cacheItem = _cache[i];
        if (cacheItem is! List<int>) continue;
        if (!listEq(value, cacheItem)) continue;

        index = i;
        break;
      }
    }
    log.fine('OrderedAssetCache.add: index = $index, value = $value');

    if (index == -1) {
      _cache.add(value);
      return _cache.length - 1;
    } else {
      return index;
    }
  }

  /// The number of (distinct) items in the cache.
  int get length => _cache.length;
  bool get isEmpty => _cache.isEmpty;
  bool get isNotEmpty => _cache.isNotEmpty;

  /// Converts the item at position [index]
  /// to bytes and returns them.
  Future<List<int>> getBytes(int index) async {
    final item = _cache[index];
    if (item is List<int>) {
      return item;
    } else if (item is File) {
      // An external file outside of Saber's own storage (e.g. one the user
      // just picked to import) — always a real path, read directly.
      return item.readAsBytes();
    } else if (item is NoteAssetPath) {
      return await FileManager.readFile(item.relPath) ?? const [];
    } else if (item is String) {
      return utf8.encode(item);
    } else if (item is MemoryImage) {
      return item.bytes;
    } else if (item is SaberAssetImageProvider) {
      return await FileManager.readFile(item.relPath) ?? const [];
    } else {
      throw Exception(
        'OrderedAssetCache.getBytes: unknown type ${item.runtimeType}',
      );
    }
  }
}

/// A reference to an asset file that belongs to the current note,
/// identified by its path relative to [FileManager.documentsDirectory].
///
/// Passed to [OrderedAssetCache.add] (in place of a raw file) so that its
/// bytes can be read lazily and backend-agnostically via
/// [FileManager.readFile], rather than assuming a real filesystem path.
class NoteAssetPath {
  final String relPath;

  const new(this.relPath);

  @override
  bool operator ==(Object other) =>
      other is NoteAssetPath && other.relPath == relPath;

  @override
  int get hashCode => relPath.hashCode;
}

/// An [ImageProvider] that lazily reads its bytes from [relPath] (relative
/// to [FileManager.documentsDirectory]) via [FileManager.readFile].
///
/// This is the SAF-safe replacement for using `FileImage` directly on a
/// path under the notes directory: `FileImage` always reads with `dart:io`,
/// which can't read a `content://` SAF path.
class SaberAssetImageProvider extends ImageProvider<SaberAssetImageProvider> {
  final String relPath;
  final double scale;

  const new(this.relPath, {this.scale = 1.0});

  @override
  Future<SaberAssetImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<SaberAssetImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    SaberAssetImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      debugLabel: key.relPath,
      informationCollector: () => <DiagnosticsNode>[
        ErrorDescription('Asset path: ${key.relPath}'),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    SaberAssetImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await FileManager.readFile(key.relPath);
    if (bytes == null || bytes.isEmpty) {
      throw StateError(
        'SaberAssetImageProvider: no bytes found for ${key.relPath}',
      );
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is SaberAssetImageProvider &&
      other.relPath == relPath &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(relPath, scale);

  @override
  String toString() => 'SaberAssetImageProvider($relPath, scale: $scale)';
}

/// A [BytesLoader] that lazily reads its SVG XML from [relPath] (relative to
/// [FileManager.documentsDirectory]) via [FileManager.readFile].
///
/// This is the SAF-safe replacement for `SvgFileLoader`, which always reads
/// with `dart:io` and can't read a `content://` SAF path. [prepareMessage]
/// does the actual (async) read before handing the bytes to [provideSvg],
/// which `flutter_svg` requires to be synchronous (it runs inside
/// [compute]).
class SaberSvgAssetLoader extends SvgLoader<Uint8List> {
  final String relPath;

  const new(this.relPath, {super.theme, super.colorMapper});

  @override
  Future<Uint8List?> prepareMessage(BuildContext? context) =>
      FileManager.readFile(relPath);

  @override
  String provideSvg(Uint8List? message) =>
      utf8.decode(message ?? const [], allowMalformed: true);

  @override
  int get hashCode => Object.hash(relPath, theme, colorMapper);

  @override
  bool operator ==(Object other) =>
      other is SaberSvgAssetLoader &&
      other.relPath == relPath &&
      other.theme == theme &&
      other.colorMapper == colorMapper;
}
