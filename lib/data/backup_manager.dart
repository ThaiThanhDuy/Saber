import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:logging/logging.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Creates and restores backups of all notes and (non-sensitive) settings.
///
/// A backup is a zip file containing:
/// - `notes/...`: every file in the notes root, with its folder structure
/// - [prefsFileName]: the values of [Stows.backupStows], as JSON
class BackupManager {
  // disable constructor
  new _();

  static final log = Logger('BackupManager');

  static const notesPrefix = 'notes';
  static const prefsFileName = 'prefs.json';
  static const backupVersion = 1;

  static String get backupFileName =>
      'saber-backup-${DateFormat('yyyy-MM-dd_HH-mm').format(DateTime.now())}.zip';

  /// Returns the bytes of a zip file containing all notes and settings.
  static Future<Uint8List> createBackup() async {
    final archive = Archive();

    final filePaths = await FileManager.getAllRawFiles();
    for (final filePath in filePaths) {
      final bytes = await FileManager.readFile(filePath, retries: 0);
      if (bytes == null) continue;
      archive.addFile(
        ArchiveFile('$notesPrefix$filePath', bytes.length, bytes),
      );
    }

    final prefsBytes = utf8.encode(jsonEncode(await _exportPrefs()));
    archive.addFile(ArchiveFile(prefsFileName, prefsBytes.length, prefsBytes));

    log.info('Created backup with ${filePaths.length} files');
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// Restores a backup created by [createBackup] from the zip at [zipPath].
  ///
  /// Notes are merged into the existing notes root, overwriting any files
  /// with the same path. Settings in the backup overwrite current settings.
  ///
  /// Throws a [FormatException] if [zipPath] isn't a valid backup.
  static Future<void> restoreBackup(String zipPath) async {
    final inputStream = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeStream(inputStream);

      final prefsFile = archive.findFile(prefsFileName);
      if (prefsFile == null) {
        throw const FormatException('Backup is missing $prefsFileName');
      }
      final prefsJson = jsonDecode(utf8.decode(_readArchiveFile(prefsFile)));
      if (prefsJson is! Map<String, dynamic> ||
          prefsJson['prefs'] is! Map<String, dynamic>) {
        throw const FormatException('Invalid $prefsFileName');
      }

      var restoredFiles = 0;
      for (final file in archive.files) {
        if (!file.isFile) continue;
        if (!file.name.startsWith('$notesPrefix/')) continue;

        final filePath = file.name.substring(notesPrefix.length);
        if (filePath.split('/').contains('..')) {
          log.warning('Skipping unsafe path in backup: ${file.name}');
          continue;
        }

        await FileManager.writeFile(
          filePath,
          _readArchiveFile(file),
          awaitWrite: true,
        );
        restoredFiles++;
      }

      // Restore prefs last so e.g. recentFiles isn't overwritten
      // by the note writes above.
      await _importPrefs(prefsJson['prefs'] as Map<String, dynamic>);

      log.info('Restored backup with $restoredFiles files');
    } finally {
      await inputStream.close();
    }
  }

  static Uint8List _readArchiveFile(ArchiveFile file) {
    final output = OutputMemoryStream();
    file.writeContent(output);
    return output.getBytes();
  }

  static Future<Map<String, dynamic>> _exportPrefs() async {
    final sharedPrefs = await SharedPreferences.getInstance();
    return {
      'version': backupVersion,
      'prefs': {
        for (final stow in stows.backupStows)
          // Values equal to the default aren't stored, so are omitted here.
          stow.key: ?sharedPrefs.get(stow.key),
      },
    };
  }

  static Future<void> _importPrefs(Map<String, dynamic> prefs) async {
    final sharedPrefs = await SharedPreferences.getInstance();
    for (final stow in stows.backupStows) {
      final value = prefs[stow.key];
      try {
        switch (value) {
          case null:
            await sharedPrefs.remove(stow.key);
          case final bool value:
            await sharedPrefs.setBool(stow.key, value);
          case final int value:
            await sharedPrefs.setInt(stow.key, value);
          case final double value:
            await sharedPrefs.setDouble(stow.key, value);
          case final String value:
            await sharedPrefs.setString(stow.key, value);
          case final List value:
            await sharedPrefs.setStringList(stow.key, value.cast<String>());
          default:
            log.warning('Skipping unsupported value for ${stow.key}: $value');
            continue;
        }
        // Reload the in-memory value from shared preferences
        // ignore: invalid_use_of_visible_for_testing_member
        await stow.read();
      } catch (e) {
        log.warning('Failed to restore ${stow.key}', e);
      }
    }
  }
}
