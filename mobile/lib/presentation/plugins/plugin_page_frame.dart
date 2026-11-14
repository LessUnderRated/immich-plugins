import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/plugins/plugin_ids.dart';
import 'package:immich_mobile/providers/timeline/timeline_plugins.provider.dart';

/// The generic slots every page gets (`PLUGINS.md`, "Slots"): `<page>.header` and `<page>.footer` (content above /
/// below the page), `<page>.fab` (content and buttons floating bottom right) and `<page>.body` (`replace` / `wrap` of
/// the whole page). Wrapped around every route by the router; costs nothing for pages no plugin targets.
///
/// A page that renders these slots itself (every timeline, through [PluginPageFrame.claim]) takes them over, so nothing
/// shows twice. The frame draws its slots from the second frame on, after such claims are in. Lock screens and the
/// private pages ([_protected]) get no frame slots: plugin content must never show over them. `<page>.empty` is served
/// by the pages that have an empty state.
class PluginPageFrame extends ConsumerStatefulWidget {
  final String routeName;
  final Widget child;

  const PluginPageFrame({super.key, required this.routeName, required this.child});

  /// Page prefixes whose generic slots are rendered by the page itself, besides timelines (which claim theirs).
  static const _servedByPage = <String, Set<String>>{
    'folder': {PluginSlotSuffix.header},
    'downloadInfo': {PluginSlotSuffix.footer},
    'activities': {PluginSlotSuffix.footer},
  };

  /// Lock screens and private content: no generic slots from the frame.
  static const _protected = {
    'privateGallery',
    'privateViewer',
    'privateLegacy',
    'privateFileViewer',
    'lockedFolder',
    'pinAuth',
  };

  /// Called by a widget that renders `<page>.header/footer/fab/body` for [page] itself (the timeline does): the
  /// enclosing frame then leaves those slots to it.
  static void claim(BuildContext context, String page) {
    final scope = context.getInheritedWidgetOfExactType<_PageSlotScope>();
    if (scope != null && !scope.claims.value.contains(page)) {
      scope.claims.value = {...scope.claims.value, page};
    }
  }

  @override
  ConsumerState<PluginPageFrame> createState() => _PluginPageFrameState();
}

class _PluginPageFrameState extends ConsumerState<PluginPageFrame> {
  final _claims = ValueNotifier<Set<String>>(const {});
  // keeps the page's state when the frame wraps it after the first frame
  final _pageKey = GlobalKey();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _claims.addListener(_changed);
    // draw the frame's slots after the first frame, once the page's own widgets have claimed theirs
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _ready = true);
      }
    });
  }

  @override
  void dispose() {
    _claims
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = KeyedSubtree(key: _pageKey, child: widget.child);
    return _PageSlotScope(claims: _claims, child: _ready ? _framed(context, page) : page);
  }

  Widget _framed(BuildContext context, Widget child) {
    final prefix = routeSlotPrefix(widget.routeName);
    if (PluginPageFrame._protected.contains(prefix) || _claims.value.contains(prefix)) {
      return child;
    }
    final bridge = ref.watch(timelinePluginBridgeProvider);
    String? slotFor(String suffix) =>
        (PluginPageFrame._servedByPage[prefix]?.contains(suffix) ?? false) ? null : '$prefix$suffix';
    final slotContext = {'route': widget.routeName, 'page': prefix};

    final headerSlot = slotFor(PluginSlotSuffix.header);
    final footerSlot = slotFor(PluginSlotSuffix.footer);
    final fabSlot = slotFor(PluginSlotSuffix.fab);
    final bodySlot = slotFor(PluginSlotSuffix.body);

    final header = headerSlot != null && bridge.hasContent(headerSlot) ? bridge.content(headerSlot, slotContext) : null;
    final footer = footerSlot != null && bridge.hasContent(footerSlot) ? bridge.content(footerSlot, slotContext) : null;
    final fabContent = fabSlot != null && bridge.hasContent(fabSlot) ? bridge.content(fabSlot, slotContext) : null;
    final fabButtons = fabSlot == null
        ? const <Widget>[]
        : [for (final b in bridge.buttons(fabSlot, slotContext)) b.item];
    final decorated = bodySlot != null && bridge.hasDecorations(bodySlot);

    if (header == null && footer == null && fabContent == null && fabButtons.isEmpty && !decorated) {
      return child;
    }

    Widget page = decorated ? bridge.decorate(bodySlot, slotContext, child) : child;
    if (header != null || footer != null) {
      page = Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (header != null) SafeArea(bottom: false, child: header),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: header != null,
                removeBottom: footer != null,
                child: page,
              ),
            ),
            if (footer != null) SafeArea(top: false, child: footer),
          ],
        ),
      );
    }
    if (fabContent != null || fabButtons.isNotEmpty) {
      page = Stack(
        children: [
          Positioned.fill(child: page),
          Positioned(
            right: 16,
            bottom: 16 + MediaQuery.paddingOf(context).bottom,
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                spacing: 8,
                children: [?fabContent, ...fabButtons],
              ),
            ),
          ),
        ],
      );
    }
    return page;
  }
}

class _PageSlotScope extends InheritedWidget {
  final ValueNotifier<Set<String>> claims;

  const _PageSlotScope({required this.claims, required super.child});

  @override
  bool updateShouldNotify(_PageSlotScope oldWidget) => !identical(claims, oldWidget.claims);
}
