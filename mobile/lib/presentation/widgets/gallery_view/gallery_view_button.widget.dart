import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';
import 'package:immich_mobile/domain/models/gallery_view.model.dart';
import 'package:immich_mobile/presentation/pages/plugins/schema_form.widget.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:immich_mobile/providers/gallery_view.provider.dart';
import 'package:immich_mobile/routing/router.dart';

class GalleryViewButton extends ConsumerWidget {
  final String scope;
  final Color? color;

  const GalleryViewButton({super.key, required this.scope, this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(galleryViewSelectionsProvider.select((selections) => selections.containsKey(scope)));
    return IconButton(
      tooltip: 'View',
      color: active ? Theme.of(context).colorScheme.primary : color,
      icon: Icon(active ? Icons.tune : Icons.tune_outlined),
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _GalleryViewSheet(scope: scope),
      ),
    );
  }
}

class _GalleryViewSheet extends ConsumerStatefulWidget {
  final String scope;

  const _GalleryViewSheet({required this.scope});

  @override
  ConsumerState<_GalleryViewSheet> createState() => _GalleryViewSheetState();
}

class _GalleryViewSheetState extends ConsumerState<_GalleryViewSheet> {
  late final Future<List<(DevicePlugin, DevicePluginMethod)>> _methods = ref
      .read(deviceWorkflowEngineProvider)
      .galleryViewMethods();
  String? _selectedKey;
  Map<String, dynamic> _config = {};
  bool _initialized = false;

  void _initialize(List<(DevicePlugin, DevicePluginMethod)> methods) {
    if (_initialized) {
      return;
    }
    _initialized = true;
    final current = ref.read(galleryViewSelectionsProvider)[widget.scope];
    if (current != null && methods.any((entry) => _key(entry) == current.key)) {
      _selectedKey = current.key;
      _config = Map<String, dynamic>.from(current.config);
    } else if (methods.isNotEmpty) {
      _selectedKey = _key(methods.first);
    }
  }

  static String _key((DevicePlugin, DevicePluginMethod) entry) => '${entry.$1.name}#${entry.$2.name}';

  Future<void> _apply((DevicePlugin, DevicePluginMethod) entry) async {
    await ref
        .read(galleryViewSelectionsProvider.notifier)
        .set(widget.scope, GalleryViewSelection(pluginName: entry.$1.name, methodName: entry.$2.name, config: _config));
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _reset() async {
    await ref.read(galleryViewSelectionsProvider.notifier).set(widget.scope, null);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, controller) => FutureBuilder<List<(DevicePlugin, DevicePluginMethod)>>(
        future: _methods,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final methods = snapshot.data ?? const [];
          if (methods.isEmpty) {
            return ListView(
              controller: controller,
              padding: const EdgeInsets.all(24),
              children: [
                const Text('No view plugins installed', textAlign: TextAlign.center),
                const SizedBox(height: 8),
                const Text(
                  'Install a plugin with a gallery view (sort and filter) from the Plugins page.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Center(
                  child: FilledButton.tonal(
                    onPressed: () {
                      Navigator.of(context).pop();
                      context.pushRoute(const PluginsRoute());
                    },
                    child: const Text('Open Plugins'),
                  ),
                ),
              ],
            );
          }

          _initialize(methods);
          final selected = methods.where((entry) => _key(entry) == _selectedKey).firstOrNull ?? methods.first;
          final hasSelection = ref.watch(galleryViewSelectionsProvider.select((s) => s.containsKey(widget.scope)));

          return ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Text(
                widget.scope == mainGalleryViewScope ? 'Photos view' : 'Album view',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (methods.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: DropdownButtonFormField<String>(
                    initialValue: _key(selected),
                    decoration: const InputDecoration(labelText: 'View'),
                    items: [
                      for (final entry in methods)
                        DropdownMenuItem(value: _key(entry), child: Text('${entry.$2.title} · ${entry.$1.title}')),
                    ],
                    onChanged: (key) => setState(() {
                      _selectedKey = key;
                      _config = {};
                    }),
                  ),
                ),
              if (selected.$2.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(selected.$2.description, style: Theme.of(context).textTheme.bodySmall),
                ),
              SchemaForm(
                key: ValueKey(_key(selected)),
                schema: selected.$2.schema,
                config: _config,
                onChanged: (config) => setState(() => _config = config),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(onPressed: hasSelection ? _reset : null, child: const Text('Reset')),
                  const Spacer(),
                  FilledButton(onPressed: () => _apply(selected), child: const Text('Apply')),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
