import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_ids.dart';
import 'package:immich_mobile/infrastructure/repositories/device_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/downloads_rule.repository.dart';
import 'package:immich_mobile/presentation/widgets/shell/shell_list.widget.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/downloads_rule.provider.dart';

Future<void> showDownloadsRuleDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _DownloadsRuleDialog());

class _DownloadsRuleDialog extends ConsumerStatefulWidget {
  const _DownloadsRuleDialog();

  @override
  ConsumerState<_DownloadsRuleDialog> createState() => _DownloadsRuleDialogState();
}

class _DownloadsRuleDialogState extends ConsumerState<_DownloadsRuleDialog> {
  DownloadsRule? _rule;
  List<DeviceAlbum> _folders = const [];
  String _defaultName = DownloadsOrganizer.defaultTargetName;
  bool _running = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final organizer = ref.read(downloadsOrganizerProvider);
    final rule = await organizer.load();
    final folders = await const DeviceAlbumRepository().albums();
    final fallback = await organizer.defaultTarget();
    if (mounted) {
      setState(() {
        _rule = rule;
        _folders = folders.where((folder) => !{'download', 'downloads'}.contains(folder.name.toLowerCase())).toList();
        _defaultName = fallback.name;
      });
    }
  }

  Future<void> _update(DownloadsRule rule) async {
    await ref.read(downloadsOrganizerProvider).save(rule);
    setState(() => _rule = rule);
  }

  Future<void> _selectFolder(String? folderId) async {
    final rule = _rule!;
    if (folderId == null) {
      await _update(DownloadsRule(enabled: rule.enabled));
      return;
    }
    final folder = _folders.firstWhere((folder) => folder.id == folderId);
    final path = await const DeviceAlbumRepository().relativePathOf(folder.id);
    await _update(DownloadsRule(enabled: rule.enabled, targetName: folder.name, targetRelativePath: path));
  }

  Future<void> _runNow() async {
    setState(() {
      _running = true;
      _result = null;
    });
    final moved = await ref.read(downloadsOrganizerProvider).run(force: true);
    await ref.read(backgroundSyncProvider).syncLocal();
    if (mounted) {
      setState(() {
        _running = false;
        _result = moved == 0 ? 'Nothing to move' : 'Moved $moved item${moved == 1 ? '' : 's'}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final rule = _rule;
    final selectedId = rule?.targetName == null
        ? null
        : _folders.where((folder) => folder.name == rule!.targetName).firstOrNull?.id;

    return AlertDialog(
      title: const Text('Downloads'),
      content: rule == null
          ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Move downloaded photos and videos'),
                  subtitle: const Text('Anything that appears in Download is moved automatically'),
                  value: rule.enabled,
                  onChanged: (enabled) => _update(
                    DownloadsRule(
                      enabled: enabled,
                      targetName: rule.targetName,
                      targetRelativePath: rule.targetRelativePath,
                    ),
                  ),
                ),
                DropdownButtonFormField<String?>(
                  initialValue: selectedId,
                  decoration: const InputDecoration(labelText: 'Move to'),
                  items: [
                    DropdownMenuItem(value: null, child: Text('$_defaultName (default)')),
                    for (final folder in _folders) DropdownMenuItem(value: folder.id, child: Text(folder.name)),
                  ],
                  onChanged: _selectFolder,
                ),
                if (_result != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_result!)),
                ShellList(
                  slot: ShellSlots.downloadsRuleDialogSections,
                  items: const [],
                  slotContext: {'enabled': rule.enabled, 'targetName': rule.targetName},
                  builder: (context, sections) => Column(mainAxisSize: MainAxisSize.min, children: sections),
                ),
              ],
            ),
      actions: [
        ShellList(
          slot: ShellSlots.downloadsRuleDialogActions,
          kind: ShellListKind.buttons,
          items: [
            ShellItem(
              DownloadsRuleDialogIds.runNow,
              TextButton(onPressed: _running || rule == null ? null : _runNow, child: const Text('Run now')),
            ),
            ShellItem(
              DownloadsRuleDialogIds.done,
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
            ),
          ],
          builder: (context, actions) => OverflowBar(alignment: MainAxisAlignment.end, spacing: 8, children: actions),
        ),
      ],
    );
  }
}
