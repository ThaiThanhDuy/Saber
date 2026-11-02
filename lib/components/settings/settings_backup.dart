import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:saber/components/settings/settings_button.dart';
import 'package:saber/components/theming/adaptive_alert_dialog.dart';
import 'package:saber/data/backup_manager.dart';
import 'package:saber/i18n/strings.g.dart';

/// Buttons to export and import a backup of all notes and settings.
class SettingsBackup extends StatefulWidget {
  const new({super.key});

  @override
  State<SettingsBackup> createState() => _SettingsBackupState();
}

class _SettingsBackupState extends State<SettingsBackup> {
  static final log = Logger('SettingsBackup');

  var _busy = false;

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _exportBackup() async {
    setState(() => _busy = true);
    _showSnackBar(t.settings.backup.exporting);
    try {
      final bytes = await BackupManager.createBackup();
      if (!mounted) return;
      // Let the user pick where to save the backup,
      // instead of FileManager.exportFile's share sheet on mobile.
      await FilePicker.saveFile(
        fileName: BackupManager.backupFileName,
        bytes: bytes,
        mimeType: 'application/zip',
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importBackup() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    final filePath = file?.path;
    if (filePath == null) return;
    if (!filePath.toLowerCase().endsWith('.zip')) {
      _showSnackBar(t.settings.backup.importFailed);
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AdaptiveAlertDialog(
        title: Text(t.settings.backup.importBackup),
        content: Text(t.settings.backup.importConfirm),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.common.cancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.common.continueBtn),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    _showSnackBar(t.settings.backup.importing);
    try {
      await BackupManager.restoreBackup(filePath);
      _showSnackBar(t.settings.backup.importSuccess);
    } catch (e, st) {
      log.warning('Failed to restore backup', e, st);
      _showSnackBar(t.settings.backup.importFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SettingsButton(
          title: t.settings.backup.exportBackup,
          subtitle: t.settings.backup.exportBackupDescription,
          icon: Icons.backup,
          onPressed: _busy ? null : _exportBackup,
        ),
        SettingsButton(
          title: t.settings.backup.importBackup,
          subtitle: t.settings.backup.importBackupDescription,
          icon: Icons.settings_backup_restore,
          onPressed: _busy ? null : _importBackup,
        ),
      ],
    );
  }
}
