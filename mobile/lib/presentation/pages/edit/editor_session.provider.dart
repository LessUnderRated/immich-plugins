import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:flutter/painting.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_image_pipeline.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_media_writer.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_tool.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_tool_protocol.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_tool_runner.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_workspace.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_edits.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_tools.provider.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:immich_mobile/providers/infrastructure/media_writer.provider.dart';
import 'package:immich_mobile/utils/asset_edit_renderer.utils.dart';

final editorImagePipelineProvider = Provider<EditorImagePipeline>(
  (ref) => EditorImagePipeline(
    censorEffects: (style, options, source, size, width, height) =>
        ref.read(censorStylesProvider).render(style, options, source, size, width, height),
  ),
);

final editorMediaWriterProvider = Provider<EditorMediaWriter>(
  (ref) => SharedEditorMediaWriter(ref.watch(mediaWriterProvider), ref.watch(deviceEditRepositoryProvider)),
);

final editorToolRunnerProvider = Provider<EditorToolRunner>(
  (ref) => EditorToolRunner(
    (tool, method, request) => ref
        .read(deviceWorkflowEngineProvider)
        .callPluginMethod(tool.plugin!, method, request.toInput(config: tool.options.config)),
  ),
);

final editorSessionProvider = NotifierProvider<EditorSessionNotifier, EditorSession>(EditorSessionNotifier.new);

/// What only the open editor page can do (it owns navigation and the save dialogs): plugins reach it through
/// `editor.save` and `editor.close`. The page sets [EditorPageHandle.current] while it is mounted.
abstract class EditorPageHandle {
  static EditorPageHandle? current;

  /// Saves like the ✓ button (asking for copy / replace when a tool changed the image, unless [target] is given).
  Future<Map<String, dynamic>> save({String? target});

  /// Closes the editor; asks about unsaved edits unless [discard].
  Future<bool> close({bool discard = false});
}

/// A tool result that replaced the working image, with the edits that were pending before it (restored on undo).
class EditorGeneration {
  final String toolId;
  final EditorWorkingImage image;
  final EditorState before;
  final Map<String, dynamic> toolState;

  const EditorGeneration({required this.toolId, required this.image, required this.before, this.toolState = const {}});
}

/// A running `apply`.
class EditorToolRun {
  final EditorTool tool;

  /// Task id: sent as `task.id`, used for progress, cancel and `editor.applyImage`.
  final String id;
  final double? progress;
  final String? message;

  const EditorToolRun({required this.tool, required this.id, this.progress, this.message});

  EditorToolRun withProgress(double? progress, String? message) =>
      EditorToolRun(tool: tool, id: id, progress: progress ?? this.progress, message: message ?? this.message);

  Map<String, dynamic> toJson() => {
    'tool': tool.id,
    'task': id,
    if (progress != null) 'progress': progress,
    if (message != null) 'message': message,
  };
}

/// A tool's preview, shown instead of the working image while that tool is selected.
class EditorPreview {
  final String toolId;
  final EditorWorkingImage image;
  final EditorRegion region;
  final int generation;

  const EditorPreview({required this.toolId, required this.image, required this.region, required this.generation});
}

enum EditorApplyOutcome { applied, unchanged, cancelled }

typedef EditorApplyResult = ({EditorApplyOutcome outcome, String? message});

class EditorSession {
  /// Empty while the editor is closed.
  final String id;
  final BaseAsset? asset;

  /// Increases every time the working image changes (tool applied, undo, reset).
  final int generation;
  final List<EditorGeneration> history;
  final EditorToolRun? run;
  final EditorPreview? preview;

  const EditorSession({this.id = '', this.asset, this.generation = 0, this.history = const [], this.run, this.preview});

  static const closed = EditorSession();

  bool get isOpen => id.isNotEmpty;

  /// The last tool result, or null while the editor works on the asset itself.
  EditorWorkingImage? get working => history.lastOrNull?.image;

  /// True once a tool replaced the image: saving then writes a new file instead of non-destructive edits.
  bool get isBaked => history.isNotEmpty;

  EditorSession copyWith({
    int? generation,
    List<EditorGeneration>? history,
    EditorToolRun? run,
    bool clearRun = false,
    EditorPreview? preview,
    bool clearPreview = false,
  }) => EditorSession(
    id: id,
    asset: asset,
    generation: generation ?? this.generation,
    history: history ?? this.history,
    run: clearRun ? null : (run ?? this.run),
    preview: clearPreview ? null : (preview ?? this.preview),
  );
}

typedef _EditorBase = ({Uint8List? bytes, ImageProvider? provider, int? width, int? height});

class EditorSessionNotifier extends Notifier<EditorSession> {
  _EditorBase? _base;
  EditorWorkingImage? _baseImage;
  Future<EditorImageWorkspace>? _workspace;
  Completer<EditorImageRef?>? _cancel;
  final Map<String, Completer<EditorImageRef?>> _pending = {};
  final Map<String, EditorImageRef> _early = {};
  ({Object key, EditorImageRef ref, bool fresh})? _previewSource;
  ({Object key, Future<({EditorWorkingImage image, bool fresh})> render})? _display;
  int _runs = 0;
  int _previews = 0;

  @override
  EditorSession build() {
    listenSelf(_emitEvents);
    return EditorSession.closed;
  }

  /// `editor.opened`, `editor.imageChanged` and `editor.closed` for plugins.
  void _emitEvents(EditorSession? previous, EditorSession next) {
    final kernel = PluginKernel.current;
    if (kernel == null) {
      return;
    }
    final before = previous ?? EditorSession.closed;
    if (!before.isOpen && next.isOpen) {
      kernel.emit(EditorPluginIds.openedEvent, {
        'session': next.id,
        if (next.asset != null) 'asset': {'id': next.asset!.id},
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
  }

  /// Opens a session for [asset]. The editor's base image is the original's [bytes] (device assets, with their
  /// decoded [width] and [height]) or an image [provider] (server assets).
  void start({BaseAsset? asset, Uint8List? bytes, ImageProvider? provider, int? width, int? height}) {
    end();
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    _base = (bytes: bytes, provider: provider, width: width, height: height);
    state = EditorSession(id: id, asset: asset);
    ref.read(editorToolStateProvider.notifier).clear();
    ref.read(editorActiveToolProvider.notifier).reset();
    unawaited(EditorImageWorkspace.purge(keep: id));
  }

  /// Ends session [id] if it is still the current one (the editor page closing).
  void endSession(String id) {
    if (state.id == id) {
      end();
    }
  }

  /// Ends the session and deletes its files. Safe to call while widgets are disposed: listeners are notified later.
  void end() {
    final id = state.id;
    final run = state.run;
    if (run != null) {
      final context = EditorToolContext(session: id, generation: state.generation, width: 0, height: 0);
      unawaited(ref.read(editorToolRunnerProvider).cancel(run.tool, context, run.id));
    }
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) {
      cancel.complete(null);
    }
    _cancel = null;
    for (final pending in _pending.values) {
      pending.complete(null);
    }
    _pending.clear();
    _early.clear();
    _base = null;
    _baseImage = null;
    _previewSource = null;
    _display = null;
    final workspace = _workspace;
    _workspace = null;
    if (workspace != null) {
      unawaited(workspace.then((workspace) => workspace.dispose(), onError: (_) {}));
    }
    if (id.isNotEmpty) {
      unawaited(
        Future.microtask(() {
          if (state.id == id) {
            state = EditorSession.closed;
          }
        }),
      );
    }
  }

  Future<EditorImageWorkspace> workspace() {
    if (!state.isOpen) {
      return Future.error(StateError('The editor is not open'));
    }
    return _workspace ??= EditorImageWorkspace.open(state.id);
  }

  /// The image the editor works on as a file: the last tool result, or the asset itself.
  Future<EditorWorkingImage> currentImage() async {
    final working = state.working;
    if (working != null) {
      return working;
    }
    final cached = _baseImage;
    if (cached != null) {
      return cached;
    }
    final base = _base;
    if (base == null) {
      throw StateError('The editor is not open');
    }
    final workspace = await this.workspace();
    final EditorWorkingImage image;
    final bytes = base.bytes;
    if (bytes != null && sniffImageMime(bytes.sublist(0, bytes.length < 16 ? bytes.length : 16)) == null) {
      // HEIC, AVIF, ...: only the platform decoder reads them; keep a PNG copy.
      final decoded = await decodeEditableImage(bytes);
      try {
        image = await workspace.writeImage(decoded, generation: 0, name: 'original');
      } finally {
        decoded.dispose();
      }
    } else if (bytes != null) {
      image = await workspace.writeEncoded(
        bytes,
        generation: 0,
        width: base.width,
        height: base.height,
        normalized: false,
        name: 'original',
      );
    } else {
      final decoded = await _resolve(base.provider!);
      try {
        image = await workspace.writeImage(decoded, generation: 0, name: 'original');
      } finally {
        decoded.dispose();
      }
    }
    if (identical(_base, base)) {
      _baseImage = image;
    }
    return image;
  }

  /// What the user currently sees as one file: the working image with every pending edit baked in. Returns the
  /// working image itself when nothing is pending and it is already in [format].
  Future<EditorWorkingImage> renderCurrent({RenderFormat? format}) async {
    final image = await currentImage();
    final edits = editorStateToEdits(ref.read(editorStateProvider), width: image.width, height: image.height);
    return ref.read(editorImagePipelineProvider).bake(image, edits, await workspace(), format: format);
  }

  /// [renderCurrent] for display while a plugin tool is selected (the tool's view shows exactly what it will get).
  /// Cached until the image or the pending edits change.
  Future<EditorWorkingImage> renderDisplay() {
    final key = (state.generation, ref.read(editorStateProvider));
    final cached = _display;
    if (cached != null && cached.key == key) {
      return cached.render.then((render) => render.image);
    }
    if (cached != null) {
      unawaited(_discardDisplay(cached.render));
    }
    final render = _renderFlagged();
    _display = (key: key, render: render);
    return render.then((render) => render.image);
  }

  /// [renderCurrent], telling whether the result is a new file (not the working image itself).
  Future<({EditorWorkingImage image, bool fresh})> _renderFlagged() async {
    final current = await currentImage();
    final image = await renderCurrent();
    return (image: image, fresh: image.file.path != current.file.path);
  }

  Future<void> _discardDisplay(Future<({EditorWorkingImage image, bool fresh})> display) async {
    try {
      final render = await display;
      if (render.fresh) {
        await _deleteInWorkspace(render.image);
      }
    } catch (_) {
      // Nothing to clean up.
    }
  }

  /// Deletes [rendered] unless it is [current] (the working image itself).
  Future<void> _discardRendered(EditorWorkingImage rendered, EditorWorkingImage current) async {
    if (rendered.file.path != current.file.path) {
      await _deleteInWorkspace(rendered);
    }
  }

  /// Deletes a workspace file; a no-op once the session ended (its folder is deleted anyway).
  Future<void> _deleteInWorkspace(EditorWorkingImage image) async {
    final workspace = _workspace;
    if (workspace != null) {
      await (await workspace).deleteImage(image);
    }
  }

  Future<Map<String, dynamic>?> _assetJson() async {
    final asset = state.asset;
    return switch (asset) {
      null => null,
      LocalAsset() => ref.read(deviceWorkflowEngineProvider).assetJson(asset),
      RemoteAsset() => {
        'id': asset.id,
        'remoteId': asset.id,
        'localId': asset.localId,
        'name': asset.name,
        'type': asset.type.name,
        'width': asset.width,
        'height': asset.height,
        'isFavorite': asset.isFavorite,
      },
    };
  }

  Future<EditorToolContext> toolContext({EditorWorkingImage? image}) async {
    final editor = ref.read(editorStateProvider);
    return EditorToolContext(
      session: state.id,
      generation: state.generation,
      width: image?.width ?? editor.originalWidth,
      height: image?.height ?? editor.originalHeight,
      asset: await _assetJson(),
      outputDir: (await workspace()).directory.path,
    );
  }

  /// The `panel` of [tool]: its JSON UI (or native view) and initial input values, for the image the user sees.
  Future<EditorToolResponse> toolPanel(EditorTool tool, Map<String, dynamic> toolState) async =>
      ref.read(editorToolRunnerProvider).panel(tool, await toolContext(image: state.working), state: toolState);

  /// Runs `apply` of [tool] on what the user sees and makes the result the working image. Pending edits are baked
  /// into the source and restored by [undoTool].
  Future<EditorApplyResult> applyTool(EditorTool tool, Map<String, dynamic> toolState) async {
    if (state.run != null) {
      throw StateError('Another tool is running');
    }
    final workspace = await this.workspace();
    await clearPreview();
    final session = state.id;
    final before = ref.read(editorStateProvider);
    // A kernel task when the tool asks for one: app-native progress, the plugin reports with `tasks.update`.
    final kernel = PluginKernel.current;
    final task = tool.options.task && kernel != null
        ? kernel.tasks.start(
            tool.plugin ?? 'app',
            tool.options.taskTitle ?? tool.title,
            cancellable: tool.options.cancellable,
            onCancel: cancelRun,
          )
        : null;
    final runId = task?.id ?? 'editor-$session-${_runs++}';
    final cancel = _cancel = Completer<EditorImageRef?>();
    state = state.copyWith(
      run: EditorToolRun(tool: tool, id: runId),
    );
    void onTaskChanged() {
      final current = kernel?.tasks[runId];
      if (current != null && current.isRunning) {
        updateRun(runId, progress: current.progress, message: current.message);
      }
    }

    kernel?.tasks.addListener(onTaskChanged);
    String? taskError;

    EditorWorkingImage? current;
    EditorWorkingImage? rendered;
    EditorImageRef? source;
    try {
      current = await currentImage();
      rendered = await renderCurrent(
        format: tool.options.source == EditorSourceFormat.jpeg ? RenderFormat.jpeg : RenderFormat.png,
      );
      source = await workspace.writeToolSource(rendered, tool.options.source);
      if (cancel.isCompleted) {
        return (outcome: EditorApplyOutcome.cancelled, message: null);
      }

      final context = await toolContext(image: rendered);
      String? message;
      final call = runApply(tool, context, source, toolState, runId).then((response) {
        message = response.message;
        return _resultOf(response, runId);
      });
      final result = await Future.any([call, cancel.future]);
      if (cancel.isCompleted || state.id != session || state.run?.id != runId) {
        unawaited(call.then((late) => _deleteForeign(late?.path), onError: (_) {}));
        return (outcome: EditorApplyOutcome.cancelled, message: null);
      }
      if (result == null) {
        return (outcome: EditorApplyOutcome.unchanged, message: message);
      }

      final adopted = await workspace.adopt(result, generation: state.generation + 1, limits: context.limits);
      _push(tool.id, adopted, before, toolState);
      return (outcome: EditorApplyOutcome.applied, message: message);
    } catch (error) {
      taskError = error.toString();
      rethrow;
    } finally {
      kernel?.tasks.removeListener(onTaskChanged);
      if (task != null) {
        if (cancel.isCompleted) {
          kernel?.tasks.cancel(runId);
        } else {
          kernel?.tasks.finish(runId, error: taskError);
        }
      }
      _pending.remove(runId);
      _early.remove(runId);
      if (identical(_cancel, cancel)) {
        _cancel = null;
      }
      if (source != null && rendered != null && !EditorImageWorkspace.isWorkingFile(source, rendered)) {
        await workspace.deletePath(source.path);
      }
      if (rendered != null && current != null) {
        await _discardRendered(rendered, current);
      }
      if (state.run?.id == runId) {
        state = state.copyWith(clearRun: true);
      }
    }
  }

  /// The plugin call of `apply`, wrapped by the `editor.tool.apply` hook: `before` may change `state`, `instead`
  /// produces the image itself, `after` may replace the result.
  Future<EditorToolResponse> runApply(
    EditorTool tool,
    EditorToolContext context,
    EditorImageRef source,
    Map<String, dynamic> toolState,
    String runId,
  ) {
    Future<EditorToolResponse> call(Map<String, dynamic> values) =>
        ref.read(editorToolRunnerProvider).apply(tool, context, source, values, taskId: runId);
    return PluginHooks.run<EditorToolResponse>(
      EditorPluginIds.toolApplyHook,
      () => {
        'session': context.session,
        'tool': tool.id,
        'state': toolState,
        'source': source.toJson(),
        if (context.asset != null) 'asset': context.asset,
      },
      () => call(toolState),
      withArgs: (args) => call(args['state'] is Map ? Map<String, dynamic>.from(args['state'] as Map) : toolState),
      encode: (response) => {
        if (response.image != null) 'image': response.image!.toJson(),
        if (response.unchanged) 'unchanged': true,
        if (response.pending) 'pending': true,
        if (response.message != null) 'message': response.message,
      },
      decode: (json) => EditorToolResponse.fromJson(json is Map ? Map<String, dynamic>.from(json) : null),
    );
  }

  Future<EditorImageRef?> _resultOf(EditorToolResponse response, String runId) {
    if (response.pending) {
      final early = _early.remove(runId);
      if (early != null) {
        return Future.value(early);
      }
      return (_pending[runId] = Completer<EditorImageRef?>()).future;
    }
    if (response.unchanged) {
      return Future.value(null);
    }
    final image = response.image;
    if (image == null) {
      return Future.error(const EditorToolException('The tool returned no image'));
    }
    return Future.value(image);
  }

  Future<void> _deleteForeign(String? path) async {
    if (path == null) {
      return;
    }
    final file = File(path);
    if (file.existsSync()) {
      await file.delete().catchError((_) => file);
    }
  }

  /// Cancels the running `apply`: the editor stops waiting at once, tells the tool (`cancel` phase) and drops the
  /// result if it still arrives.
  void cancelRun() {
    final run = state.run;
    if (run == null) {
      return;
    }
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) {
      cancel.complete(null);
    }
    _pending.remove(run.id)?.complete(null);
    state = state.copyWith(clearRun: true);
    unawaited(
      toolContext(
        image: state.working,
      ).then((context) => ref.read(editorToolRunnerProvider).cancel(run.tool, context, run.id), onError: (_) {}),
    );
  }

  /// Progress of the running `apply` (from the task the tool reports to).
  void updateRun(String taskId, {double? progress, String? message}) {
    final run = state.run;
    if (run != null && run.id == taskId) {
      state = state.copyWith(run: run.withProgress(progress, message));
    }
  }

  /// `editor.applyImage`: completes the pending `apply` with [taskId], or (without a matching run) replaces the
  /// working image with [image] directly. Returns `delivered` or `applied`.
  Future<String> deliverImage(EditorImageRef image, {String? taskId, String? toolId}) async {
    if (!state.isOpen) {
      throw StateError('The editor is not open');
    }
    final run = state.run;
    if (taskId != null && run != null && run.id == taskId) {
      final pending = _pending.remove(taskId);
      if (pending != null) {
        pending.complete(image);
      } else {
        _early[taskId] = image;
      }
      return 'delivered';
    }
    if (run != null) {
      throw StateError('A tool is running');
    }
    final before = ref.read(editorStateProvider);
    final adopted = await (await workspace()).adopt(image, generation: state.generation + 1);
    await clearPreview();
    _push(toolId ?? 'external', adopted, before, const {});
    return 'applied';
  }

  void _push(String toolId, EditorWorkingImage image, EditorState before, Map<String, dynamic> toolState) {
    final generation = state.generation + 1;
    state = state.copyWith(
      generation: generation,
      history: [
        ...state.history,
        EditorGeneration(toolId: toolId, image: image.withGeneration(generation), before: before, toolState: toolState),
      ],
    );
    ref.read(editorStateProvider.notifier).rebase(image.width, image.height);
  }

  /// Runs `preview` of [tool] on a downscaled copy of what the user sees. Stale answers (the image changed or a newer
  /// preview was requested) are dropped.
  Future<EditorPreview?> previewTool(EditorTool tool, Map<String, dynamic> toolState) async {
    if (!tool.options.preview || state.run != null) {
      return null;
    }
    final session = state.id;
    final generation = state.generation;
    final sequence = ++_previews;
    final workspace = await this.workspace();
    final source = await _previewSourceFor(tool, workspace);
    final response = await ref
        .read(editorToolRunnerProvider)
        .preview(tool, await toolContext(image: state.working), source, toolState);

    final stale = state.id != session || state.generation != generation || sequence != _previews || state.run != null;
    final result = response.image;
    if (stale || response.unchanged || result == null) {
      await _deleteForeign(result?.path == source.path ? null : result?.path);
      if (!stale) {
        await clearPreview();
      }
      return null;
    }

    final image = await workspace.adopt(result, generation: generation);
    final preview = EditorPreview(
      toolId: tool.id,
      image: image,
      region: response.region ?? EditorRegion.full,
      generation: generation,
    );
    final previous = state.preview;
    state = state.copyWith(preview: preview);
    await workspace.deleteImage(previous?.image);
    return preview;
  }

  Future<EditorImageRef> _previewSourceFor(EditorTool tool, EditorImageWorkspace workspace) async {
    final key = (state.generation, ref.read(editorStateProvider), tool.options.source, tool.options.previewMaxSize);
    final cached = _previewSource;
    if (cached != null && cached.key == key && File(cached.ref.path).existsSync()) {
      return cached.ref;
    }
    if (cached != null && cached.fresh) {
      await workspace.deletePath(cached.ref.path);
    }
    final current = await currentImage();
    final rendered = await renderCurrent(format: RenderFormat.png);
    final source = await workspace.writeToolSource(
      rendered,
      tool.options.source,
      maxDimension: tool.options.previewMaxSize,
    );
    if (source.path != rendered.file.path) {
      await _discardRendered(rendered, current);
    }
    _previewSource = (key: key, ref: source, fresh: source.path != current.file.path);
    return source;
  }

  /// `editor.source`: what the user sees as a file in [format], downscaled to [maxSize]. Read-only for the caller; the
  /// file is deleted when the editor closes.
  Future<EditorImageRef> exportSource({EditorSourceFormat format = EditorSourceFormat.png, int? maxSize}) async {
    final workspace = await this.workspace();
    final current = await currentImage();
    final rendered = await renderCurrent(
      format: format == EditorSourceFormat.jpeg ? RenderFormat.jpeg : RenderFormat.png,
    );
    final source = await workspace.writeToolSource(rendered, format, maxDimension: maxSize);
    if (source.path != rendered.file.path) {
      await _discardRendered(rendered, current);
    }
    return source;
  }

  Future<void> clearPreview() async {
    final preview = state.preview;
    if (preview == null) {
      return;
    }
    state = state.copyWith(clearPreview: true);
    await _deleteInWorkspace(preview.image);
  }

  /// Reverts the last tool result and restores the edits that were pending before it.
  Future<bool> undoTool() async {
    final last = state.history.lastOrNull;
    if (last == null || state.run != null) {
      return false;
    }
    await clearPreview();
    state = state.copyWith(
      generation: state.generation + 1,
      history: state.history.sublist(0, state.history.length - 1),
    );
    ref.read(editorStateProvider.notifier).restore(last.before);
    await _deleteInWorkspace(last.image);
    return true;
  }

  /// Reverts every tool result (back to the asset itself, with the edits pending before the first tool).
  Future<bool> resetTools() async {
    final first = state.history.firstOrNull;
    if (first == null || state.run != null) {
      return false;
    }
    await clearPreview();
    final dropped = state.history;
    state = state.copyWith(generation: state.generation + 1, history: const []);
    ref.read(editorStateProvider.notifier).restore(first.before);
    for (final generation in dropped) {
      await _deleteInWorkspace(generation.image);
    }
    return true;
  }

  /// Whether the baked result can be saved as [target].
  bool canSave(EditorSaveTarget target) {
    final working = state.working;
    return working != null && ref.read(editorMediaWriterProvider).formatFor(state.asset, target, working) != null;
  }

  /// Bakes the pending edits into the working image and writes it as [target].
  Future<EditorSaveResult> saveBaked(EditorSaveTarget target) async {
    final writer = ref.read(editorMediaWriterProvider);
    final current = await currentImage();
    final format = writer.formatFor(state.asset, target, current);
    if (format == null) {
      throw StateError('This image cannot be saved as ${target.name}');
    }
    final rendered = await renderCurrent(format: format);
    try {
      return await writer.save(state.asset, target, rendered);
    } finally {
      await _discardRendered(rendered, current);
    }
  }

  /// JSON snapshot for `editor.state` and events.
  Map<String, dynamic> describe() {
    if (!state.isOpen) {
      return {'open': false};
    }
    final editor = ref.read(editorStateProvider);
    final working = state.working;
    return {
      'open': true,
      'session': state.id,
      if (state.asset != null) 'assetId': state.asset!.id,
      'tool': ref.read(editorActiveToolProvider),
      'tools': [for (final tool in ref.read(editorToolsProvider)) tool.toJson()],
      'generation': state.generation,
      'image': working?.toJson() ?? {'width': editor.originalWidth, 'height': editor.originalHeight},
      'edits': editorStateToJson(editor),
      'baked': state.isBaked,
      'history': [for (final generation in state.history) generation.toolId],
      if (state.run != null) 'run': state.run!.toJson(),
      if (state.preview != null) 'preview': {'tool': state.preview!.toolId, ...state.preview!.region.toJson()},
    };
  }
}

Future<ui.Image> _resolve(ImageProvider provider) {
  final completer = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      stream.removeListener(listener);
      if (completer.isCompleted) {
        info.image.dispose();
      } else {
        completer.complete(info.image);
      }
    },
    onError: (error, stack) {
      stream.removeListener(listener);
      if (!completer.isCompleted) {
        completer.completeError(error, stack);
      }
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// Remembers which editor sessions saved, for `editor.closed`.
abstract final class EditorPluginEvents {
  static final _saved = <String>{};

  static void markSaved(String session) => _saved.add(session);

  static bool saved(String session) => _saved.remove(session);
}
