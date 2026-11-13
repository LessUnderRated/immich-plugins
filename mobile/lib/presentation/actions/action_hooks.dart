import 'dart:async';

import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline_plugin.model.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart';
import 'package:immich_ui/immich_ui.dart';

/// One run of a UI action, as its `action.<id>` hook sees it.
class ActionHookCall {
  final String actionId;

  /// Where the action runs: the timeline selection or the viewer. Null for actions without assets.
  final ActionSource? source;

  /// The assets the action runs on (the selection, or the viewer's asset).
  final List<BaseAsset> assets;

  /// Action-specific arguments (`albumId`, `tagId`, ...).
  final Map<String, dynamic> args;

  const ActionHookCall({required this.actionId, this.source, this.assets = const [], this.args = const {}});

  /// `{ "actionId", "source"?, "assetIds", "assets": [asset], ...args }` with timeline asset JSON.
  Map<String, dynamic> toJson() => {
    'actionId': actionId,
    if (source != null) 'source': source!.name,
    'assetIds': [for (final asset in assets) asset.id],
    'assets': TimelineAssetJson.encodeAll(assets),
    ...args,
  };
}

/// Runs an action through its hook with richer arguments than [ActionHookCall.toJson] (full AssetV1, which is only
/// available asynchronously). Optional: without a binding, actions run through [PluginHooks].
abstract interface class ActionHookBinding {
  bool hasHook(String hookId);

  /// Runs [original] wrapped by the plugins hooking [hookId]; throws the kernel's cancellation error when a `before`
  /// handler cancels.
  Future<void> run(String hookId, ActionHookCall call, Future<void> Function() original);
}

/// The `action.<id>` hook of every UI action, and the `action.performed` event.
///
/// Free when no plugin uses them: [run] calls the action itself, synchronously.
abstract final class ActionHooks {
  static ActionHookBinding? _binding;

  static void bind(ActionHookBinding? binding) => _binding = binding;

  /// Whether a plugin hooks action [actionId].
  static bool has(String actionId) {
    final hookId = TimelineHooks.action(actionId);
    return _binding?.hasHook(hookId) ?? PluginHooks.has(hookId);
  }

  /// [original] running through `action.<actionId>`; [call] describes the run and is only built when a plugin
  /// hooks the action or listens to `action.performed`.
  static FutureOr<void> Function() wrap(
    String actionId,
    FutureOr<void> Function() original,
    ActionHookCall Function() call,
  ) =>
      () => run(actionId, original, call);

  static FutureOr<void> run(String actionId, FutureOr<void> Function() original, ActionHookCall Function() call) {
    final hooked = has(actionId);
    final listened = PluginHooks.listens(TimelineEvents.actionPerformed);
    if (!hooked && !listened) {
      return original();
    }
    return _runHooked(actionId, original, call(), hooked: hooked, listened: listened);
  }

  static Future<void> _runHooked(
    String actionId,
    FutureOr<void> Function() original,
    ActionHookCall call, {
    required bool hooked,
    required bool listened,
  }) async {
    final hookId = TimelineHooks.action(actionId);
    final binding = _binding;
    Map<String, dynamic> performed(Map<String, dynamic> args) => {
      'id': actionId,
      if (args['source'] != null) 'source': args['source'],
      'assetIds': args['assetIds'] ?? const <String>[],
    };

    try {
      if (hooked && binding != null) {
        await binding.run(hookId, call, () async => original());
        if (listened) {
          PluginHooks.emit(TimelineEvents.actionPerformed, () => performed(call.toJson()));
        }
        return;
      }
      if (!hooked) {
        await original();
        PluginHooks.emit(TimelineEvents.actionPerformed, () => performed(call.toJson()));
        return;
      }
      await PluginHooks.run<void>(
        hookId,
        call.toJson,
        () async => original(),
        event: listened ? TimelineEvents.actionPerformed : null,
        eventData: (args, _) => performed(args),
      );
    } catch (error) {
      if (!PluginHooks.isCancelled(error)) {
        rethrow;
      }
      final message = PluginHooks.cancelMessage(error);
      if (message != null && message.isNotEmpty) {
        snackbar.show(message, SnackbarType.info);
      }
    }
  }
}
