import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';
import 'package:immich_mobile/infrastructure/plugins/device_workflow_engine.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

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

  Future<void> refresh(DeviceWorkflowEngine engine) async {
    _contributions = await engine.contributions();
    _routes = await engine.routeOverrides();
    notifyListeners();
  }

  void showOverlay(PluginOverlaySpec overlay) {
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
    unawaited(
      router.pushWidget(
        PluginPage(
          plugin: plugin,
          view: '${spec['view'] ?? resolver.route.name}',
          title: spec['title'] as String?,
          fullscreen: spec['fullscreen'] != false,
          params: {
            ...?(spec['params'] is Map ? Map<String, dynamic>.from(spec['params'] as Map) : null),
            'route': resolver.route.name,
            'path': resolver.route.path,
          },
        ),
      ),
    );
  }
}

class PluginView extends StatelessWidget {
  final String plugin;
  final String view;
  final Map<String, dynamic> params;

  const PluginView({super.key, required this.plugin, required this.view, this.params = const {}});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return const Center(child: Text('Plugin views need Android'));
    }
    return AndroidView(
      key: ValueKey('$plugin#$view#${jsonEncode(params)}'),
      viewType: pluginViewType,
      creationParams: {'plugin': plugin, 'view': view, 'params': jsonEncode(params)},
      creationParamsCodec: const StandardMessageCodec(),
      gestureRecognizers: const {},
    );
  }
}

class PluginPage extends StatelessWidget {
  final String plugin;
  final String view;
  final String? title;
  final bool fullscreen;
  final Map<String, dynamic> params;

  const PluginPage({
    super.key,
    required this.plugin,
    required this.view,
    this.title,
    this.fullscreen = false,
    this.params = const {},
  });

  @override
  Widget build(BuildContext context) {
    final body = PluginView(plugin: plugin, view: view, params: params);
    if (fullscreen && title == null) {
      return Scaffold(body: SafeArea(child: body));
    }
    return Scaffold(
      appBar: AppBar(title: Text(title ?? plugin)),
      body: body,
    );
  }
}

class PluginOverlayLayer extends ConsumerWidget {
  final Widget child;

  const PluginOverlayLayer({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surfaces = ref.watch(pluginSurfacesProvider);
    final overlays = surfaces.overlays(ref.watch(currentRouteNameProvider));
    if (overlays.isEmpty) {
      return child;
    }
    return Stack(children: [child, for (final overlay in overlays) _positioned(overlay)]);
  }

  Widget _positioned(PluginOverlaySpec overlay) {
    final view = IgnorePointer(
      ignoring: !overlay.interactive,
      child: PluginView(plugin: overlay.plugin, view: overlay.view, params: overlay.params),
    );
    final position = overlay.position;
    if (position.isEmpty) {
      return Positioned.fill(key: ValueKey(overlay.key), child: view);
    }
    return Positioned(
      key: ValueKey(overlay.key),
      left: position['left'],
      top: position['top'],
      right: position['right'],
      bottom: position['bottom'],
      width: position['width'],
      height: position['height'],
      child: view,
    );
  }
}

const _icons = <String, IconData>{
  'extension': Icons.extension_outlined,
  'star': Icons.star_outline,
  'favorite': Icons.favorite_outline,
  'share': Icons.share_outlined,
  'edit': Icons.edit_outlined,
  'delete': Icons.delete_outline,
  'info': Icons.info_outline,
  'settings': Icons.settings_outlined,
  'search': Icons.search,
  'filter': Icons.filter_alt_outlined,
  'sort': Icons.sort,
  'tune': Icons.tune,
  'shield': Icons.shield_outlined,
  'lock': Icons.lock_outline,
  'visibility': Icons.visibility_outlined,
  'visibility_off': Icons.visibility_off_outlined,
  'image': Icons.image_outlined,
  'photo': Icons.photo_outlined,
  'video': Icons.videocam_outlined,
  'album': Icons.photo_album_outlined,
  'folder': Icons.folder_outlined,
  'download': Icons.download_outlined,
  'upload': Icons.upload_outlined,
  'cloud': Icons.cloud_outlined,
  'sync': Icons.sync,
  'refresh': Icons.refresh,
  'play': Icons.play_arrow_outlined,
  'pause': Icons.pause_outlined,
  'brush': Icons.brush_outlined,
  'blur': Icons.blur_on,
  'grid': Icons.grid_on,
  'label': Icons.label_outline,
  'tag': Icons.sell_outlined,
  'map': Icons.map_outlined,
  'person': Icons.person_outline,
  'face': Icons.face_outlined,
  'calendar': Icons.calendar_today_outlined,
  'more': Icons.more_vert,
  'add': Icons.add,
  'check': Icons.check,
  'close': Icons.close,
  'open': Icons.open_in_new,
  'link': Icons.link,
  'code': Icons.code,
  'bolt': Icons.bolt_outlined,
  'magic': Icons.auto_fix_high_outlined,
};

class PluginIcon extends ConsumerWidget {
  final String plugin;
  final String? icon;
  final Color? color;

  const PluginIcon({super.key, required this.plugin, this.icon, this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final icon = this.icon;
    if (icon != null && icon.contains('.')) {
      final root = ref.watch(pluginFilesRootProvider).valueOrNull;
      if (root != null) {
        return Image.file(File(p.join(root, plugin, 'files', icon)), width: 24, height: 24, color: color);
      }
    }
    return Icon(_icons[icon] ?? Icons.extension_outlined, color: color);
  }
}

class PluginSlotButtons extends ConsumerWidget {
  final String slot;
  final List<LocalAsset> assets;
  final Color? color;

  const PluginSlotButtons({super.key, required this.slot, this.assets = const [], this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref
        .watch(pluginSurfacesProvider)
        .slot(slot)
        .where((item) => item.kind != PluginContributionKind.overlay)
        .toList();
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in items)
          IconButton(
            tooltip: item.title,
            color: color,
            icon: PluginIcon(plugin: item.plugin, icon: item.icon, color: color),
            onPressed: () => runPluginContribution(ref, item, assets: assets),
          ),
      ],
    );
  }
}

class PluginViewerOverlays extends ConsumerStatefulWidget {
  final BaseAsset asset;

  const PluginViewerOverlays({super.key, required this.asset});

  @override
  ConsumerState<PluginViewerOverlays> createState() => _PluginViewerOverlaysState();
}

class _PluginViewerOverlaysState extends ConsumerState<PluginViewerOverlays> {
  Map<String, dynamic>? _asset;

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
    final asset = widget.asset;
    final json = asset is LocalAsset
        ? await ref.read(deviceWorkflowEngineProvider).assetJson(asset)
        : <String, dynamic>{'id': asset is RemoteAsset ? asset.id : asset.heroTag, 'originalFileName': asset.name};
    if (mounted) {
      setState(() => _asset = json);
    }
  }

  @override
  Widget build(BuildContext context) {
    final overlays = ref.watch(pluginSurfacesProvider).slot('viewer', kind: PluginContributionKind.overlay);
    final asset = _asset;
    if (overlays.isEmpty || asset == null) {
      return const SizedBox.shrink();
    }
    return Stack(
      children: [
        for (final overlay in overlays)
          if (overlay.view != null)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !overlay.interactive,
                child: PluginView(
                  plugin: overlay.plugin,
                  view: overlay.view!,
                  params: {...overlay.params, 'asset': asset},
                ),
              ),
            ),
      ],
    );
  }
}

Future<void> runPluginContribution(WidgetRef ref, PluginContribution item, {List<LocalAsset> assets = const []}) async {
  try {
    await ref.read(deviceWorkflowEngineProvider).runContribution(item, assets: assets);
  } catch (error) {
    scaffoldMessengerKey.currentState?.showSnackBar(SnackBar(content: Text('${item.title} failed: $error')));
  }
}

Future<Object?> performPluginUiAction(StackRouter router, String plugin, Map<String, dynamic> action) async {
  final params = action['params'] is Map ? Map<String, dynamic>.from(action['params'] as Map) : <String, dynamic>{};
  switch (action['type']) {
    case 'toast':
      scaffoldMessengerKey.currentState?.showSnackBar(SnackBar(content: Text('${action['message'] ?? ''}')));
      return null;
    case 'openUrl':
      final uri = Uri.tryParse('${action['url']}');
      return uri == null ? false : launchUrl(uri, mode: LaunchMode.externalApplication);
    case 'openPage':
      unawaited(
        router.pushWidget(
          PluginPage(
            plugin: '${action['plugin'] ?? plugin}',
            view: '${action['view']}',
            title: action['title'] as String?,
            fullscreen: action['fullscreen'] == true,
            params: params,
          ),
        ),
      );
      return null;
    case 'closePage':
    case 'back':
      return router.maybePop();
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
          plugin: '${action['plugin'] ?? plugin}',
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
      pluginSurfaces.hideOverlay('${action['plugin'] ?? plugin}', '${action['id']}');
      return null;
    case 'routes':
      return router.stack.map((route) => route.name).toList();
    default:
      return null;
  }
}
