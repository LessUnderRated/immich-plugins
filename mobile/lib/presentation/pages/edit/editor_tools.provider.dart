import 'package:collection/collection.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_tool.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_session.provider.dart';
import 'package:immich_mobile/providers/plugin_kernel.provider.dart';
import 'package:immich_mobile/utils/mosaic.utils.dart';

/// Plugin tools of the `editor.image` surface (`contributes.tools`), filtered by `when` against the edited asset.
final editorPluginToolsProvider = Provider<List<EditorTool>>((ref) {
  final kernel = ref.watch(pluginKernelProvider);
  final asset = ref.watch(editorSessionProvider.select((session) => session.asset));
  final context = asset == null ? const {'isImage': true, 'assetType': 'IMAGE'} : PluginKernel.assetContext([asset]);
  return [
    for (final tool in kernel.tools(EditorPluginIds.toolSurface, context: context))
      EditorTool.plugin(
        plugin: tool.plugin,
        toolId: tool.id,
        title: tool.title,
        subtitle: tool.subtitle,
        icon: tool.icon,
        method: tool.method,
        uiMethod: tool.uiMethod,
        params: tool.params,
        order: tool.order,
      ),
  ];
});

/// Hide / order rules for the tool selector (`contributes.builtins["editImage.tools"]`).
final editorToolRulesProvider = Provider<({Set<String> hide, List<String> order})>((ref) {
  final rules = ref.watch(pluginKernelProvider).builtins(EditorPluginIds.toolsSlot);
  return (hide: rules.hide, order: rules.order);
});

/// Every tool of the selector in display order: built-ins (`crop`, `mosaic`) first, then plugin tools.
final editorToolsProvider = Provider<List<EditorTool>>((ref) {
  final rules = ref.watch(editorToolRulesProvider);
  final tools = arrangeEditorTools(
    EditorTool.builtins,
    ref.watch(editorPluginToolsProvider),
    hide: rules.hide,
    order: rules.order,
  );
  return tools.isEmpty ? EditorTool.builtins : tools;
});

/// Id of the selected tool.
final editorActiveToolProvider = NotifierProvider<EditorActiveToolNotifier, String>(EditorActiveToolNotifier.new);

/// The selected tool.
final editorActiveToolEntryProvider = Provider<EditorTool>((ref) {
  final id = ref.watch(editorActiveToolProvider);
  final tools = ref.watch(editorToolsProvider);
  return tools.firstWhereOrNull((tool) => tool.id == id) ?? tools.first;
});

class EditorActiveToolNotifier extends Notifier<String> {
  @override
  String build() => ref.read(editorToolsProvider).first.id;

  EditorTool? find(String id) => ref.read(editorToolsProvider).firstWhereOrNull((tool) => tool.id == id);

  /// Selects the tool with [id] (a built-in id or `plugin:<plugin>/<tool>`). Returns false when there is none.
  bool select(String id) {
    final tool = find(id);
    if (tool == null) {
      return false;
    }
    final mode = switch (tool.id) {
      EditorBuiltinToolIds.crop => EditorMode.transform,
      EditorBuiltinToolIds.mosaic => EditorMode.mosaic,
      _ => null,
    };
    if (mode != null) {
      ref.read(editorStateProvider.notifier).setMode(mode);
    }
    state = tool.id;
    return true;
  }

  /// Selects the first tool (when the editor opens).
  void reset() => select(ref.read(editorToolsProvider).first.id);
}

/// Panel input values of each plugin tool (by tool id), sent as `state` with `preview` and `apply`. Kept while the
/// editor is open so switching tools does not lose them.
final editorToolStateProvider = NotifierProvider<EditorToolStateNotifier, Map<String, Map<String, dynamic>>>(
  EditorToolStateNotifier.new,
);

class EditorToolStateNotifier extends Notifier<Map<String, Map<String, dynamic>>> {
  @override
  Map<String, Map<String, dynamic>> build() => const {};

  Map<String, dynamic> of(String toolId) => state[toolId] ?? const {};

  void set(String toolId, Map<String, dynamic> values) => state = {...state, toolId: Map.unmodifiable(values)};

  void merge(String toolId, Map<String, dynamic> values) => set(toolId, {...of(toolId), ...values});

  void clear() => state = const {};
}
