import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:uuid/uuid.dart';

@RoutePage()
class PluginsPage extends ConsumerWidget {
  const PluginsPage({super.key});

  Future<void> _installZip(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        withData: true,
      );
      final bytes = picked?.files.singleOrNull?.bytes;
      if (bytes == null) {
        return;
      }
      final name = await ref.read(deviceWorkflowEngineProvider).installZip(bytes);
      messenger.showSnackBar(SnackBar(content: Text('Installed $name')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Install failed: $error')));
    }
  }

  Future<void> _scanFolder(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final installed = await ref.read(deviceWorkflowEngineProvider).installFromDropFolder();
    messenger.showSnackBar(
      SnackBar(content: Text(installed.isEmpty ? 'No new plugin zips found' : 'Installed ${installed.join(', ')}')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Plugins'),
          actions: [
            IconButton(
              tooltip: 'Install plugin zip',
              icon: const Icon(Icons.add),
              onPressed: () => _installZip(context, ref),
            ),
            IconButton(
              tooltip: 'Scan plugin folder',
              icon: const Icon(Icons.folder_open),
              onPressed: () => _scanFolder(context, ref),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Plugins'),
              Tab(text: 'Workflows'),
              Tab(text: 'Activity'),
            ],
          ),
        ),
        body: const TabBarView(children: [_PluginList(), _WorkflowList(), _ActivityList()]),
      ),
    );
  }
}

class _PluginList extends ConsumerWidget {
  const _PluginList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plugins = ref.watch(devicePluginsProvider);
    return plugins.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('$error')),
      data: (plugins) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final plugin in plugins) _PluginCard(plugin: plugin),
          const _DropFolderHint(),
        ],
      ),
    );
  }
}

class _DropFolderHint extends ConsumerWidget {
  const _DropFolderHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        'Install a plugin with + (a zip containing manifest.json and a .wasm file), or copy zips into '
        'Android/data/<app>/files/plugins and tap the folder button.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _PluginCard extends ConsumerWidget {
  final DevicePlugin plugin;

  const _PluginCard({required this.plugin});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.read(deviceWorkflowEngineProvider);
    return Card(
      child: ExpansionTile(
        title: Text(plugin.title),
        subtitle: Text(
          [
            'v${plugin.version}',
            if (plugin.author.isNotEmpty) plugin.author,
            if (plugin.bundled) 'built in',
          ].join(' · '),
        ),
        leading: Switch(value: plugin.enabled, onChanged: (enabled) => engine.setPluginEnabled(plugin.name, enabled)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (plugin.description.isNotEmpty) Text(plugin.description),
          const SizedBox(height: 8),
          for (final method in plugin.methods)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(method.title),
              subtitle: Text(method.description),
              trailing: method.hostFunctions ? const Icon(Icons.extension, size: 16) : null,
            ),
          if (!plugin.bundled)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: const Text('Uninstall'),
                onPressed: () => engine.uninstall(plugin.name),
              ),
            ),
        ],
      ),
    );
  }
}

class _WorkflowList extends ConsumerWidget {
  const _WorkflowList();

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final plugins = ref.read(devicePluginsProvider).valueOrNull ?? const <DevicePlugin>[];
    final templates = [
      for (final plugin in plugins.where((plugin) => plugin.enabled))
        for (final template in plugin.templates) template,
    ];

    final choice = await showModalBottomSheet<Map<String, dynamic>?>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Blank workflow'),
              onTap: () => Navigator.pop(context, <String, dynamic>{}),
            ),
            for (final template in templates)
              ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: Text(template['title'] as String? ?? template['name'] as String? ?? 'Template'),
                subtitle: Text(template['description'] as String? ?? ''),
                onTap: () => Navigator.pop(context, template),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) {
      return;
    }

    const uuid = Uuid();
    final steps = <DeviceWorkflowStep>[
      for (final step in (choice['steps'] as List? ?? const []).whereType<Map>())
        if ('${step['method']}'.contains('#'))
          DeviceWorkflowStep(
            id: uuid.v4(),
            pluginName: '${step['method']}'.split('#').first,
            methodName: '${step['method']}'.split('#').last,
            config: step['config'] is Map ? Map<String, dynamic>.from(step['config'] as Map) : {},
          ),
    ];
    final workflow = DeviceWorkflow(
      id: uuid.v4(),
      name: choice['title'] as String? ?? 'New workflow',
      trigger: deviceAssetCreateTrigger,
      enabled: true,
      steps: steps,
    );
    unawaited(context.pushRoute(DeviceWorkflowEditorRoute(workflow: workflow)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workflows = ref.watch(deviceWorkflowsProvider);
    final engine = ref.read(deviceWorkflowEngineProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Workflow'),
        onPressed: () => _create(context, ref),
      ),
      body: workflows.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (workflows) => workflows.isEmpty
            ? const Center(child: Text('No workflows yet. They run on new photos.'))
            : ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                children: [
                  for (final workflow in workflows)
                    Card(
                      child: ListTile(
                        title: Text(workflow.name),
                        subtitle: Text('When a new photo appears · ${workflow.steps.length} steps'),
                        leading: Switch(
                          value: workflow.enabled,
                          onChanged: (enabled) => engine.saveWorkflow(workflow.copyWith(enabled: enabled)),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.pushRoute(DeviceWorkflowEditorRoute(workflow: workflow)),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _ActivityList extends ConsumerWidget {
  const _ActivityList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(deviceWorkflowsProvider);
    final runs = ref.read(deviceWorkflowEngineProvider).recentRuns;
    if (runs.isEmpty) {
      return const Center(child: Text('No workflow runs yet'));
    }
    return ListView(
      children: [
        for (final run in runs)
          ListTile(
            dense: true,
            title: Text('${run.workflow} · ${run.asset}'),
            subtitle: Text(run.result),
            trailing: Text(TimeOfDay.fromDateTime(run.at).format(context)),
          ),
      ],
    );
  }
}
