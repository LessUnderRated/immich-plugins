import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_tool_protocol.dart';

/// Editor-specific options of a plugin tool, read from `contributes.tools[].params`.
class EditorToolOptions {
  /// Format of the source handed to `preview` and `apply` (`params.source`: `rgba` (default), `png`, `jpeg`).
  final EditorSourceFormat source;

  /// The tool implements the `preview` phase (`params.preview`).
  final bool preview;

  /// Re-run `preview` after every panel change (`params.livePreview`, debounced).
  final bool livePreview;

  /// Longest side of the preview source (`params.previewMaxSize`).
  final int previewMaxSize;

  /// Run `apply` as a cancellable task with progress (`params.task`, default true).
  final bool task;

  /// Whether the task can be cancelled (`params.cancellable`, default true).
  final bool cancellable;

  /// Label of the apply button and title of the task (`params.applyLabel`, `params.taskTitle`).
  final String? applyLabel;
  final String? taskTitle;

  /// Plugin config passed as the call's `config` (`params.config`).
  final Map<String, dynamic> config;

  const EditorToolOptions({
    this.source = EditorSourceFormat.rgba,
    this.preview = false,
    this.livePreview = false,
    this.previewMaxSize = editorDefaultPreviewSize,
    this.task = true,
    this.cancellable = true,
    this.applyLabel,
    this.taskTitle,
    this.config = const {},
  });

  factory EditorToolOptions.fromParams(Map<String, dynamic> params) {
    final config = params['config'];
    final previewMaxSize = (params['previewMaxSize'] as num?)?.toInt();
    return EditorToolOptions(
      source: EditorSourceFormat.parse(params['source']),
      preview: params['preview'] == true || params['livePreview'] == true,
      livePreview: params['livePreview'] == true,
      previewMaxSize: previewMaxSize == null || previewMaxSize <= 0 ? editorDefaultPreviewSize : previewMaxSize,
      task: params['task'] != false,
      cancellable: params['cancellable'] != false,
      applyLabel: params['applyLabel'] as String?,
      taskTitle: params['taskTitle'] as String?,
      config: config is Map ? Map<String, dynamic>.from(config) : const {},
    );
  }
}

/// One entry of the editor's tool selector: a built-in tool (`crop`, `mosaic`) or a plugin tool.
class EditorTool {
  /// Built-in id, or `plugin:<plugin>/<tool id>` for plugin tools.
  final String id;

  /// Plugin name, null for built-in tools.
  final String? plugin;

  /// The plugin's own tool id (sent as `tool` in `EditorToolV1`); equals [id] for built-ins.
  final String toolId;

  /// Display title; empty for built-ins (the page uses translated labels).
  final String title;
  final String? subtitle;

  /// Icon name (plugin icon registry) or a file inside the plugin.
  final String? icon;

  /// Method called with `EditorToolV1` (all phases), and an optional separate method for the `panel` phase.
  final String? method;
  final String? uiMethod;
  final Map<String, dynamic> params;
  final EditorToolOptions options;
  final int order;

  const EditorTool._({
    required this.id,
    required this.toolId,
    this.plugin,
    this.title = '',
    this.subtitle,
    this.icon,
    this.method,
    this.uiMethod,
    this.params = const {},
    this.options = const EditorToolOptions(),
    this.order = 0,
  });

  const EditorTool.builtin(String id) : this._(id: id, toolId: id);

  factory EditorTool.plugin({
    required String plugin,
    required String toolId,
    required String title,
    String? subtitle,
    String? icon,
    String? method,
    String? uiMethod,
    Map<String, dynamic> params = const {},
    int order = 0,
  }) => EditorTool._(
    id: editorPluginToolId(plugin, toolId),
    plugin: plugin,
    toolId: toolId,
    title: title,
    subtitle: subtitle,
    icon: icon,
    method: method,
    uiMethod: uiMethod,
    params: params,
    options: EditorToolOptions.fromParams(params),
    order: order,
  );

  static const crop = EditorTool.builtin(EditorBuiltinToolIds.crop);
  static const mosaic = EditorTool.builtin(EditorBuiltinToolIds.mosaic);
  static const builtins = [crop, mosaic];

  bool get isBuiltin => plugin == null;

  /// Method for the `panel` phase.
  String? get panelMethod => uiMethod ?? method;

  Map<String, dynamic> toJson() => {
    'id': id,
    'tool': toolId,
    'builtin': isBuiltin,
    if (plugin != null) 'plugin': plugin,
    if (title.isNotEmpty) 'title': title,
    if (icon != null) 'icon': icon,
  };

  @override
  bool operator ==(Object other) => other is EditorTool && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

String editorPluginToolId(String plugin, String toolId) => 'plugin:$plugin/$toolId';

/// Merges built-in and plugin tools into the selector order.
///
/// Built-ins come first in their own order, then plugin tools by `order`. [hide] removes ids, [order] moves the listed
/// ids to the front in that order; ids after a `"..."` entry move to the end (same rules as `contributes.builtins`).
List<EditorTool> arrangeEditorTools(
  List<EditorTool> builtins,
  List<EditorTool> contributed, {
  Set<String> hide = const {},
  List<String> order = const [],
}) {
  final plugins = [...contributed]..sort((a, b) => a.order.compareTo(b.order));
  final sorted = [
    for (final tool in [...builtins, ...plugins])
      if (!hide.contains(tool.id)) tool,
  ];
  if (order.isEmpty) {
    return sorted;
  }

  final split = order.indexOf('...');
  final head = split == -1 ? order : order.sublist(0, split);
  final tail = split == -1 ? const <String>[] : order.sublist(split + 1);
  final byId = {for (final tool in sorted) tool.id: tool};
  final placed = <String>{};
  List<EditorTool> pick(List<String> ids) => [
    for (final id in ids)
      if (byId[id] != null && placed.add(id)) byId[id]!,
  ];
  final first = pick(head);
  final last = pick(tail);
  return [
    ...first,
    for (final tool in sorted)
      if (!placed.contains(tool.id)) tool,
    ...last,
  ];
}
