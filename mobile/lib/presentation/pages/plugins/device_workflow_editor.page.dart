import 'package:auto_route/auto_route.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';
import 'package:immich_mobile/presentation/pages/plugins/schema_form.widget.dart';
import 'package:immich_mobile/providers/app_album.provider.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:uuid/uuid.dart';

@RoutePage()
class DeviceWorkflowEditorPage extends ConsumerStatefulWidget {
  final DeviceWorkflow workflow;

  const DeviceWorkflowEditorPage({super.key, required this.workflow});

  @override
  ConsumerState<DeviceWorkflowEditorPage> createState() => _DeviceWorkflowEditorPageState();
}

class _DeviceWorkflowEditorPageState extends ConsumerState<DeviceWorkflowEditorPage> {
  late final AlbumOptionsLoader _appAlbums = () async => [
    for (final album in await ref.read(appAlbumRepositoryProvider).list()) (id: album.id, name: album.name),
  ];
  late DeviceWorkflow _workflow = widget.workflow;
  bool _testing = false;

  Future<void> _save() async {
    await ref.read(deviceWorkflowEngineProvider).saveWorkflow(_workflow);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _delete() async {
    await ref.read(deviceWorkflowEngineProvider).deleteWorkflow(_workflow.id);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _testOnNewestPhoto() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _testing = true);
    try {
      final db = ref.read(driftProvider);
      final row =
          await (db.localAssetEntity.select()
                ..orderBy([(row) => OrderingTerm.desc(row.createdAt)])
                ..limit(1))
              .getSingleOrNull();
      if (row == null) {
        messenger.showSnackBar(const SnackBar(content: Text('No photos on this device')));
        return;
      }
      final result = await ref.read(deviceWorkflowEngineProvider).runOnAsset(_workflow, row.toDto());
      messenger.showSnackBar(SnackBar(content: Text('${row.name}: $result')));
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  Future<void> _addStep(List<DevicePlugin> plugins) async {
    final picked = await showModalBottomSheet<(DevicePlugin, DevicePluginMethod)?>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, controller) => ListView(
          controller: controller,
          children: [
            for (final plugin in plugins.where((plugin) => plugin.enabled)) ...[
              ListTile(title: Text(plugin.title, style: Theme.of(context).textTheme.titleMedium)),
              for (final method in plugin.methods.where((method) => method.types.contains(deviceAssetType)))
                ListTile(
                  leading: Icon(method.isFilter ? Icons.filter_alt_outlined : Icons.bolt),
                  title: Text(method.title),
                  subtitle: Text(method.description),
                  onTap: () => Navigator.pop(context, (plugin, method)),
                ),
            ],
          ],
        ),
      ),
    );
    if (picked == null) {
      return;
    }
    final (plugin, method) = picked;
    setState(() {
      _workflow = _workflow.copyWith(
        steps: [
          ..._workflow.steps,
          DeviceWorkflowStep(id: const Uuid().v4(), pluginName: plugin.name, methodName: method.name, config: {}),
        ],
      );
    });
  }

  void _updateStep(int index, DeviceWorkflowStep? step) {
    final steps = [..._workflow.steps];
    step == null ? steps.removeAt(index) : steps[index] = step;
    setState(() => _workflow = _workflow.copyWith(steps: steps));
  }

  void _move(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _workflow.steps.length) {
      return;
    }
    final steps = [..._workflow.steps];
    final step = steps.removeAt(index);
    steps.insert(target, step);
    setState(() => _workflow = _workflow.copyWith(steps: steps));
  }

  @override
  Widget build(BuildContext context) {
    final plugins = ref.watch(devicePluginsProvider).valueOrNull ?? const <DevicePlugin>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Workflow'),
        actions: [
          IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _delete),
          IconButton(tooltip: 'Save', icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Step'),
        onPressed: () => _addStep(plugins),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        children: [
          TextFormField(
            initialValue: _workflow.name,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (name) => _workflow = _workflow.copyWith(name: name),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            subtitle: const Text('Runs automatically when a new photo appears on the device'),
            value: _workflow.enabled,
            onChanged: (enabled) => setState(() => _workflow = _workflow.copyWith(enabled: enabled)),
          ),
          OutlinedButton.icon(
            icon: _testing
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow),
            label: const Text('Run on newest photo'),
            onPressed: _testing ? null : _testOnNewestPhoto,
          ),
          const SizedBox(height: 12),
          for (final (index, step) in _workflow.steps.indexed)
            _StepCard(
              key: ValueKey(step.id),
              step: step,
              plugin: plugins.where((plugin) => plugin.name == step.pluginName).firstOrNull,
              onChanged: (next) => _updateStep(index, next),
              onMoveUp: () => _move(index, -1),
              onMoveDown: () => _move(index, 1),
              albumOptions: _appAlbums,
            ),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final DeviceWorkflowStep step;
  final DevicePlugin? plugin;
  final ValueChanged<DeviceWorkflowStep?> onChanged;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final AlbumOptionsLoader albumOptions;

  const _StepCard({
    super.key,
    required this.step,
    required this.plugin,
    required this.onChanged,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.albumOptions,
  });

  @override
  Widget build(BuildContext context) {
    final method = plugin?.method(step.methodName);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    method?.title ?? '${step.pluginName}#${step.methodName} (missing)',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Switch(
                  value: step.enabled,
                  onChanged: (enabled) => onChanged(step.copyWith(enabled: enabled)),
                ),
                IconButton(icon: const Icon(Icons.arrow_upward), onPressed: onMoveUp),
                IconButton(icon: const Icon(Icons.arrow_downward), onPressed: onMoveDown),
                IconButton(icon: const Icon(Icons.close), onPressed: () => onChanged(null)),
              ],
            ),
            if (method != null && method.description.isNotEmpty)
              Text(method.description, style: Theme.of(context).textTheme.bodySmall),
            if (method != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SchemaForm(
                  schema: method.schema,
                  config: step.config,
                  onChanged: (config) => onChanged(step.copyWith(config: config)),
                  albumOptions: albumOptions,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
