import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saber/components/home/sort_button.dart';
import 'package:saber/data/file_manager/local_storage_backend.dart';
import 'package:saber/data/file_manager/saf_storage_backend.dart';
import 'package:saber/data/file_manager/storage_backend.dart';
import 'package:saber/data/nextcloud/saber_syncer.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:share_plus/share_plus.dart';

/// A collection of cross-platform utility functions for working with a virtual file system.
class FileManager {
  // disable constructor
  new _();

  static final log = Logger('FileManager');

  static const appRootDirectoryPrefix = 'Saber';

  /// This isn't final because isolates sometimes init multiple times.
  /// Realistically, this value never changes.
  static late String documentsDirectory;

  /// Whether [documentsDirectory] is an Android Storage Access Framework
  /// tree URI (a user-picked folder outside the app's own storage) rather
  /// than a real filesystem path.
  static bool get isSafBackend => documentsDirectory.startsWith('content://');

  static StorageBackend? _cachedBackend;
  static String? _cachedBackendRoot;

  /// The backend for [documentsDirectory]. Recomputed (and cached) whenever
  /// [documentsDirectory] changes, rather than only being set in [init],
  /// since some tests set [documentsDirectory] directly.
  static StorageBackend get _backend {
    if (_cachedBackendRoot != documentsDirectory) {
      _cachedBackendRoot = documentsDirectory;
      _cachedBackend = _createBackend(documentsDirectory);
    }
    return _cachedBackend!;
  }

  static StorageBackend _createBackend(String root) =>
      root.startsWith('content://')
      ? SafStorageBackend(root)
      : LocalStorageBackend(root);

  static final fileWriteStream = StreamController<FileOperation>.broadcast();

  // TODO(adil192): Implement or remove this
  static String _sanitisePath(String path) => File(path).path;

  /// A regex that matches the file names/paths of asset files,
  /// including previews, e.g. `mynote.sbn2.1`.
  static final assetFileRegex = RegExp(r'\.sbn2?\.[\dp]+$');

  /// Forbidden names for files and directories (on any/all platforms).
  /// These patterns match the base name only (not the full path).
  /// Source: https://stackoverflow.com/a/31976060/
  static List<(String, RegExp)> _getForbiddenFilenamePatterns() => [
    (
      t.home.renameNote.noteNameForbiddenCharacters,
      RegExp(r'[<>:"/\\|?*\x00-\x1F]'),
    ),
    (
      t.home.renameNote.noteNameReserved,
      RegExp(
        r'^((con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?)|\.+$',
        caseSensitive: false,
      ),
    ),
  ];
  static String? validateFilename(String filename) {
    if (filename.isEmpty) return t.home.renameNote.noteNameEmpty;
    for (final (error, regexp) in _getForbiddenFilenamePatterns()) {
      if (regexp.hasMatch(filename)) return error;
    }
    return null;
  }

  static Future<void> init({
    String? documentsDirectory,
    bool shouldWatchRootDirectory = true,
  }) async {
    FileManager.documentsDirectory =
        documentsDirectory ?? await getDocumentsDirectory();

    if (shouldWatchRootDirectory) unawaited(watchRootDirectory());
  }

  static Future<String> getDocumentsDirectory() async =>
      stows.customDataDir.value ?? await getDefaultDocumentsDirectory();

  static Future<String> getDefaultDocumentsDirectory() async =>
      '${(await getApplicationDocumentsDirectory()).path}/$appRootDirectoryPrefix';

  /// Whether the directory at [path] (a real path, or a SAF `content://`
  /// tree URI) has no children. Used by the "custom Saber folder" settings
  /// UI to validate a candidate folder before switching to it.
  static Future<bool> isDirEmpty(String path) async =>
      await _isBackendEmpty(_createBackend(path));

  static Future<bool> _isBackendEmpty(StorageBackend backend) async {
    final entities = await backend.list('/');
    return entities == null || entities.isEmpty;
  }

  static Future<void> migrateDataDir() async {
    final oldDirPath = documentsDirectory;
    final newDirPath = await getDocumentsDirectory();
    if (oldDirPath == newDirPath) return;
    log.info('Migrating data directory from $oldDirPath to $newDirPath');

    final oldBackend = _backend;
    final newBackend = _createBackend(newDirPath);

    final oldDirEmpty = await _isBackendEmpty(oldBackend);
    final newDirEmpty = await _isBackendEmpty(newBackend);

    if (!oldDirEmpty && !newDirEmpty) {
      log.severe('New and old data directory aren\'t empty, can\'t migrate');
      return;
    }

    documentsDirectory = newDirPath;

    if (oldDirEmpty) {
      log.fine('Old data directory is empty or missing, nothing to migrate');
      return;
    }

    if (oldBackend is LocalStorageBackend &&
        newBackend is LocalStorageBackend) {
      await moveDirContents(
        oldDir: Directory(oldDirPath),
        newDir: Directory(newDirPath),
      );
      await Directory(oldDirPath).delete(recursive: true);
    } else {
      await _moveDirContentsGeneric(oldBackend, newBackend);
      // Only delete the (now-emptied) old folder entity itself if it was a
      // local, Saber-private directory. A SAF folder was explicitly picked
      // by the user and may still be meaningful to them outside of Saber,
      // so we leave it in place (empty) rather than deleting it.
      if (oldBackend is LocalStorageBackend) {
        await Directory(oldDirPath).delete(recursive: true);
      }
    }
  }

  /// Fast path for local-to-local migration: uses real filesystem
  /// rename/copy operations directly.
  static Future<void> moveDirContents({
    required Directory oldDir,
    required Directory newDir,
  }) async {
    await newDir.create(recursive: true);

    await for (final entity in oldDir.list(recursive: true)) {
      // Get the path under oldDir and map it into newDir.
      final relative = p.relative(entity.path, from: oldDir.path);
      final targetPath = p.join(newDir.path, relative);

      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
        continue;
      }

      if (entity is File) {
        // Ensure parent exists
        await entity.parent.create(recursive: true);

        try {
          await entity.rename(targetPath);
        } on FileSystemException catch (e) {
          // Cross device move, eg. private to public on android
          const exdev = 18;
          if (e.osError?.errorCode == exdev) {
            await entity.copy(targetPath);
            await entity.delete();
          } else {
            rethrow;
          }
        }
      }
    }
  }

  /// Generic path for any migration involving a SAF backend: copies bytes
  /// through [FileManager]'s own read/write API instead of relying on a
  /// real filesystem rename/copy.
  static Future<void> _moveDirContentsGeneric(
    StorageBackend oldBackend,
    StorageBackend newBackend, {
    String dir = '/',
  }) async {
    final entities = await oldBackend.list(dir);
    if (entities == null) return;

    for (final entity in entities) {
      final childPath = '$dir${entity.name}';
      if (entity.isDirectory) {
        await newBackend.createDirectory(childPath);
        await _moveDirContentsGeneric(
          oldBackend,
          newBackend,
          dir: '$childPath/',
        );
        await oldBackend.deleteDirectory(childPath, recursive: false);
      } else {
        final bytes = await oldBackend.readBytes(childPath);
        if (bytes != null) {
          final modified = await oldBackend.lastModified(childPath);
          await newBackend.writeBytes(childPath, bytes, lastModified: modified);
        }
        await oldBackend.delete(childPath);
      }
    }
  }

  @visibleForTesting
  static Future<void> watchRootDirectory() async {
    if (isSafBackend) return; // no OS-level watch equivalent for SAF
    final rootDir = Directory(documentsDirectory);
    await rootDir.create(recursive: true);
    if (Platform.isIOS) return;
    rootDir.watch(recursive: true).listen((event) {
      final FileOperationType type = switch (event.type) {
        FileSystemEvent.delete => .delete,
        FileSystemEvent.create => .write,
        FileSystemEvent.modify => .write,
        FileSystemEvent.move => .write,
        _ =>
          kDebugMode
              ? throw UnimplementedError(
                  'Unhandled FileSystemEvent type: ${event.type}',
                )
              : .write,
      };
      final String path = event.path
          .replaceAll('\\', '/')
          // The path may or may not be relative,
          // so remove the root directory path to make sure it's relative.
          .replaceFirst(documentsDirectory, '');
      broadcastFileWrite(type, path);
    });
  }

  @visibleForTesting
  static void broadcastFileWrite(FileOperationType type, String path) async {
    if (!fileWriteStream.hasListener) return;

    // remove extension
    if (path.endsWith(Editor.extension)) {
      path = path.substring(0, path.length - Editor.extension.length);
    } else if (path.endsWith(Editor.extensionOldJson)) {
      path = path.substring(0, path.length - Editor.extensionOldJson.length);
    }

    fileWriteStream.add(FileOperation(type, path));
  }

  /// Returns the contents of the file at [filePath].
  static Future<Uint8List?> readFile(String filePath, {int retries = 3}) async {
    filePath = _sanitisePath(filePath);

    Uint8List? result;
    if (shouldUseRawFilePath) {
      final file = getFile(filePath);
      if (file.existsSync()) {
        result = await file.readAsBytes();
        if (result.isEmpty) result = null;
      } else {
        retries = 0; // don't retry if the file doesn't exist
      }
    } else if (await _backend.exists(filePath)) {
      result = await _backend.readBytes(filePath);
      if (result != null && result.isEmpty) result = null;
    } else {
      retries = 0; // don't retry if the file doesn't exist
    }

    // If result is null, try again in case the file was locked.
    if (result == null && retries > 0) {
      await Future.delayed(const Duration(milliseconds: 100));
      return readFile(filePath, retries: retries - 1);
    }
    return result;
  }

  /// Whether [getFile], [doesFileExist], [isDirectory] and [lastModified]
  /// should bypass [_backend] and just use `dart:io` directly on
  /// [filePath] unmodified, instead of prefixing with the documents
  /// directory. This is useful for testing when test files aren't in the
  /// documents directory, and only ever applies to the local backend (SAF
  /// paths are never "raw" filesystem paths to begin with).
  @visibleForTesting
  static var shouldUseRawFilePath = false;

  /// Returns a `dart:io` [File] for [filePath]. Only meaningful for the
  /// local backend — do not call this when [isSafBackend] is true, since a
  /// `content://` URI isn't a real path `dart:io` can read/write.
  static File getFile(String filePath) {
    if (shouldUseRawFilePath) {
      return File(filePath);
    } else {
      assert(
        filePath.startsWith('/'),
        'Expected filePath to start with a slash, got $filePath',
      );
      return File(documentsDirectory + filePath);
    }
  }

  /// Writes [toWrite] to [filePath].
  ///
  /// The file at [toPath] will have its last modified timestamp set to
  /// [lastModified], if specified.
  /// This is useful when downloading remote files, to make sure that the
  /// timestamp is the same locally and remotely.
  static Future<void> writeFile(
    String filePath,
    List<int> toWrite, {
    bool awaitWrite = false,
    bool alsoUpload = true,
    DateTime? lastModified,
  }) async {
    filePath = _sanitisePath(filePath);
    log.fine('Writing to $filePath');

    await _saveFileAsRecentlyAccessed(filePath);

    await _createFileDirectory(filePath);
    Future writeFuture = Future.wait([
      _backend.writeBytes(filePath, toWrite, lastModified: lastModified),
      // if we're using a new format, also delete the old file
      if (filePath.endsWith(Editor.extension))
        _backend.delete(
          '${filePath.substring(0, filePath.length - Editor.extension.length)}'
          '${Editor.extensionOldJson}',
        ),
    ]);

    void afterWrite() {
      broadcastFileWrite(FileOperationType.write, filePath);
      if (alsoUpload) syncer.uploader.enqueueRel(filePath);
      if (filePath.endsWith(Editor.extension)) {
        _removeReferences(
          '${filePath.substring(0, filePath.length - Editor.extension.length)}'
          '${Editor.extensionOldJson}',
        );
      }
    }

    writeFuture = writeFuture.then((_) => afterWrite());
    if (awaitWrite) await writeFuture;
  }

  static Future<void> createFolder(String folderPath) async {
    folderPath = _sanitisePath(folderPath);
    await _backend.createDirectory(folderPath);
  }

  static Future exportFile(
    String fileName,
    Uint8List bytes, {
    bool isImage = false,
    required BuildContext context,
  }) async {
    File? tempFile;
    Future<File> getTempFile() async {
      final tempFolder = (await getTemporaryDirectory()).path;
      final file = File('$tempFolder/$fileName');
      await file.writeAsBytes(bytes);
      return file;
    }

    if (Platform.isAndroid || Platform.isIOS) {
      if (isImage) {
        // request permission
        final permissionGranted = await _requestPhotosPermission();
        // save image to gallery
        if (permissionGranted) {
          await SaverGallery.saveImage(
            Uint8List.fromList(bytes),
            fileName: fileName,
            albumPath: 'Saber',
            skipIfExists: true,
          );
        }
      } else {
        // share file
        tempFile = await getTempFile();
        if (Platform.isIOS || Platform.isMacOS) {
          if (!context.mounted) return;
          final box = context.findRenderObject() as RenderBox;
          await SharePlus.instance.share(
            ShareParams(
              files: [XFile(tempFile.path)],
              // iOS requires a sharePositionOrigin for the share sheet to appear
              sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
            ),
          );
        } else {
          await SharePlus.instance.share(
            ShareParams(files: [XFile(tempFile.path)]),
          );
        }
      }
    } else {
      // desktop, open save-as dialog
      await FilePicker.saveFile(
        fileName: fileName,
        initialDirectory: (await getDownloadsDirectory())?.path,
        type: FileType.custom,
        allowedExtensions: [fileName.split('.').last],
        bytes: bytes,
      );
    }

    // delete temp file if it isn't null
    await tempFile?.delete();
  }

  static Future<bool> _requestPhotosPermission() async {
    if (Platform.isIOS) {
      return await Permission.photosAddOnly.request().isGranted;
    } else if (!Platform.isAndroid) {
      return true;
    }

    final sdkInt = await DeviceInfoPlugin().androidInfo.then(
      (info) => info.version.sdkInt,
    );
    if (sdkInt > 33) {
      return await Permission.photos.request().isGranted;
    } else {
      return await Permission.storage.request().isGranted;
    }
  }

  /// Moves a file from [fromPath] to [toPath], returning its final path.
  ///
  /// If a file already exists at [toPath], [fromPath] will be suffixed with
  /// a number e.g. "file (1)". If [replaceExistingFile] is true, the existing
  /// file will be overwritten instead.
  ///
  /// If [replaceExistingFile] is true but the file is a reserved file name,
  /// the filename will be suffixed with a number instead
  /// (like if [replaceExistingFile] was false).
  static Future<String> moveFile(
    String fromPath,
    String toPath, {
    bool replaceExistingFile = false,
    bool alsoMoveAssets = true,
  }) async {
    fromPath = _sanitisePath(fromPath);
    toPath = _sanitisePath(toPath);

    if (!toPath.contains('/')) {
      // if toPath is a relative path
      toPath = fromPath.substring(0, fromPath.lastIndexOf('/') + 1) + toPath;
    }

    if (!replaceExistingFile || Editor.isReservedPath(toPath)) {
      toPath = await suffixFilePathToMakeItUnique(
        toPath,
        currentPath: fromPath,
      );
    }

    if (fromPath == toPath) return toPath;

    if (await _backend.exists(fromPath)) {
      await _createFileDirectory(toPath);
      await _backend.rename(fromPath, toPath);
    } else {
      log.warning('Tried to move non-existent file from $fromPath to $toPath');
    }

    syncer.uploader.enqueueRel(fromPath);
    syncer.uploader.enqueueRel(toPath);

    _renameReferences(fromPath, toPath);
    broadcastFileWrite(FileOperationType.delete, fromPath);
    broadcastFileWrite(FileOperationType.write, toPath);

    if (alsoMoveAssets && !assetFileRegex.hasMatch(fromPath)) {
      final assets = <String>[];
      for (int assetNumber = 0; true; assetNumber++) {
        if (await _backend.exists('$fromPath.$assetNumber')) {
          assets.add('$assetNumber');
        } else {
          break;
        }
      }
      if (await _backend.exists('$fromPath.p')) {
        assets.add('p');
      }

      await Future.wait([
        for (final assetNumber in assets)
          moveFile(
            '$fromPath.$assetNumber',
            '$toPath.$assetNumber',
            replaceExistingFile: replaceExistingFile,
          ),
      ]);
    }

    return toPath;
  }

  static Future deleteFile(
    String filePath, {
    bool alsoUpload = true,
    bool alsoDeleteAssets = true,
  }) async {
    filePath = _sanitisePath(filePath);

    if (!await _backend.exists(filePath)) return;
    await _backend.delete(filePath);

    if (alsoUpload) syncer.uploader.enqueueRel(filePath);

    _removeReferences(filePath);
    broadcastFileWrite(FileOperationType.delete, filePath);

    if (alsoDeleteAssets && !assetFileRegex.hasMatch(filePath)) {
      final assets = <int>[];
      for (int assetNumber = 0; true; assetNumber++) {
        if (await _backend.exists('$filePath.$assetNumber')) {
          assets.add(assetNumber);
        } else {
          break;
        }
      }

      final hasPreview = await _backend.exists('$filePath.p');
      await Future.wait([
        for (final assetNumber in assets)
          deleteFile('$filePath.$assetNumber', alsoDeleteAssets: false),
        if (hasPreview) deleteFile('$filePath.p', alsoDeleteAssets: false),
      ]);
    }
  }

  static Future removeUnusedAssets(
    String filePath, {
    required int numAssets,
  }) async {
    final futures = <Future>[];

    for (int assetNumber = numAssets; true; assetNumber++) {
      final assetPath = '$filePath.$assetNumber';
      if (await _backend.exists(assetPath)) {
        futures.add(deleteFile(assetPath));
      } else {
        break;
      }
    }

    await Future.wait(futures);
  }

  static Future renameDirectory(String directoryPath, String newName) async {
    directoryPath = _sanitisePath(directoryPath);

    if (!await _backend.isDirectory(directoryPath)) return;

    /// recursively find children of [directoryPath] for [_renameReferences]
    final List<String> children = [];
    for (final fullPath in await getAllFiles(
      includeExtensions: true,
      includeAssets: true,
      rootDir: '$directoryPath/',
    )) {
      children.add(fullPath.substring(directoryPath.length));
    }

    final String newPath =
        directoryPath.substring(0, directoryPath.lastIndexOf('/') + 1) +
        newName;
    await _backend.rename(directoryPath, newPath);

    for (final child in children) {
      _renameReferences(directoryPath + child, newPath + child);
      broadcastFileWrite(FileOperationType.delete, directoryPath + child);
      broadcastFileWrite(FileOperationType.write, newPath + child);
    }
    _renameFolderColors(directoryPath, newPath);
  }

  static Future deleteDirectory(
    String directoryPath, [
    bool recursive = true,
  ]) async {
    directoryPath = _sanitisePath(directoryPath);

    if (!await _backend.isDirectory(directoryPath)) return;

    if (recursive) {
      // call [deleteFile] on all files that are descendants of the directory
      final files = await getAllFiles(
        includeExtensions: true,
        includeAssets: true,
        rootDir: '$directoryPath/',
      );
      for (final file in files) {
        await deleteFile(file);
      }
    }

    await _backend.deleteDirectory(directoryPath, recursive: recursive);
    _renameFolderColors(directoryPath, null);
  }

  /// Moves the custom colors of [fromPath] and its subfolders to [toPath],
  /// or removes them if [toPath] is null.
  static void _renameFolderColors(String fromPath, String? toPath) {
    final oldColors = stows.folderColors.value;
    final newColors = <String, int>{};
    for (final MapEntry(key: path, value: color) in oldColors.entries) {
      if (path == fromPath || path.startsWith('$fromPath/')) {
        if (toPath != null) {
          newColors[toPath + path.substring(fromPath.length)] = color;
        }
      } else {
        newColors[path] = color;
      }
    }
    if (newColors.length == oldColors.length &&
        newColors.keys.every(oldColors.containsKey)) {
      return;
    }
    stows.folderColors.value = newColors;
  }

  /// Gets the children of a directory, separated into
  /// [DirectoryChildren.directories] and [DirectoryChildren.files].
  ///
  /// If [includeExtensions] is false (default), the extension will be removed
  /// from the file names. We use this to get all notes in a directory.
  ///
  /// If [includeAssets] is true, assets and previews will be included.
  /// We use this for syncing.
  ///
  /// Note: [includeAssets] can't be true without [includeExtension],
  /// since otherwise we wouldn't be able to tell the difference between notes
  /// and assets.
  static Future<DirectoryChildren?> getChildrenOfDirectory(
    String directory, {
    bool includeExtensions = false,
    bool includeAssets = false,
    SortMetric sortMetric = .nameAToZ,
  }) async {
    assert(
      !includeAssets || includeExtensions,
      'includeAssets can\'t be true without includeExtensions',
    );

    directory = _sanitisePath(directory);
    if (!directory.endsWith('/')) directory += '/';

    final entities = await _backend.list(directory);
    if (entities == null) return null;

    final List<String> directories = [], files = [];
    // Populated from the same listing that gave us [entities], so sorting
    // by last-modified below usually doesn't need any extra backend calls.
    final Map<String, DateTime> lastModifiedCache = {};

    for (final entity in entities) {
      final child = entity.name;

      // directories don't need any further processing
      if (entity.isDirectory) {
        if (!directories.contains(child)) directories.add(child);
        continue;
      }

      // filter out reserved files
      if (Editor.isReservedPath(directory + child)) continue;

      final isSbn2 = child.endsWith(Editor.extension);
      final isSbn1 = child.endsWith(Editor.extensionOldJson);

      final String name;
      if (!includeExtensions) {
        if (isSbn2) {
          name = child.substring(0, child.length - Editor.extension.length);
        } else if (isSbn1) {
          name = child.substring(
            0,
            child.length - Editor.extensionOldJson.length,
          );
        } else {
          continue; // child is the name of some asset
        }
      } else {
        if (!includeAssets && !isSbn2 && !isSbn1) continue; // asset
        name = child;
      }

      if (!includeAssets && assetFileRegex.hasMatch(name)) continue;

      if (entity.lastModified != null) {
        lastModifiedCache['$directory$name${Editor.extension}'] =
            entity.lastModified!;
      }
      files.add(name);
    }

    switch (sortMetric) {
      case .nameAToZ:
        directories.sort();
        files.sort();
      case .nameZToA:
        directories.sort((child, other) => -child.compareTo(other));
        files.sort((child, other) => -child.compareTo(other));
      case .lastModifiedNewToOld:
      case .lastModifiedOldToNew:
        directories.sort();
        final dates = await Future.wait([
          for (final file in files)
            _cachedLastModified(
              lastModifiedCache,
              '$directory$file${Editor.extension}',
            ),
        ]);
        final indexed = [
          for (var i = 0; i < files.length; i++) (files[i], dates[i]),
        ];
        final ascending = sortMetric == .lastModifiedOldToNew;
        indexed.sort(
          (a, b) => ascending ? a.$2.compareTo(b.$2) : -a.$2.compareTo(b.$2),
        );
        files
          ..clear()
          ..addAll([for (final entry in indexed) entry.$1]);
    }

    return DirectoryChildren(directories, files);
  }

  static Future<DateTime> _cachedLastModified(
    Map<String, DateTime> cache,
    String relPath,
  ) async => cache[relPath] ?? await lastModified(relPath);

  /// Returns a list of all files recursively under [rootDir] (the notes
  /// root by default).
  ///
  /// See [getChildrenOfDirectory] for more information on the parameters.
  static Future<List<String>> getAllFiles({
    bool includeExtensions = false,
    bool includeAssets = false,
    String rootDir = '/',
  }) async {
    final allFiles = <String>[];
    final directories = <String>[rootDir];

    while (directories.isNotEmpty) {
      final directory = directories.removeLast();
      final children = await getChildrenOfDirectory(
        directory,
        includeExtensions: includeExtensions,
        includeAssets: includeAssets,
      );
      if (children == null) continue;

      for (final file in children.files) {
        allFiles.add('$directory$file');
      }
      for (final childDirectory in children.directories) {
        directories.add('$directory$childDirectory/');
      }
    }

    return allFiles;
  }

  /// Returns every file under the notes root, without filtering out
  /// assets, reserved files (e.g. the whiteboard) or unknown file types.
  /// Used for backups.
  static Future<List<String>> getAllRawFiles({String dir = '/'}) async {
    final entities = await _backend.list(dir);
    if (entities == null) return const [];

    final files = <String>[];
    for (final entity in entities) {
      final childPath = '$dir${entity.name}';
      if (entity.isDirectory) {
        files.addAll(await getAllRawFiles(dir: '$childPath/'));
      } else {
        files.add(childPath);
      }
    }
    return files;
  }

  static Future<List<String>> getRecentlyAccessed() async {
    if (!stows.recentFiles.loaded) await stows.recentFiles.waitUntilRead();
    // Delete entries for files that have been deleted outside of Saber
    for (final file in stows.recentFiles.value.toList()) {
      if (!await doesFileExist(file)) await _removeReferences(file);
    }
    return stows.recentFiles.value
        .map((String filePath) {
          if (filePath.endsWith(Editor.extension)) {
            return filePath.substring(
              0,
              filePath.length - Editor.extension.length,
            );
          } else if (filePath.endsWith(Editor.extensionOldJson)) {
            return filePath.substring(
              0,
              filePath.length - Editor.extensionOldJson.length,
            );
          } else {
            return filePath;
          }
        })
        .where(
          (String file) => !Editor.isReservedPath(file),
        ) // filter out reserved file names
        .toList();
  }

  /// Returns whether the [filePath] is a directory or file.
  /// Behaviour is undefined if [filePath] is not a valid path.
  static Future<bool> isDirectory(String filePath) async {
    filePath = _sanitisePath(filePath);
    if (shouldUseRawFilePath) return Directory(filePath).existsSync();
    return _backend.isDirectory(filePath);
  }

  static Future<bool> doesFileExist(String filePath) async {
    filePath = _sanitisePath(filePath);
    if (shouldUseRawFilePath) return File(filePath).existsSync();
    return _backend.exists(filePath);
  }

  static Future<DateTime> lastModified(String filePath) async {
    filePath = _sanitisePath(filePath);
    if (shouldUseRawFilePath) {
      final file = File(filePath);
      if (!file.existsSync()) return DateTime(2023);
      return file.lastModifiedSync();
    }
    return _backend.lastModified(filePath);
  }

  static Future<String> newFilePath([String parentPath = '/']) async {
    assert(parentPath.endsWith('/'));

    final DateTime now = DateTime.now();
    final String filePath =
        '$parentPath${DateFormat("yy-MM-dd").format(now)} '
        '${t.editor.untitled}';

    return await suffixFilePathToMakeItUnique(filePath);
  }

  /// Returns a unique file path by appending a number to the end of the [filePath].
  /// e.g. "/Untitled" -> "/Untitled (2)"
  ///
  /// Providing a [currentPath] means that e.g. "/Untitled (2)" being renamed
  /// to "/Untitled" will be returned as "/Untitled (2)" not "/Untitled (3)".
  ///
  /// If [currentPath] is provided, it must
  /// end with [Editor.extension] or [Editor.extensionOldJson].
  static Future<String> suffixFilePathToMakeItUnique(
    String filePath, {
    String? intendedExtension,
    String? currentPath,
  }) async {
    String newFilePath = filePath;
    bool hasExtension = false;

    if (filePath.endsWith(Editor.extension)) {
      filePath = filePath.substring(
        0,
        filePath.length - Editor.extension.length,
      );
      newFilePath = filePath;
      hasExtension = true;
      intendedExtension ??= Editor.extension;
    } else if (filePath.endsWith(Editor.extensionOldJson)) {
      filePath = filePath.substring(
        0,
        filePath.length - Editor.extensionOldJson.length,
      );
      newFilePath = filePath;
      hasExtension = true;
      intendedExtension ??= Editor.extensionOldJson;
    } else {
      intendedExtension ??= Editor.extension;
    }

    int i = 1;
    while (true) {
      if (!await doesFileExist(newFilePath + Editor.extension) &&
          !await doesFileExist(newFilePath + Editor.extensionOldJson))
        break;
      if (newFilePath + Editor.extension == currentPath) break;
      if (newFilePath + Editor.extensionOldJson == currentPath) break;
      i++;
      newFilePath = '$filePath ($i)';
    }

    return newFilePath + (hasExtension ? intendedExtension : '');
  }

  /// Imports a file from a sharing intent.
  ///
  /// [parentDir], if provided, must start and end with a slash.
  ///
  /// [extension], if provided, must start with a dot.
  /// If not provided, it will be inferred from the [path].
  ///
  /// Returns the file path of the imported file.
  static Future<String?> importFile(
    String path,
    String? parentDir, {
    String? extension,
    bool awaitWrite = true,
  }) async {
    assert(
      parentDir == null || parentDir.startsWith('/') && parentDir.endsWith('/'),
    );

    if (extension == null) {
      extension = '.${path.split('.').last}';
      assert(extension.length > 1);
    } else {
      assert(extension.startsWith('.')); // extension must start with a dot
    }

    /// The file name without its extension
    String fileName = path.split(RegExp(r'[\\/]')).last;
    fileName = fileName.substring(0, fileName.lastIndexOf('.'));
    final String importedPath;

    final writeFutures = <Future>[];

    if (extension.toLowerCase() == '.sba') {
      final inputStream = InputFileStream(path);
      final archive = ZipDecoder().decodeStream(inputStream);

      final mainFile = archive.files.cast<ArchiveFile?>().firstWhere(
        (file) =>
            file!.name.toLowerCase().endsWith('sbn') ||
            file.name.toLowerCase().endsWith('sbn2'),
        orElse: () => null,
      );
      if (mainFile == null) {
        log.severe('Failed to find main note in sba: $path');
        return null;
      }
      final mainFileExtension = '.${mainFile.name.split('.').last}'
          .toLowerCase();
      importedPath = await suffixFilePathToMakeItUnique(
        '${parentDir ?? '/'}$fileName',
        intendedExtension: mainFileExtension,
      );
      final mainFileContents = () {
        final output = OutputMemoryStream();
        mainFile.writeContent(output);
        return output.getBytes();
      }();
      writeFutures.add(
        writeFile(
          importedPath + mainFileExtension,
          mainFileContents,
          awaitWrite: awaitWrite,
        ),
      );

      // now import assets
      for (final file in archive.files) {
        if (!file.isFile) continue;
        if (file == mainFile) continue;

        final extension = file.name.split('.').last;
        final assetNumber = int.tryParse(extension);
        if (assetNumber == null) continue;
        if (assetNumber < 0) continue;

        final assetBytes = () {
          final output = OutputMemoryStream();
          file.writeContent(output);
          return output.getBytes();
        }();
        writeFutures.add(
          writeFile(
            '$importedPath$mainFileExtension.$assetNumber',
            assetBytes,
            awaitWrite: awaitWrite,
          ),
        );
      }
    } else {
      // import sbn or sbn2
      final file = File(path);
      final fileContents = await file.readAsBytes();
      importedPath = await suffixFilePathToMakeItUnique(
        '${parentDir ?? '/'}$fileName',
        intendedExtension: extension.toLowerCase(),
      );
      writeFutures.add(
        writeFile(
          importedPath + extension.toLowerCase(),
          fileContents,
          awaitWrite: awaitWrite,
        ),
      );
    }

    await Future.wait(writeFutures);

    return importedPath;
  }

  /// Creates the parent directories of filePath if they don't exist.
  static Future _createFileDirectory(String filePath) async {
    assert(filePath.contains('/'), 'filePath must be a path, not a file name');
    final parentDirectory = filePath.substring(0, filePath.lastIndexOf('/'));
    await _backend.createDirectory(parentDirectory);
  }

  static Future _renameReferences(String fromPath, String toPath) async {
    // rename file in recently accessed
    bool replaced = false;
    for (int i = 0; i < stows.recentFiles.value.length; i++) {
      if (stows.recentFiles.value[i] != fromPath) continue;
      if (!replaced) {
        stows.recentFiles.value[i] = toPath;
        replaced = true;
      } else {
        stows.recentFiles.value.removeAt(i);
      }
    }
    stows.recentFiles.notifyListeners();
  }

  static Future _removeReferences(String filePath) async {
    // remove file from recently accessed
    for (int i = 0; i < stows.recentFiles.value.length; i++) {
      if (stows.recentFiles.value[i] != filePath) continue;
      stows.recentFiles.value.removeAt(i);
    }
    stows.recentFiles.notifyListeners();
  }

  static Future _saveFileAsRecentlyAccessed(String filePath) async {
    // don't add assets to recently accessed
    if (assetFileRegex.hasMatch(filePath)) return;

    stows.recentFiles.value.remove(filePath);
    stows.recentFiles.value.insert(0, filePath);
    if (stows.recentFiles.value.length > maxRecentlyAccessedFiles)
      stows.recentFiles.value.removeLast();

    stows.recentFiles.notifyListeners();
  }

  static const maxRecentlyAccessedFiles = 30;
}

class DirectoryChildren {
  final List<String> directories;
  final List<String> files;

  new(this.directories, this.files);

  bool onlyOneChild() => directories.length + files.length <= 1;

  bool get isEmpty => directories.isEmpty && files.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

enum FileOperationType { write, delete }

class FileOperation {
  final FileOperationType type;
  final String filePath;

  const new(this.type, this.filePath);
}
