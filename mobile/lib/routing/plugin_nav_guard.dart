import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_ids.dart';
import 'package:logging/logging.dart';

/// Runs every navigation to an app route through the `nav.push` hook.
///
/// args: `{ route, path, params, query, stack, redirected }`. A `before` handler may cancel (the navigation does not
/// happen and its message shows), or change `path` (an app path such as `/favorite-route`) or `route` (a route name
/// such as `FavoriteRoute`) to redirect. An `instead` handler that returns a result takes over: the app does not
/// navigate. With no plugin on the hook the navigation continues synchronously.
class PluginNavGuard extends AutoRouteGuard {
  const PluginNavGuard();

  static final _log = Logger('PluginNavGuard');

  /// Redirects in the last second; more than [_maxRedirects] stops redirecting (a plugin loop).
  static final List<DateTime> _recentRedirects = [];
  static const _maxRedirects = 5;
  static bool _nextIsRedirect = false;

  @override
  Future<void> onNavigation(NavigationResolver resolver, StackRouter router) async {
    if (resolver.isReevaluating || !PluginHooks.has(ShellHooks.navPush)) {
      resolver.next();
      return;
    }

    final match = resolver.route;
    final redirected = _nextIsRedirect;
    _nextIsRedirect = false;
    final args = <String, dynamic>{
      'route': match.name,
      'path': match.stringMatch.startsWith('/') ? match.stringMatch : '/${match.stringMatch}',
      'params': _json(match.params.rawMap),
      'query': _json(match.queryParams.rawMap),
      'stack': [for (final page in router.root.stack) page.name],
      'redirected': redirected,
    };

    try {
      await PluginHooks.run<void>(
        ShellHooks.navPush,
        () => args,
        () async => resolver.next(),
        withArgs: (changed) async => _continueOrRedirect(resolver, router, args, changed),
        decode: (_) {},
      );
    } catch (error, stack) {
      if (PluginHooks.isCancelled(error)) {
        ShellHookRunner.showCancelled(error);
      } else {
        _log.warning('nav.push hook failed', error, stack);
        if (!resolver.isResolved) {
          resolver.next();
          return;
        }
      }
    }
    // An `instead` handler took over, or the navigation was cancelled.
    if (!resolver.isResolved) {
      resolver.next(false);
    }
  }

  static void _continueOrRedirect(
    NavigationResolver resolver,
    StackRouter router,
    Map<String, dynamic> original,
    Map<String, dynamic> changed,
  ) {
    final path = changed['path'];
    final route = changed['route'];
    String? target;
    if (path is String && path.isNotEmpty && path != original['path']) {
      target = path;
    } else if (route is String && route.isNotEmpty && route != original['route']) {
      target = pathOfRoute(router.root, route);
    }
    if (target == null || !_allowRedirect()) {
      resolver.next();
      return;
    }
    resolver.next(false);
    _nextIsRedirect = true;
    unawaited(router.root.pushPath(target));
  }

  static bool _allowRedirect() {
    final now = DateTime.now();
    _recentRedirects.removeWhere((time) => now.difference(time) > const Duration(seconds: 1));
    if (_recentRedirects.length >= _maxRedirects) {
      _log.warning('nav.push: too many redirects, ignoring the plugin redirect');
      return false;
    }
    _recentRedirects.add(now);
    return true;
  }

  static Map<String, dynamic> _json(Map<String, dynamic> map) => {
    for (final MapEntry(:key, :value) in map.entries)
      key: value is num || value is bool || value is String || value == null ? value : '$value',
  };
}

/// The app path of the top-level route named [routeName] (`FavoriteRoute` -> `/favorite-route`), or null.
String? pathOfRoute(RoutingController router, String routeName) {
  for (final route in router.routeCollection.routes) {
    if (route.name == routeName) {
      return route.path;
    }
  }
  return null;
}
