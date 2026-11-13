import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_media_writer.dart';

/// Asks where a baked result (an image changed by a tool, e.g. upscaled) goes. Asked on every save.
Future<EditorSaveTarget?> showEditorSaveTargetDialog(
  BuildContext context, {
  required bool canCopy,
  required bool canReplace,
}) {
  final message = switch ((canCopy, canReplace)) {
    (true, true) =>
      'A tool changed the image itself. Save the result as a new copy, or replace the original? '
          'A replaced original is kept as a backup.',
    (true, false) =>
      'A tool changed the image itself. The original cannot be replaced, so the result is saved as a new copy.',
    (false, true) => 'A tool changed the image itself. The result replaces the original, which is kept as a backup.',
    (false, false) => 'This image cannot be saved.',
  };

  return showDialog<EditorSaveTarget>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.t.save),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: ButtonStyle(foregroundColor: WidgetStateProperty.all(context.themeData.colorScheme.onSurfaceVariant)),
          child: Text(context.t.cancel),
        ),
        if (canReplace)
          TextButton(
            onPressed: () => Navigator.of(context).pop(EditorSaveTarget.replace),
            child: const Text('Replace original'),
          ),
        if (canCopy)
          TextButton(onPressed: () => Navigator.of(context).pop(EditorSaveTarget.copy), child: const Text('Save copy')),
      ],
    ),
  );
}
