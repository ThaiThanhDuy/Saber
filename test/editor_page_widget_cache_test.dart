import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/pages/editor/editor.dart';

import 'utils/test_mock_channel_handlers.dart';

/// [EditorState.pageBuilder] memoizes the [Canvas] widget it returns per
/// page, so that panning/zooming (which rebuilds every visible page every
/// frame, see [EditorState._pageWidgetCache]) doesn't force a full subtree
/// rebuild (including the QuillEditor) when nothing about that page
/// actually changed. This test guards both directions of that invariant.
void main() {
  FlavorConfig.setup();
  FileManager.documentsDirectory =
      '$tmpDir/editor_page_widget_cache_test/'
      '${FileManager.appRootDirectoryPrefix}';

  testWidgets('returns the identical widget when nothing relevant changed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Editor(path: '/editor-page-widget-cache-test')),
    );
    await tester.pumpAndSettle();

    final editorState = tester.state<EditorState>(find.byType(Editor));
    final context = tester.element(find.byType(Editor));

    final widget1 = editorState.pageBuilder(context, 0);
    final widget2 = editorState.pageBuilder(context, 0);
    expect(identical(widget1, widget2), isTrue);
  });

  testWidgets('invalidates the cache when the active tool changes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Editor(path: '/editor-page-widget-cache-test-2')),
    );
    await tester.pumpAndSettle();

    final editorState = tester.state<EditorState>(find.byType(Editor));
    final context = tester.element(find.byType(Editor));

    final beforeToolChange = editorState.pageBuilder(context, 0);
    editorState.currentTool = Eraser();
    final afterToolChange = editorState.pageBuilder(context, 0);

    expect(identical(beforeToolChange, afterToolChange), isFalse);
  });
}
