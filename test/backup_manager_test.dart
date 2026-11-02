import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/backup_manager.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'utils/test_mock_channel_handlers.dart';

void main() {
  group('BackupManager', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();

    FlavorConfig.setup();

    setUpAll(() async {
      await FileManager.init(shouldWatchRootDirectory: false);
    });

    test('backup and restore round trip', () async {
      SharedPreferences.setMockInitialValues({
        stows.autosaveDelay.key: 5000,
        stows.pinnedColors.key: ['ff000000'],
        stows.maxImageSize.key: 1234.0,
        stows.customDataDir.key: '/should/not/be/backed/up',
      });

      const files = {
        '/backup_test/note.sbn2': 'note',
        '/backup_test/note.sbn2.0': 'asset',
        '/backup_test/sub/other.sbn2': 'other',
      };
      for (final MapEntry(key: path, value: content) in files.entries) {
        await FileManager.writeFile(
          path,
          utf8.encode(content),
          awaitWrite: true,
          alsoUpload: false,
        );
      }

      final backup = await BackupManager.createBackup();
      final zipFile = File(
        '${Directory.systemTemp.path}/saber_backup_test.zip',
      );
      await zipFile.writeAsBytes(backup);

      // wipe the notes and prefs
      await FileManager.deleteDirectory('/backup_test');
      SharedPreferences.setMockInitialValues({});

      await BackupManager.restoreBackup(zipFile.path);
      await zipFile.delete();

      for (final MapEntry(key: path, value: content) in files.entries) {
        final bytes = await FileManager.readFile(path);
        expect(bytes, isNotNull, reason: '$path should be restored');
        expect(utf8.decode(bytes!), content);
      }

      final sharedPrefs = await SharedPreferences.getInstance();
      expect(sharedPrefs.getInt(stows.autosaveDelay.key), 5000);
      expect(sharedPrefs.getStringList(stows.pinnedColors.key), ['ff000000']);
      expect(sharedPrefs.getDouble(stows.maxImageSize.key), 1234.0);
      expect(sharedPrefs.get(stows.customDataDir.key), isNull);

      await FileManager.deleteDirectory('/backup_test');
    });
  });
}
