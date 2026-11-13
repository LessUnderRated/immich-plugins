import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/local_album.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/plugins/device_workflow_engine.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/presentation/actions/action_hooks.dart';
import 'package:immich_mobile/presentation/plugins/plugin_icons.dart';
import 'package:immich_mobile/presentation/plugins/plugin_ui_renderer.dart';
import 'package:immich_mobile/providers/app_album.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/plugin_kernel.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:photo_manager/photo_manager.dart' hide AssetType;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

export 'package:immich_mobile/presentation/plugins/plugin_icons.dart' show PluginIcon, pluginIconData;

const pluginViewType = 'immich/plugin_view';

class PluginOverlaySpec {
  final String plugin;
  final String id;
  final String view;
  final Map<String, dynamic> params;
  final String? route;
  final bool interactive;
  final Map<String, double> position;

  const PluginOverlaySpec({
    required this.plugin,
    required this.id,
    required this.view,
    this.params = const {},
    this.route,
    this.interactive = false,
    this.position = const {},
  });

  String get key => '$plugin#$id';

  bool showsOn(String? currentRoute) => route == null || route == '*' || route == currentRoute;
}

/// Legacy (v1) contribution lists, route overrides and runtime overlays (`showOverlay`).
///
/// Slot rendering moved to the kernel (`PluginSlot`, [PluginSlotButtons]); this stays for code that reads v1
/// contributions directly (`slot('selection')`, `slot('plugins.page')`) and for route overrides.
class PluginSurfaces extends ChangeNotifier {
  List<PluginContribution> _contributions = const [];
  Map<String, (String, Map<String, dynamic>)> _routes = const {};
  final Map<String, PluginOverlaySpec> _overlays = {};
  final Set<String> _hiddenStatic = {};

  List<PluginContribution> get contributions => _contributions;

  List<PluginContribution> slot(String slot, {PluginContributionKind? kind}) => [
    for (final contribution in _contributions)
      if (contribution.slot == slot && (kind == null || contribution.kind == kind)) contribution,
  ];

  (String, Map<String, dynamic>)? routeOverride(String routeName) => _routes[routeName];

  List<PluginOverlaySpec> overlays(String? currentRoute) => [
    for (final contribution in _contributions)
      if (contribution.kind == PluginContributionKind.overlay &&
          contribution.view != null &&
          !_hiddenStatic.contains(contribution.key) &&
          (contribution.slot == 'global' || contribution.slot.startsWith('route:')))
        PluginOverlaySpec(
          plugin: contribution.plugin,
          id: contribution.id,
          view: contribution.view!,
          params: contribution.params,
          route: contribution.slot == 'global' ? null : contribution.slot.substring('route:'.length),
          interactive: contribution.interactive,
        ),
    ..._overlays.values,
  ].where((overlay) => overlay.showsOn(currentRoute)).toList();

  /// Overlays shown at runtime with the `showOverlay` command.
  List<PluginOverlaySpec> runtimeOverlays(String? currentRoute) => [
    for (final overlay in _overlays.values)
      if (overlay.showsOn(currentRoute)) overlay,
  ];

  /// Whether a manifest overlay was hidden with `hideOverlay`.
  bool isHidden(String plugin, String id) => _hiddenStatic.contains('$plugin#overlay#$id');

  Future<void> refresh(DeviceWorkflowEngine engine) async {
    _contributions = await engine.contributions();
    _routes = await engine.routeOverrides();
    notifyListeners();
  }

  void showOverlay(PluginOverlaySpec overlay) {
    _hiddenStatic.remove('${overlay.plugin}#overlay#${overlay.id}');
    _overlays[overlay.key] = overlay;
    notifyListeners();
  }

  void hideOverlay(String plugin, String id) {
    if (_overlays.remove('$plugin#$id') == null) {
      _hiddenStatic.add('$plugin#overlay#$id');
    }
    notifyListeners();
  }
}

final pluginSurfaces = PluginSurfaces();

final pluginSurfacesProvider = ChangeNotifierProvider<PluginSurfaces>((ref) => pluginSurfaces);

/// `action.<id>` hooks with full AssetV1 assets (the timeline's [ActionHooks] uses it when bound).
class _KernelActionHooks implements ActionHookBinding {
  final PluginKernel _kernel;

  const _KernelActionHooks(this._kernel);

  @override
  bool hasHook(String hookId) => _kernel.hasHook(hookId);

  @override
  Future<void> run(String hookId, ActionHookCall call, Future<void> Function() original) async {
    final args = {
      ...call.toJson(),
      'assets': [for (final asset in call.assets) await _kernel.assetJson(asset)],
    };
    await _kernel.run<void>(hookId, args, (_) => original());
  }
}

/// Wires the plugin kernel to the app UI. Called once from `ImmichApp.initState`; returns the subscription that keeps
/// the legacy [pluginSurfaces] in sync (cancel it in `dispose`).
StreamSubscription<void> startPluginKernel(WidgetRef ref) {
  final kernel = ref.read(pluginKernelProvider);
  final engine = kernel.engine;
  kernel.commandHandler = (plugin, command, context) =>
      performPluginUiAction(ref.read(appRouterProvider), plugin, command, context: context);
  ActionHooks.bind(_KernelActionHooks(kernel));
  final subscription = engine.changes.listen((_) => unawaited(pluginSurfaces.refresh(engine)));
  unawaited(kernel.start().then((_) => pluginSurfaces.refresh(engine)));
  return subscription;
}

class PluginRouteGuard extends AutoRouteGuard {
  const PluginRouteGuard();

  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) {
    final override = pluginSurfaces.routeOverride(resolver.route.name);
    if (override == null) {
      resolver.next(true);
      return;
    }

    final (plugin, spec) = override;
    resolver.next(false);
    final params = {
      ...?(spec['params'] is Map ? Map<String, dynamic>.from(spec['params'] as Map) : null),
      'route': resolver.route.name,
      'path': resolver.route.path,
    };
    final uiMethod = spec['uiMethod'];
    unawaited(
      uiMethod is String || spec['ui'] is Map
          ? router.pushWidget(
              PluginUiPage(
                plugin: plugin,
                title: spec['title'] as String?,
                method: uiMethod is String ? uiMethod : null,
                page: resolver.route.name,
                ui: spec['ui'] is Map ? Map<String, dynamic>.from(spec['ui'] as Map) : null,
                params: params,
              ),
            )
          : router.pushWidget(
              PluginPage(
                plugin: plugin,
                view: '${spec['view'] ?? resolver.route.name}',
                title: spec['title'] as String?,
                fullscreen: spec['fullscreen'] != false,
                params: params,
                composition: spec['composition'] as String?,
              ),
            ),
    );
  }
}

/// A plugin's native Android view (`ImmichViewPlugin.createView`).
///
/// * [composition] `"hybrid"` uses Hybrid Composition (`PlatformViewLink` + `initExpensiveAndroidView`: exact
///   rendering, best for text input and video); anything else uses the texture layer (`AndroidView`).
/// * [interactive] views get every gesture that starts on them (eager gesture forwarding), even inside scroll views.
/// * The plugin receives in its params JSON, besides [params]: `instance` (id for `views.setHeight` /
///   `setContentHeight`), `theme` (`brightness`, `isDark`, `colors` as `#AARRGGBB`, `fontFamily`, `textScale`,
///   `density`) and `composition`.
/// * Height: [height] when given, else the height the plugin reported, else [defaultHeight] (null: fill the parent).
class PluginView extends ConsumerStatefulWidget {
  final String plugin;
  final String view;
  final Map<String, dynamic> params;
  final String? composition;
  final bool interactive;
  final double? height;
  final double? defaultHeight;

  const PluginView({
    super.key,
    required this.plugin,
    required this.view,
    this.params = const {},
    this.composition,
    this.interactive = false,
    this.height,
    this.defaultHeight,
  });

  @override
  ConsumerState<PluginView> createState() => _PluginViewState();
}

class _PluginViewState extends ConsumerState<PluginView> {
  late final PluginKernel _kernel = ref.read(pluginKernelProvider);
  late final String _instance = _kernel.views.newInstanceId(widget.plugin);
  late final ValueNotifier<double?> _reported = _kernel.views.height(_instance);

  @override
  void dispose() {
    _kernel.views.release(_instance);
    super.dispose();
  }

  Widget _platformView(BuildContext context) {
    final hybrid = widget.composition == 'hybrid';
    final theme = pluginThemeInfo(context);
    final creationParams = {
      'plugin': widget.plugin,
      'view': widget.view,
      'composition': hybrid ? 'hybrid' : 'texture',
      'params': jsonEncode({
        ...widget.params,
        'instance': _instance,
        'theme': widget.params['theme'] ?? theme,
        'composition': hybrid ? 'hybrid' : 'texture',
      }),
    };
    final gestures = widget.interactive
        ? <Factory<OneSequenceGestureRecognizer>>{
            const Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
          }
        : const <Factory<OneSequenceGestureRecognizer>>{};
    final key = ValueKey(
      '${widget.plugin}#${widget.view}#${jsonHash(widget.params)}#${theme['brightness']}#${hybrid ? 'h' : 't'}',
    );
    if (!hybrid) {
      return AndroidView(
        key: key,
        viewType: pluginViewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: gestures,
        layoutDirection: Directionality.of(context),
      );
    }
    final direction = Directionality.of(context);
    return PlatformViewLink(
      key: key,
      viewType: pluginViewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: gestures,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: pluginViewType,
          layoutDirection: direction,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        );
        controller.addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
        unawaited(controller.create());
        return controller;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return const Center(child: Text('Plugin views need Android'));
    }
    final view = _platformView(context);
    final fixed = widget.height;
    if (fixed != null) {
      return SizedBox(height: fixed, child: view);
    }
    return ValueListenableBuilder<double?>(
      valueListenable: _reported,
      builder: (context, reported, child) {
        final height = reported ?? widget.defaultHeight;
        return height == null ? child! : SizedBox(height: height, child: child);
      },
      child: view,
    );
  }
}

class PluginPage extends StatelessWidget {
  final String plugin;
  final String view;
  final String? title;
  final bool fullscreen;
  final Map<String, dynamic> params;
  final String? composition;

  const PluginPage({
    super.key,
    required this.plugin,
    required this.view,
    this.title,
    this.fullscreen = false,
    this.params = const {},
    this.composition,
  });

  @override
  Widget build(BuildContext context) {
    final body = PluginView(plugin: plugin, view: view, params: params, composition: composition, interactive: true);
    if (fullscreen && title == null) {
      return Scaffold(body: SafeArea(child: body));
    }
    return Scaffold(
      appBar: AppBar(title: Text(title ?? plugin)),
      body: body,
    );
  }
}

/// Overlays on every screen (`global`) or one route (`route:<RouteName>`), from manifests (kernel slots, legacy and
/// v2) and from `showOverlay`, plus the in-app task indicator.
class PluginOverlayLayer extends ConsumerWidget {
  final Widget child;

  const PluginOverlayLayer({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surfaces = ref.watch(pluginSurfacesProvider);
    final kernel = ref.watch(pluginKernelProvider);
    final route = ref.watch(currentRouteNameProvider);
    final slotContext = {'route': route};
    final staticOverlays = [
      ...kernel.slot(globalOverlaySlot, context: slotContext),
      if (route != null) ...kernel.slot(routeOverlaySlot(route), context: slotContext),
    ].where((item) => item.kind == PluginSlotKind.overlay && !surfaces.isHidden(item.plugin, item.id)).toList();
    final runtime = surfaces.runtimeOverlays(route);
    final tasks = ref.watch(pluginTasksProvider);
    if (staticOverlays.isEmpty && runtime.isEmpty && tasks.isEmpty) {
      return child;
    }
    return Stack(
      children: [
        child,
        for (final item in staticOverlays) _positioned('${item.plugin}#${item.id}', item.position, _content(item)),
        for (final overlay in runtime)
          _positioned(
            overlay.key,
            overlay.position,
            IgnorePointer(
              ignoring: !overlay.interactive,
              child: PluginView(
                plugin: overlay.plugin,
                view: overlay.view,
                params: overlay.params,
                interactive: overlay.interactive,
              ),
            ),
          ),
        if (tasks.isNotEmpty) const PluginTaskIndicator(),
      ],
    );
  }

  static Widget _content(SlotContribution item) {
    final Widget content;
    if (item.view != null) {
      content = PluginView(
        plugin: item.plugin,
        view: item.view!,
        params: item.params,
        composition: item.composition,
        interactive: item.interactive,
      );
    } else if (item.ui != null || item.uiMethod != null) {
      content = Material(
        type: MaterialType.transparency,
        child: PluginUiView(
          plugin: item.plugin,
          ui: item.ui,
          method: item.uiMethod,
          page: item.id,
          params: item.params,
          surface: item.surfaceId,
        ),
      );
    } else {
      return const SizedBox.shrink();
    }
    return IgnorePointer(ignoring: !item.interactive, child: content);
  }

  static Widget _positioned(String key, Map<String, double> position, Widget child) {
    if (position.isEmpty) {
      return Positioned.fill(key: ValueKey(key), child: child);
    }
    return Positioned(
      key: ValueKey(key),
      left: position['left'],
      top: position['top'],
      right: position['right'],
      bottom: position['bottom'],
      width: position['width'],
      height: position['height'],
      child: child,
    );
  }
}

/// Small floating progress pill for running plugin / app tasks; tap shows the list with cancel buttons.
class PluginTaskIndicator extends ConsumerWidget {
  const PluginTaskIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(pluginTasksProvider);
    if (tasks.isEmpty) {
      return const SizedBox.shrink();
    }
    final running = tasks.where((task) => task.isRunning).toList();
    final first = running.firstOrNull ?? tasks.first;
    final scheme = Theme.of(context).colorScheme;
    final padding = MediaQuery.paddingOf(context);
    final failed = first.state == PluginTaskState.failed;
    return Positioned(
      right: 12,
      bottom: padding.bottom + 88,
      child: Material(
        elevation: 4,
        color: scheme.secondaryContainer,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          onTap: () => unawaited(showPluginTasksSheet(context)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 18,
                  child: first.isRunning
                      ? CircularProgressIndicator(strokeWidth: 2.5, value: first.progress)
                      : Icon(failed ? Icons.error_outline : Icons.check_circle_outline, size: 18),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    running.length > 1 ? '${first.title} +${running.length - 1}' : first.title,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSecondaryContainer),
                  ),
                ),
                if (first.isRunning && first.progress != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    '${(first.progress! * 100).round()}%',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One task row: title, message, progress and a cancel button.
class PluginTaskTile extends ConsumerWidget {
  final PluginTask task;

  const PluginTaskTile({super.key, required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitle = [
      task.owner,
      if (task.message != null) task.message!,
      if (task.error != null) task.error!,
      if (!task.isRunning) task.state.name,
    ].join(' · ');
    return ListTile(
      leading: task.isRunning
          ? SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3, value: task.progress))
          : Icon(switch (task.state) {
              PluginTaskState.done => Icons.check_circle_outline,
              PluginTaskState.failed => Icons.error_outline,
              _ => Icons.cancel_outlined,
            }),
      title: Text(task.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (task.isRunning) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: task.progress),
          ],
        ],
      ),
      trailing: task.isRunning && task.cancellable
          ? IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close),
              onPressed: () => ref.read(pluginKernelProvider).tasks.cancel(task.id),
            )
          : null,
    );
  }
}

/// Lists plugin and app tasks in a bottom sheet.
Future<void> showPluginTasksSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => Consumer(
    builder: (context, ref, _) {
      final tasks = ref.watch(pluginTaskHistoryProvider);
      return SafeArea(
        child: tasks.isEmpty
            ? const Padding(padding: EdgeInsets.all(24), child: Text('No tasks'))
            : ListView(shrinkWrap: true, children: [for (final task in tasks) PluginTaskTile(task: task)]),
      );
    },
  ),
);

/// Legacy (v1) buttons of a slot, now rendered from the kernel: legacy `buttons` and v2 `button` / `toggle` items of
/// [slot] as icon buttons. [assets] are sent to the plugin (AssetV1) and describe the slot context for `when`.
class PluginSlotButtons extends ConsumerWidget {
  final String slot;
  final List<BaseAsset> assets;
  final Color? color;

  const PluginSlotButtons({super.key, required this.slot, this.assets = const [], this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kernel = ref.watch(pluginKernelProvider);
    if (!kernel.hasSlot(slot)) {
      return const SizedBox.shrink();
    }
    final slotContext = PluginKernel.assetContext(assets);
    final items = kernel
        .slot(slot, context: slotContext)
        .where((item) => item.kind == PluginSlotKind.button || item.kind == PluginSlotKind.toggle)
        .toList();
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in items)
          item.isToggle
              ? Consumer(
                  builder: (context, ref, _) {
                    final on = ref.watch(pluginToggleProvider(item.toggleKey));
                    return IconButton(
                      tooltip: on ? item.activeTitle ?? item.title : item.title,
                      color: color,
                      isSelected: on,
                      icon: PluginIcon(plugin: item.plugin, icon: item.icon, color: color),
                      selectedIcon: PluginIcon(plugin: item.plugin, icon: item.activeIcon ?? item.icon, color: color),
                      onPressed: () => unawaited(runPluginSlotItem(ref, item, slotContext: slotContext, assets: assets)),
                    );
                  },
                )
              : IconButton(
                  tooltip: item.tooltip ?? item.title,
                  color: color,
                  icon: PluginIcon(plugin: item.plugin, icon: item.icon, color: color),
                  onPressed: () => unawaited(runPluginSlotItem(ref, item, slotContext: slotContext, assets: assets)),
                ),
      ],
    );
  }
}

/// Runs a slot item tap ([PluginKernel.runSlot]); failures show a snackbar.
Future<void> runPluginSlotItem(
  WidgetRef ref,
  SlotContribution item, {
  Map<String, dynamic> slotContext = const {},
  List<BaseAsset> assets = const [],
  BuildContext? context,
}) async {
  try {
    await ref.read(pluginKernelProvider).runSlot(item, context: slotContext, assets: assets, buildContext: context);
  } on PluginCancelled catch (cancelled) {
    ref.read(pluginKernelProvider).showCancelled(cancelled);
  } catch (error) {
    scaffoldMessengerKey.currentState?.showSnackBar(SnackBar(content: Text('${item.title} failed: $error')));
  }
}

/// Overlays over the photo / video viewer: slot `viewer.overlay` and the legacy `viewer` slot. Native views get
/// `params.asset` (AssetV1); JSON UI gets the asset and the slot context as event context; `when` sees the context. The context has `asset`
/// fields, `frame` (`{ left, top, width, height }` of the shown image / video frame in logical pixels, when known)
/// and `zoomed`.
class PluginViewerOverlays extends ConsumerStatefulWidget {
  /// Slot ids served (new first, legacy second).
  static const slots = ['viewer.overlay', 'viewer'];

  final BaseAsset asset;
  final Rect? frame;
  final bool zoomed;

  const PluginViewerOverlays({super.key, required this.asset, this.frame, this.zoomed = false});

  @override
  ConsumerState<PluginViewerOverlays> createState() => _PluginViewerOverlaysState();
}

class _PluginViewerOverlaysState extends ConsumerState<PluginViewerOverlays> {
  Map<String, dynamic>? _asset;
  BaseAsset? _loadedFor;

  bool _hasOverlays(PluginKernel kernel) => PluginViewerOverlays.slots.any(kernel.hasSlot);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(PluginViewerOverlays oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset != widget.asset) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final kernel = ref.read(pluginKernelProvider);
    final asset = widget.asset;
    if (!_hasOverlays(kernel) || identical(_loadedFor, asset)) {
      return;
    }
    _loadedFor = asset;
    final json = await kernel.assetJson(asset);
    if (mounted && identical(widget.asset, asset)) {
      setState(() => _asset = json);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kernel = ref.watch(pluginKernelProvider);
    if (!_hasOverlays(kernel)) {
      return const SizedBox.shrink();
    }
    final frame = widget.frame;
    final slotContext = {
      ...PluginKernel.assetContext([widget.asset]),
      'zoomed': widget.zoomed,
      if (frame != null)
        'frame': {'left': frame.left, 'top': frame.top, 'width': frame.width, 'height': frame.height},
    };
    final overlays = [
      for (final slot in PluginViewerOverlays.slots)
        for (final item in kernel.slot(slot, context: slotContext))
          if (item.kind == PluginSlotKind.overlay || item.kind == PluginSlotKind.view || item.kind == PluginSlotKind.wrap)
            item,
    ];
    final asset = _asset;
    if (overlays.isEmpty) {
      return const SizedBox.shrink();
    }
    if (asset == null) {
      unawaited(_load());
      return const SizedBox.shrink();
    }
    final context = {...slotContext, 'asset': asset};
    return Stack(
      children: [
        for (final overlay in overlays)
          if (overlay.view != null)
            Positioned.fill(
              key: ValueKey('${overlay.key}#view'),
              child: IgnorePointer(
                ignoring: !overlay.interactive,
                child: PluginView(
                  plugin: overlay.plugin,
                  view: overlay.view!,
                  // frame / zoomed change while viewing; they stay out of the params so the view is not recreated
                  params: {...overlay.params, 'asset': asset},
                  composition: overlay.composition,
                  interactive: overlay.interactive,
                ),
              ),
            )
          else if (overlay.ui != null || overlay.uiMethod != null)
            Positioned.fill(
              key: ValueKey('${overlay.key}#ui'),
              child: IgnorePointer(
                ignoring: !overlay.interactive,
                child: Material(
                  type: MaterialType.transparency,
                  child: overlay.uiMethod != null && overlay.ui == null
                      ? _SlotOverlayContent(item: overlay, slotContext: context, asset: widget.asset)
                      : PluginUiView(
                          plugin: overlay.plugin,
                          ui: overlay.ui,
                          method: overlay.method ?? overlay.uiMethod,
                          page: overlay.id,
                          params: overlay.params,
                          eventContext: context,
                          surface: PluginKernel.slotSurfaceId(overlay, slotContext),
                        ),
                ),
              ),
            ),
      ],
    );
  }
}

/// `uiMethod` overlay content (fetched with `SlotV1` per asset and cached like other slot content).
class _SlotOverlayContent extends ConsumerStatefulWidget {
  final SlotContribution item;
  final Map<String, dynamic> slotContext;
  final BaseAsset asset;

  const _SlotOverlayContent({required this.item, required this.slotContext, required this.asset});

  @override
  ConsumerState<_SlotOverlayContent> createState() => _SlotOverlayContentState();
}

class _SlotOverlayContentState extends ConsumerState<_SlotOverlayContent> {
  Future<void>? _pending;

  @override
  Widget build(BuildContext context) {
    final kernel = ref.watch(pluginKernelProvider);
    // content is cached per asset, not per frame position or zoom
    final cacheContext = {...widget.slotContext}
      ..remove('asset')
      ..remove('frame')
      ..remove('zoomed');
    if (!kernel.isSlotUiResolved(widget.item, context: cacheContext)) {
      _pending ??= kernel.slotUi(widget.item, context: cacheContext, assets: [widget.asset]).then((_) {
        _pending = null;
        if (mounted) {
          setState(() {});
        }
      });
      return const SizedBox.shrink();
    }
    final ui = kernel.cachedSlotUi(widget.item, context: cacheContext);
    if (ui == null) {
      return const SizedBox.shrink();
    }
    return PluginUiView(
      plugin: widget.item.plugin,
      ui: ui,
      method: widget.item.method ?? widget.item.uiMethod,
      page: widget.item.id,
      params: widget.item.params,
      eventContext: widget.slotContext,
      surface: PluginKernel.slotSurfaceId(widget.item, cacheContext),
    );
  }
}

/// Runs a legacy (v1) contribution (button or page).
Future<void> runPluginContribution(WidgetRef ref, PluginContribution item, {List<BaseAsset> assets = const []}) async {
  try {
    await ref.read(deviceWorkflowEngineProvider).runContribution(item, assets: assets);
  } catch (error) {
    scaffoldMessengerKey.currentState?.showSnackBar(SnackBar(content: Text('${item.title} failed: $error')));
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------------------------------------------------

Map<String, dynamic> _mapOf(Object? value) => value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<String> _stringsOf(Object? value) => value is List ? [for (final item in value) '$item'] : const [];

void _snack(String message, {SnackBarAction? action}) =>
    scaffoldMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(message), action: action));

Future<List<BaseAsset>> _assetsByIds(PluginKernel kernel, Iterable<String> ids) async => [
  for (final id in ids) ?await kernel.findAsset(id),
];

/// Runs an app command for [plugin] (plan section 3.5). [context] is the widget that triggered it when known; the
/// router's navigator is used otherwise. Returns the command's result (dialog choice, picked assets, ...).
Future<Object?> performPluginUiAction(
  StackRouter router,
  String plugin,
  Map<String, dynamic> action, {
  BuildContext? context,
}) async {
  final owner = '${action['plugin'] ?? plugin}';
  final params = _mapOf(action['params']);
  final navigatorContext = context != null && context.mounted ? context : router.navigatorKey.currentContext;
  final container = navigatorContext == null ? null : ProviderScope.containerOf(navigatorContext, listen: false);
  final kernel = PluginKernel.current;
  switch (action['type']) {
    case 'toast':
      _snack('${action['message'] ?? ''}');
      return null;
    case 'snackbar':
      final button = action['action'];
      _snack(
        '${action['message'] ?? ''}',
        action: button is Map
            ? SnackBarAction(
                label: '${button['label'] ?? 'OK'}',
                onPressed: () {
                  final command = button['command'] is Map ? _mapOf(button['command']) : null;
                  final method = button['method'];
                  if (command != null && kernel != null) {
                    unawaited(kernel.command(owner, command));
                  } else if (method is String && kernel != null) {
                    unawaited(
                      kernel
                          .call(owner, method, PluginCallType.uiEvent, {
                            'surface': 'snackbar',
                            'event': 'action',
                            'value': button['value'],
                          })
                          .then((response) => kernel.perform(owner, response)),
                    );
                  }
                },
              )
            : null,
      );
      return null;
    case 'openUrl':
      final uri = Uri.tryParse('${action['url']}');
      return uri == null ? false : launchUrl(uri, mode: LaunchMode.externalApplication);
    case 'openPage':
      final page = router.pushWidget(
        PluginPage(
          plugin: owner,
          view: '${action['view']}',
          title: action['title'] as String?,
          fullscreen: action['fullscreen'] == true,
          params: params,
          composition: action['composition'] as String?,
        ),
      );
      return action['wait'] == true ? await page : null;
    case 'openUiPage':
      final ui = action['ui'];
      final page = openPluginUiPage(
        router,
        plugin: owner,
        title: action['title'] as String?,
        method: (action['method'] ?? (ui is Map ? null : action['page'])) as String?,
        page: action['page'] as String?,
        ui: ui is Map ? Map<String, dynamic>.from(ui) : null,
        params: params,
        eventContext: _mapOf(action['context']),
        surface: action['surface'] as String?,
      );
      return action['wait'] == true ? await page : null;
    case 'closePage':
    case 'back':
      return router.maybePop(action['result']);
    case 'navigate':
      final path = action['path'];
      if (path is String) {
        unawaited(router.pushPath(path));
      }
      return null;
    case 'showOverlay':
      final position = action['position'];
      pluginSurfaces.showOverlay(
        PluginOverlaySpec(
          plugin: owner,
          id: '${action['id'] ?? action['view']}',
          view: '${action['view']}',
          params: params,
          route: action['route'] as String?,
          interactive: action['interactive'] == true,
          position: position is Map
              ? {
                  for (final MapEntry(:key, :value) in position.entries)
                    if (value is num) '$key': value.toDouble(),
                }
              : const {},
        ),
      );
      return null;
    case 'hideOverlay':
      pluginSurfaces.hideOverlay(owner, '${action['id']}');
      return null;
    case 'routes':
      return router.stack.map((route) => route.name).toList();
    case 'dialog':
    case 'sheet':
      if (navigatorContext == null || !navigatorContext.mounted) {
        return null;
      }
      final ui = action['ui'];
      final show = action['type'] == 'dialog' ? showPluginUiDialog : showPluginUiSheet;
      return show(
        navigatorContext,
        plugin: owner,
        title: action['title'] as String?,
        ui: ui is Map ? Map<String, dynamic>.from(ui) : null,
        method: action['method'] as String?,
        page: action['page'] as String?,
        params: params,
        surface: action['surface'] as String?,
        buttons: action['buttons'] ?? action['options'],
        dismissible: action['dismissible'] != false,
      );
    case 'confirm':
      if (navigatorContext == null || !navigatorContext.mounted) {
        return false;
      }
      final confirmed = await showDialog<bool>(
        context: navigatorContext,
        builder: (context) => AlertDialog(
          title: action['title'] == null ? null : Text('${action['title']}'),
          content: action['message'] == null ? null : Text('${action['message']}'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text('${action['cancel'] ?? 'Cancel'}')),
            FilledButton(
              style: action['destructive'] == true
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    )
                  : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text('${action['confirm'] ?? 'OK'}'),
            ),
          ],
        ),
      );
      return confirmed == true;
    case 'prompt':
      if (navigatorContext == null || !navigatorContext.mounted) {
        return null;
      }
      final controller = TextEditingController(text: action['value'] as String?);
      try {
        return await showDialog<String>(
          context: navigatorContext,
          builder: (context) => AlertDialog(
            title: action['title'] == null ? null : Text('${action['title']}'),
            content: TextField(
              controller: controller,
              autofocus: true,
              obscureText: action['obscure'] == true,
              decoration: InputDecoration(hintText: action['hint'] as String?, labelText: action['label'] as String?),
              onSubmitted: (text) => Navigator.pop(context, text),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('OK')),
            ],
          ),
        );
      } finally {
        controller.dispose();
      }
    case 'pickAssets':
      final picked = await router.push<Set<BaseAsset>>(AssetSelectionTimelineRoute());
      if (picked == null || kernel == null) {
        return const [];
      }
      final limit = action['limit'];
      final list = limit is int && limit > 0 ? picked.take(limit) : picked;
      return [for (final asset in list) await kernel.assetJson(asset)];
    case 'pickAlbum':
      if (navigatorContext == null || !navigatorContext.mounted || container == null) {
        return null;
      }
      return _pickAlbum(navigatorContext, container, title: action['title'] as String?);
    case 'pickDate':
      if (navigatorContext == null || !navigatorContext.mounted) {
        return null;
      }
      final initial = action['value'] is String ? DateTime.tryParse(action['value'] as String) : null;
      final now = DateTime.now();
      final date = await showDatePicker(
        context: navigatorContext,
        initialDate: initial ?? now,
        firstDate: DateTime(1900),
        lastDate: DateTime(now.year + 50),
      );
      return date?.toIso8601String().substring(0, 10);
    case 'openAsset':
      if (kernel == null || container == null) {
        return false;
      }
      final ids = [if (action['assetId'] != null) '${action['assetId']}', ..._stringsOf(action['assetIds'])];
      final assets = await _assetsByIds(kernel, ids);
      if (assets.isEmpty) {
        return false;
      }
      final index = (action['index'] is int ? action['index'] as int : 0).clamp(0, assets.length - 1);
      final viewer = container.read(assetViewerProvider.notifier)..reset();
      if (assets[index].isVideo) {
        viewer.setControls(false);
      }
      viewer.setAsset(assets[index]);
      unawaited(
        router.push(
          AssetViewerRoute(
            initialIndex: index,
            timelineService: container.read(timelineFactoryProvider).fromAssets(assets, TimelineOrigin.deepLink),
          ),
        ),
      );
      return true;
    case 'openAlbum':
      if (container == null) {
        return false;
      }
      return _openAlbum(router, container, '${action['albumId'] ?? action['id']}', kind: action['kind'] as String?);
    case 'select':
      if (kernel == null || container == null) {
        return 0;
      }
      final assets = await _assetsByIds(kernel, _stringsOf(action['assetIds'] ?? action['ids']));
      final notifier = container.read(multiSelectProvider.notifier);
      if (action['replace'] == true) {
        notifier.reset();
      }
      for (final asset in assets) {
        notifier.selectAsset(asset);
      }
      return assets.length;
    case 'clearSelection':
      container?.read(multiSelectProvider.notifier).reset();
      return null;
    case 'haptic':
      switch (action['style'] ?? action['kind']) {
        case 'light':
          await HapticFeedback.lightImpact();
        case 'medium':
          await HapticFeedback.mediumImpact();
        case 'heavy':
          await HapticFeedback.heavyImpact();
        case 'vibrate':
          await HapticFeedback.vibrate();
        default:
          await HapticFeedback.selectionClick();
      }
      return null;
    case 'copy':
      await pluginCopy('${action['text'] ?? ''}');
      if (action['toast'] != false) {
        _snack('${action['message'] ?? 'Copied'}');
      }
      return null;
    case 'share':
      final files = <XFile>[for (final path in _stringsOf(action['files'])) XFile(path)];
      for (final id in _stringsOf(action['assetIds'])) {
        final entity = await AssetEntity.fromId(id);
        final file = await entity?.originFile;
        if (file != null) {
          files.add(XFile(file.path));
        }
      }
      final text = action['text'] as String?;
      if (files.isNotEmpty) {
        await Share.shareXFiles(files, text: text, subject: action['subject'] as String?);
      } else if (text != null) {
        await Share.share(text, subject: action['subject'] as String?);
      }
      return files.length;
    default:
      return null;
  }
}

Future<Map<String, dynamic>?> _pickAlbum(BuildContext context, ProviderContainer container, {String? title}) async {
  final entries = <({String id, String name, String kind, int? count})>[];
  try {
    for (final album in await container.read(appAlbumRepositoryProvider).list()) {
      entries.add((id: album.id, name: album.name, kind: 'app', count: album.assetIds.length));
    }
  } catch (_) {
    // app albums unavailable
  }
  try {
    for (final album in await container.read(remoteAlbumServiceProvider).getAll()) {
      entries.add((id: album.id, name: album.name, kind: 'remote', count: album.assetCount));
    }
  } catch (_) {
    // not signed in
  }
  try {
    final local = LocalAlbumService(container.read(driftProvider).localAlbumRepository);
    for (final album in await local.getAll()) {
      entries.add((id: album.id, name: album.name, kind: 'local', count: album.assetCount));
    }
  } catch (_) {
    // no local albums
  }
  if (!context.mounted) {
    return null;
  }
  final picked = await showModalBottomSheet<({String id, String name, String kind, int? count})>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(title ?? 'Choose an album', style: Theme.of(context).textTheme.titleLarge),
            ),
            if (entries.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No albums')),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final entry in entries)
                    ListTile(
                      leading: Icon(switch (entry.kind) {
                        'remote' => Icons.cloud_outlined,
                        'local' => Icons.phone_android_outlined,
                        _ => Icons.photo_album_outlined,
                      }),
                      title: Text(entry.name),
                      subtitle: entry.count == null ? null : Text('${entry.count}'),
                      onTap: () => Navigator.pop(context, entry),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  return picked == null ? null : {'id': picked.id, 'name': picked.name, 'kind': picked.kind, 'assetCount': picked.count};
}

Future<bool> _openAlbum(StackRouter router, ProviderContainer container, String id, {String? kind}) async {
  if (kind == null || kind == 'app') {
    final album = await container.read(appAlbumRepositoryProvider).get(id);
    if (album != null) {
      unawaited(router.push(AppAlbumRoute(albumId: id)));
      return true;
    }
  }
  if (kind == null || kind == 'remote') {
    try {
      final album = await container.read(remoteAlbumServiceProvider).get(id);
      if (album != null) {
        unawaited(router.push(RemoteAlbumRoute(album: album)));
        return true;
      }
    } catch (_) {
      // not signed in
    }
  }
  if (kind == null || kind == 'local') {
    final albums = await LocalAlbumService(container.read(driftProvider).localAlbumRepository).getAll();
    final LocalAlbum? album = albums.where((album) => album.id == id).firstOrNull;
    if (album != null) {
      unawaited(router.push(LocalTimelineRoute(album: album)));
      return true;
    }
  }
  return false;
}
