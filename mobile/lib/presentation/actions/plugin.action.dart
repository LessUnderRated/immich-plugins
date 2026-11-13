import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/action_ids.dart';
import 'package:immich_mobile/presentation/pages/plugins/schema_form.widget.dart';
import 'package:immich_mobile/presentation/plugins/plugin_ui.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:immich_mobile/utils/error_handler.dart';

final _stateProvider = Provider.family.autoDispose<List<LocalAsset>?, ActionSource>((ref, source) {
  final local = ref.watch(assetsActionProvider(source)).whereType<LocalAsset>().toList(growable: false);
  return local.isEmpty ? null : local;
}, dependencies: [assetsActionProvider]);

class PluginAction extends AssetActionBuilder {
  const PluginAction({required super.source});

  @override
  String get id => ActionIds.plugins;

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(_stateProvider(source));
    final methods = ref.watch(assetActionMethodsProvider).valueOrNull ?? const [];
    final buttons = ref.watch(pluginSurfacesProvider).slot('selection');
    if (assets == null || (methods.isEmpty && buttons.isEmpty)) {
      return null;
    }
    return .new(
      icon: Icons.extension_outlined,
      label: 'Plugins',
      onAction: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _PluginActionSheet(source: source, assets: assets, methods: methods, buttons: buttons),
      ),
    );
  }
}

class _PluginActionSheet extends ConsumerStatefulWidget {
  final ActionSource source;
  final List<LocalAsset> assets;
  final List<(DevicePlugin, DevicePluginMethod)> methods;
  final List<PluginContribution> buttons;

  const _PluginActionSheet({required this.source, required this.assets, required this.methods, required this.buttons});

  @override
  ConsumerState<_PluginActionSheet> createState() => _PluginActionSheetState();
}

class _PluginActionSheetState extends ConsumerState<_PluginActionSheet> {
  (DevicePlugin, DevicePluginMethod)? _selected;
  Map<String, dynamic> _config = {};
  bool _running = false;

  bool _hasOptions(DevicePluginMethod method) =>
      method.schema['properties'] is Map && (method.schema['properties'] as Map).isNotEmpty;

  Future<void> _run((DevicePlugin, DevicePluginMethod) entry) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    final clearSelection = ref.read(clearSelectionProvider(widget.source));
    setState(() => _running = true);
    try {
      final response = await ref
          .read(deviceWorkflowEngineProvider)
          .runAssetAction(entry.$1.name, entry.$2.name, widget.assets, _config);
      final message = response?['message'];
      clearSelection();
      await ref.read(backgroundSyncProvider).syncLocal();
      navigator.pop();
      messenger?.showSnackBar(SnackBar(content: Text(message is String ? message : '${entry.$2.title} finished')));
    } catch (error, stack) {
      handleError(error, stack: stack, description: '${entry.$2.title} failed');
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final count = widget.assets.length;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(left: 16, right: 16, bottom: 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: _running
            ? const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            : selected == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Run on $count ${count == 1 ? 'item' : 'items'}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  for (final button in widget.buttons)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: PluginIcon(plugin: button.plugin, icon: button.icon),
                      title: Text(button.title),
                      subtitle: Text(button.plugin),
                      onTap: () async {
                        final navigator = Navigator.of(context);
                        final clearSelection = ref.read(clearSelectionProvider(widget.source));
                        await runPluginContribution(ref, button, assets: widget.assets);
                        clearSelection();
                        navigator.pop();
                      },
                    ),
                  for (final entry in widget.methods)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.extension_outlined),
                      title: Text(entry.$2.title),
                      subtitle: Text(entry.$2.description.isEmpty ? entry.$1.title : entry.$2.description),
                      onTap: () => _hasOptions(entry.$2)
                          ? setState(() {
                              _selected = entry;
                              _config = {};
                            })
                          : _run(entry),
                    ),
                ],
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(selected.$2.title, style: Theme.of(context).textTheme.titleMedium),
                    if (selected.$2.description.isNotEmpty)
                      Text(selected.$2.description, style: Theme.of(context).textTheme.bodySmall),
                    SchemaForm(
                      schema: selected.$2.schema,
                      config: _config,
                      onChanged: (config) => setState(() => _config = config),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        TextButton(onPressed: () => setState(() => _selected = null), child: const Text('Back')),
                        const Spacer(),
                        FilledButton(onPressed: () => _run(selected), child: const Text('Run')),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
