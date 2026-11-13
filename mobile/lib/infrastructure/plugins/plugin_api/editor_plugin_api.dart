import 'package:collection/collection.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_tool.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_tool_protocol.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/presentation/actions/edit_asset.action.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_session.provider.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_tools.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// Plugin API of the **editor** area (editor: tool selector, plugin tools (`EditorToolV1`), panels, `editor.save`, built-in tool ids).
///
/// Registers the `editor.*` host functions and emits the editor events (`editor.opened`, `editor.toolChanged`,
/// `editor.imageChanged`, `editor.closed`; `editor.saved` comes from the page). Tools, panels, slots and the
/// `editor.open` / `editor.save` / `editor.tool.apply` hooks are wired where the editor runs.
void registerEditorPluginApi(PluginKernel kernel, Ref ref) {
  EditorSessionNotifier session() => ref.read(editorSessionProvider.notifier);

  void requireOpen() {
    if (!ref.read(editorSessionProvider).isOpen) {
      throw const HostFunctionException(409, 'The editor is not open');
    }
  }

  Map<String, dynamic> options(List<dynamic> args, [int index = 0]) =>
      args.length > index && args[index] is Map ? Map<String, dynamic>.from(args[index] as Map) : <String, dynamic>{};

  /// A tool by id: built-in ids, `plugin:<p>/<id>`, or the calling plugin's own tool id.
  EditorTool? findTool(String plugin, Object? id) {
    final tools = ref.read(editorToolsProvider);
    if (id == null) {
      return ref.read(editorActiveToolEntryProvider);
    }
    return tools.firstWhereOrNull((tool) => tool.id == '$id') ??
        tools.firstWhereOrNull((tool) => tool.plugin == plugin && tool.toolId == '$id');
  }

  void register(String name, HostFunction handler, String doc) =>
      kernel.registerHost(name, handler, doc: doc, area: 'editor');

  register(EditorPluginIds.hostOpen, (plugin, args) async {
    final id = args.isEmpty ? null : args.first;
    if (id is! String || id.isEmpty) {
      throw const HostFunctionException(400, 'editor.open needs an asset id');
    }
    final asset = await kernel.findAsset(id);
    if (asset == null) {
      throw const HostFunctionException(404, 'Asset not found');
    }
    final route = await prepareImageEditor(ref.read, asset);
    if (route == null) {
      return {'opened': false};
    }
    await ref.read(appRouterProvider).push(route);
    return {'opened': true, 'session': ref.read(editorSessionProvider).id};
  }, '[assetId] -> { opened, session }');

  register(EditorPluginIds.hostClose, (plugin, args) async {
    final page = EditorPageHandle.current;
    if (page == null) {
      return false;
    }
    return page.close(discard: options(args)['discard'] == true);
  }, '[{ discard? }] -> bool');

  register(EditorPluginIds.hostState, (plugin, args) async => session().describe(), '[] -> editor state');

  register(EditorPluginIds.hostSetTool, (plugin, args) async {
    requireOpen();
    final tool = findTool(plugin, args.isEmpty ? null : args.first);
    return tool != null && ref.read(editorActiveToolProvider.notifier).select(tool.id);
  }, '[toolId] -> bool');

  register(EditorPluginIds.hostApply, (plugin, args) async {
    requireOpen();
    final opts = options(args);
    final tool = findTool(plugin, opts['tool']);
    if (tool == null || tool.isBuiltin) {
      throw const HostFunctionException(404, 'No such plugin tool');
    }
    final state = {
      ...ref.read(editorToolStateProvider.notifier).of(tool.id),
      if (opts['state'] is Map) ...Map<String, dynamic>.from(opts['state'] as Map),
    };
    final result = await session().applyTool(tool, state);
    return {'outcome': result.outcome.name, if (result.message != null) 'message': result.message};
  }, '[{ tool?, state? }] -> { outcome, message? }');

  register(EditorPluginIds.hostPreview, (plugin, args) async {
    requireOpen();
    final opts = options(args);
    final tool = findTool(plugin, opts['tool']);
    if (tool == null || tool.isBuiltin) {
      throw const HostFunctionException(404, 'No such plugin tool');
    }
    final state = {
      ...ref.read(editorToolStateProvider.notifier).of(tool.id),
      if (opts['state'] is Map) ...Map<String, dynamic>.from(opts['state'] as Map),
    };
    final preview = await session().previewTool(tool, state);
    return preview == null ? null : {'region': preview.region.toJson()};
  }, '[{ tool?, state? }] -> { region } | null');

  register(EditorPluginIds.hostApplyImage, (plugin, args) async {
    requireOpen();
    final EditorImageRef? image;
    try {
      image = EditorImageRef.fromJson(args.isEmpty ? null : args.first);
    } on EditorToolException catch (error) {
      throw HostFunctionException(400, error.message);
    }
    if (image == null) {
      throw const HostFunctionException(400, 'editor.applyImage needs { path, width, height, format }');
    }
    final opts = options(args, 1);
    return session().deliverImage(image, taskId: opts['task'] as String?, toolId: opts['tool'] as String?);
  }, '[image, { task?, tool? }] -> "delivered" | "applied"');

  register(EditorPluginIds.hostUndo, (plugin, args) async {
    requireOpen();
    return session().undoTool();
  }, '[] -> bool');

  register(EditorPluginIds.hostSource, (plugin, args) async {
    requireOpen();
    final opts = options(args);
    final source = await session().exportSource(
      format: EditorSourceFormat.parse(opts['format']),
      maxSize: (opts['maxSize'] as num?)?.toInt(),
    );
    return source.toJson();
  }, '[{ format?, maxSize? }] -> image');

  register(EditorPluginIds.hostSave, (plugin, args) async {
    final page = EditorPageHandle.current;
    if (page == null) {
      throw const HostFunctionException(409, 'The editor is not open');
    }
    return page.save(target: options(args)['target'] as String?);
  }, '[{ target? }] -> { target, assetId, createdId? }');

  // ---- events ---------------------------------------------------------------------------------------------------

  ref.listen<EditorSession>(editorSessionProvider, (previous, next) {
    final before = previous ?? EditorSession.closed;
    if (!before.isOpen && next.isOpen) {
      kernel.emit(EditorPluginIds.openedEvent, {
        'session': next.id,
        if (next.asset != null) 'asset': {'id': next.asset!.id},
        'tool': ref.read(editorActiveToolProvider),
        'tools': [for (final tool in ref.read(editorToolsProvider)) tool.id],
      });
    } else if (before.isOpen && !next.isOpen) {
      kernel.emit(EditorPluginIds.closedEvent, {'session': before.id, 'saved': EditorPluginEvents.saved(before.id)});
    } else if (next.isOpen && before.id == next.id && before.generation != next.generation) {
      final working = next.working;
      final reason = next.history.length > before.history.length
          ? 'apply'
          : next.history.isEmpty && before.history.isNotEmpty
          ? 'reset'
          : next.history.length < before.history.length
          ? 'undo'
          : 'external';
      kernel.emit(EditorPluginIds.imageChangedEvent, {
        'session': next.id,
        'generation': next.generation,
        if (next.history.isNotEmpty) 'tool': next.history.last.toolId,
        if (working != null) 'width': working.width,
        if (working != null) 'height': working.height,
        'reason': reason,
      });
    }
  });

  ref.listen<String>(editorActiveToolProvider, (previous, next) {
    final open = ref.read(editorSessionProvider);
    if (open.isOpen && previous != next) {
      kernel.emit(EditorPluginIds.toolChangedEvent, {'session': open.id, 'tool': next, 'previous': previous});
    }
  });
}

/// Remembers which editor sessions saved, for `editor.closed`.
abstract final class EditorPluginEvents {
  static final _saved = <String>{};

  static void markSaved(String session) => _saved.add(session);

  static bool saved(String session) => _saved.remove(session);
}
