import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/register_all.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';

/// The plugin kernel. Created once (kept alive); registers every area's plugin API and binds the data layer's
/// [PluginHooks] facade. Widgets that `ref.watch` it rebuild when the plugin contribution index changes (install,
/// enable, disable, `refresh`, `refreshSlots`, `setTheme`), not on toggle or task changes (see the providers below).
final pluginKernelProvider = ChangeNotifierProvider<PluginKernel>((ref) {
  final kernel = PluginKernel(ref.watch(deviceWorkflowEngineProvider));
  PluginKernel.current = kernel;
  PluginHooks.bind(kernel.hookBinding);
  registerAllPluginApis(kernel, ref);
  ref.onDispose(() {
    if (identical(PluginKernel.current, kernel)) {
      PluginHooks.bind(null);
    }
  });
  return kernel;
});

/// The running app's kernel for code without a Riverpod ref, or null before `pluginKernelProvider` was first read
/// (background isolates never have one). Prefer `PluginHooks` in services and repositories.
PluginKernel? get pluginKernelOrNull => PluginKernel.current;

/// The running app's kernel for code without a Riverpod ref. Throws before the app created it; use
/// [pluginKernelOrNull] where that can happen.
PluginKernel get pluginKernel =>
    PluginKernel.current ?? (throw StateError('The plugin kernel is not running (read pluginKernelProvider first)'));

/// The value of a toggle (`<owner>/<id>`, e.g. `app/viewer.shield` or `my-plugin/hud`); rebuilds when any toggle
/// changes. Change it with `ref.read(pluginKernelProvider).toggles.set(key, value)`.
final pluginToggleProvider = Provider.autoDispose.family<bool, String>((ref, key) {
  final toggles = ref.watch(pluginKernelProvider.select((kernel) => kernel.toggles));
  void listener() => ref.invalidateSelf();
  toggles.addListener(listener);
  ref.onDispose(() => toggles.removeListener(listener));
  return toggles.get(key);
});

/// Plugin and app tasks to show (running plus the ones that finished in the last seconds).
final pluginTasksProvider = Provider.autoDispose<List<PluginTask>>((ref) {
  final tasks = ref.watch(pluginKernelProvider.select((kernel) => kernel.tasks));
  void listener() => ref.invalidateSelf();
  tasks.addListener(listener);
  ref.onDispose(() => tasks.removeListener(listener));
  return tasks.visible;
});

/// Every known task, newest first (Plugins page).
final pluginTaskHistoryProvider = Provider.autoDispose<List<PluginTask>>((ref) {
  final tasks = ref.watch(pluginKernelProvider.select((kernel) => kernel.tasks));
  void listener() => ref.invalidateSelf();
  tasks.addListener(listener);
  ref.onDispose(() => tasks.removeListener(listener));
  return tasks.all;
});
