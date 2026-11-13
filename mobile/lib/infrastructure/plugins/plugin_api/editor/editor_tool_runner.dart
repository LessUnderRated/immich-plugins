import 'dart:async';

import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_tool.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_tool_protocol.dart';

/// Sends one `EditorToolV1` call to the plugin behind [tool] and returns its raw response.
typedef EditorToolCaller =
    Future<Map<String, dynamic>?> Function(EditorTool tool, String method, EditorToolRequest request);

/// What every call of one editor session shares.
class EditorToolContext {
  final String session;
  final int generation;

  /// Size of the current working image (sent as `image` in every phase).
  final int width;
  final int height;

  /// AssetV1 of the edited asset, when known.
  final Map<String, dynamic>? asset;

  /// Folder tools should write their results into (same file system as the editor's files; deleted with them).
  final String? outputDir;
  final EditorToolLimits limits;

  const EditorToolContext({
    required this.session,
    required this.generation,
    required this.width,
    required this.height,
    this.asset,
    this.outputDir,
    this.limits = const EditorToolLimits(),
  });
}

/// Runs the phases of `EditorToolV1` against plugin tools.
class EditorToolRunner {
  final EditorToolCaller _call;

  const EditorToolRunner(this._call);

  EditorToolRequest _request(
    EditorTool tool,
    EditorToolContext context,
    EditorToolPhase phase, {
    EditorImageRef? source,
    Map<String, dynamic> state = const {},
    int? previewMaxSize,
    String? taskId,
  }) => EditorToolRequest(
    phase: phase,
    tool: tool.toolId,
    session: context.session,
    generation: context.generation,
    imageWidth: context.width,
    imageHeight: context.height,
    source: source,
    state: state,
    asset: context.asset,
    previewMaxSize: previewMaxSize,
    taskId: taskId,
    outputDir: context.outputDir,
    limits: context.limits,
    params: tool.params,
  );

  Future<EditorToolResponse> _send(EditorTool tool, String? method, EditorToolRequest request) async {
    if (tool.isBuiltin || method == null) {
      throw EditorToolException('Tool ${tool.id} has no method');
    }
    return EditorToolResponse.fromJson(await _call(tool, method, request));
  }

  /// `panel`: the tool's panel and initial input values.
  Future<EditorToolResponse> panel(
    EditorTool tool,
    EditorToolContext context, {
    Map<String, dynamic> state = const {},
  }) => _send(tool, tool.panelMethod, _request(tool, context, EditorToolPhase.panel, state: state));

  /// `preview`: a quick result on a downscaled [source].
  Future<EditorToolResponse> preview(
    EditorTool tool,
    EditorToolContext context,
    EditorImageRef source,
    Map<String, dynamic> state,
  ) => _send(
    tool,
    tool.method,
    _request(
      tool,
      context,
      EditorToolPhase.preview,
      source: source,
      state: state,
      previewMaxSize: tool.options.previewMaxSize,
    ),
  );

  /// `apply`: the full result on [source]. [taskId] identifies the run for progress, cancel and `editor.applyImage`.
  Future<EditorToolResponse> apply(
    EditorTool tool,
    EditorToolContext context,
    EditorImageRef source,
    Map<String, dynamic> state, {
    required String taskId,
  }) => _send(
    tool,
    tool.method,
    _request(tool, context, EditorToolPhase.apply, source: source, state: state, taskId: taskId),
  );

  /// `cancel`: sent while `apply` runs; errors are ignored.
  Future<void> cancel(EditorTool tool, EditorToolContext context, String taskId) async {
    try {
      await _send(tool, tool.method, _request(tool, context, EditorToolPhase.cancel, taskId: taskId));
    } catch (_) {
      // The tool may not implement cancel; the editor drops the result either way.
    }
  }

  /// `dispose`: the tool was deselected or the editor closed; errors are ignored.
  Future<void> dispose(EditorTool tool, EditorToolContext context) async {
    try {
      await _send(tool, tool.method, _request(tool, context, EditorToolPhase.dispose));
    } catch (_) {
      // Nothing to release.
    }
  }
}
