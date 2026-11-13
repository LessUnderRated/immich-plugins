/// Ids of everything the timeline area (timelines, selection, action bars, app menu, bottom tabs) exposes to
/// plugins: pages, slots, built-in item ids, hooks, events and host functions. The catalog with argument and result
/// shapes is `docs/plugins/timeline.md`. Action ids are in `presentation/actions/action_ids.dart`.
///
/// Pure Dart, no Flutter imports.
library;

import 'package:immich_mobile/domain/models/timeline_plugin.model.dart';

/// Page ids: route names in lower camel case without `Route`.
abstract final class TimelinePages {
  static const mainTimeline = 'mainTimeline';
  static const archive = 'archive';
  static const favorite = 'favorite';
  static const recentlyAdded = 'recentlyAdded';
  static const recentlyTaken = 'recentlyTaken';
  static const localTimeline = 'localTimeline';
  static const trash = 'trash';
  static const assetSelectionTimeline = 'assetSelectionTimeline';
  static const cleanupPreview = 'cleanupPreview';
  static const deviceTrash = 'deviceTrash';
  static const localMediaSummary = 'localMediaSummary';
  static const remoteMediaSummary = 'remoteMediaSummary';
  static const tabShell = 'tabShell';

  /// A timeline whose page gives no id of its own.
  static const timeline = 'timeline';

  static const all = [
    mainTimeline,
    archive,
    favorite,
    recentlyAdded,
    recentlyTaken,
    localTimeline,
    trash,
    assetSelectionTimeline,
    cleanupPreview,
    deviceTrash,
    localMediaSummary,
    remoteMediaSummary,
    tabShell,
  ];
}

/// Slot ids. Per page: `<page>.appBar.actions`, `<page>.appBar.menu`, `<page>.header`, `<page>.footer`,
/// `<page>.empty`, `<page>.body`. Timeline-wide slots carry `page` and `origin` in their context.
abstract final class TimelineSlots {
  static String appBarActions(String page) => '$page.appBar.actions';
  static String appBarMenu(String page) => '$page.appBar.menu';
  static String header(String page) => '$page.header';
  static String footer(String page) => '$page.footer';
  static String empty(String page) => '$page.empty';
  static String body(String page) => '$page.body';

  /// Above the grid of every timeline (after the page's own header).
  static const timelineHeader = 'timeline.header';

  /// Below the grid of every timeline.
  static const timelineFooter = 'timeline.footer';

  /// Shown instead of the grid of every timeline with no assets.
  static const timelineEmpty = 'timeline.empty';

  /// Decorations of every thumbnail tile: `badge`, `wrap`, `replace`.
  static const tile = 'timeline.tile';

  /// Decorations of every group (date) header: `badge`, `wrap`, `replace`.
  static const groupHeader = 'timeline.groupHeader';

  /// The bottom navigation: plugin `tab` items and built-in tab rules.
  static const tabs = 'tabShell.tabs';

  /// The app menu (⋮) shared by the home tabs.
  static const appMenu = 'app.menu';

  /// Buttons next to the app menu in the home tab app bars (built-ins: `settings`, `menu`).
  static const appActions = 'app.appBar.actions';
}

/// Ids of built-in items that are not actions (`ActionIds`), per slot.
abstract final class TimelineItemIds {
  // mainTimeline.appBar.actions, localTimeline.appBar.actions
  static const galleryView = 'galleryView';

  // app.menu
  static const settings = 'settings';
  static const plugins = 'plugins';
  static const trash = 'trash';
  static const lockedFolder = 'lockedFolder';
  static const appLogs = 'appLogs';

  // app.appBar.actions
  static const settingsButton = 'settings';
  static const appMenu = 'menu';

  // trash.appBar.menu
  static const emptyTrash = 'emptyTrash';
  static const restoreAll = 'restoreAll';

  // deviceTrash.appBar.actions, deviceTrash.selection.actions
  static const selectAll = 'selectAll';
  static const restore = 'restore';
  static const deleteForever = 'deleteForever';

  // selection.status
  static const clearSelection = 'clear';

  // selection.sections
  static const addToAlbum = 'addToAlbum';

  // timeline.groupHeader
  static const groupTitle = 'title';
  static const selectGroup = 'selectGroup';

  // tabShell.tabs
  static const photosTab = 'photos';
  static const albumsTab = 'albums';
  static const privateTab = 'private';
}

/// Hook ids.
abstract final class TimelineHooks {
  /// Every UI action: `action.<actionId>` (see `ActionIds`). Cancellable.
  static String action(String actionId) => 'action.$actionId';

  /// What a timeline shows: filter, sort, group. Not cancellable.
  static const query = timelineQueryHookId;

  /// Tapping a thumbnail outside selection mode (opens the viewer). Cancellable, replaceable.
  static const openAsset = 'timeline.openAsset';

  /// Selecting a bottom navigation tab. Cancellable; `before` may redirect with `{"args": {"id": other}}`.
  static const selectTab = 'tab.select';
}

/// Event names.
abstract final class TimelineEvents {
  static const selectionChanged = 'selection.changed';
  static const tabSelected = 'tab.selected';
  static const reloaded = timelineReloadedEventId;

  /// Throttled to 4 per second.
  static const scrolled = 'timeline.scrolled';
  static const actionPerformed = 'action.performed';
}

/// Host function names.
abstract final class TimelineHostNames {
  static const refresh = 'timeline.refresh';
  static const scrollTo = 'timeline.scrollTo';
  static const visibleRange = 'timeline.visibleRange';
  static const current = 'timeline.current';
  static const assets = 'timeline.assets';
  static const selectionGet = 'selection.get';
  static const selectionSet = 'selection.set';
  static const selectionAdd = 'selection.add';
  static const selectionRemove = 'selection.remove';
  static const selectionClear = 'selection.clear';
  static const selectionAll = 'selection.all';
  static const actionsList = 'actions.list';
  static const actionsRun = 'actions.run';
  static const tabsList = 'tabs.list';
  static const tabsSelect = 'tabs.select';
}
