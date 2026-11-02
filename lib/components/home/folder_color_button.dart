import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:saber/components/theming/adaptive_alert_dialog.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';

class FolderColorButton extends StatelessWidget {
  const new({super.key, required this.folderPath, this.afterChange});

  /// The full path of the folder, e.g. `/Folder/Subfolder`.
  final String folderPath;
  final VoidCallback? afterChange;

  static Color? getColor(String folderPath) {
    final argb = stows.folderColors.value[folderPath];
    return argb == null ? null : Color(argb);
  }

  static void setColor(String folderPath, Color? color) {
    final colors = {...stows.folderColors.value};
    if (color == null) {
      colors.remove(folderPath);
    } else {
      colors[folderPath] = color.toARGB32();
    }
    stows.folderColors.value = colors;
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      padding: .zero,
      tooltip: t.home.folderColor.changeColor,
      onPressed: () async {
        var pickedColor =
            getColor(folderPath) ?? ColorScheme.of(context).primary;
        final result = await showDialog<_ColorDialogResult>(
          context: context,
          builder: (context) => AdaptiveAlertDialog(
            title: Text(t.home.folderColor.changeColor),
            content: SingleChildScrollView(
              child: ColorPicker(
                color: pickedColor,
                pickersEnabled: const {ColorPickerType.wheel: true},
                onColorChanged: (Color color) => pickedColor = color,
              ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () =>
                    Navigator.of(context).pop(_ColorDialogResult.reset),
                child: Text(t.home.folderColor.reset),
              ),
              CupertinoDialogAction(
                onPressed: () =>
                    Navigator.of(context).pop(_ColorDialogResult.save),
                child: Text(MaterialLocalizations.of(context).saveButtonLabel),
              ),
            ],
          ),
        );
        switch (result) {
          case .save:
            setColor(folderPath, pickedColor);
          case .reset:
            setColor(folderPath, null);
          case null:
            return;
        }
        afterChange?.call();
      },
      icon: const Icon(Icons.palette),
    );
  }
}

enum _ColorDialogResult { save, reset }
