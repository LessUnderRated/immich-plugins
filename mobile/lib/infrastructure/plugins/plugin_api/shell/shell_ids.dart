/// Ids of everything the app shell exposes to plugins: slots, built-in item ids, hooks, events and host functions.
///
/// Pure Dart (no Flutter imports) so services, tests and the kernel can use the same names. `docs/plugins/shell.md`
/// documents every entry; keep both in sync.
library;

/// Slot id prefix of a route: the route name in lower camel case without `Route`
/// (`MainTimelineRoute` -> `mainTimeline`, `SettingsSubRoute` -> `settingsSub`).
String routeSlotPrefix(String routeName) {
  var name = routeName.endsWith('Route') ? routeName.substring(0, routeName.length - 'Route'.length) : routeName;
  if (name.isEmpty) {
    name = routeName;
  }
  return name[0].toLowerCase() + name.substring(1);
}

/// Generic slot suffixes every page gets (plan section 4).
abstract final class PageSlotSuffix {
  static const appBarActions = 'appBar.actions';
  static const appBarMenu = 'appBar.menu';
  static const header = 'header';
  static const footer = 'footer';
  static const empty = 'empty';
  static const fab = 'fab';
  static const body = 'body';
}

/// `<page>.<suffix>`, e.g. `pageSlot('BackupRoute', PageSlotSuffix.appBarActions)` -> `backup.appBar.actions`.
String pageSlot(String routeName, String suffix) => '${routeSlotPrefix(routeName)}.$suffix';

/// Slots of the shell area and the built-in item ids each one holds.
abstract final class ShellSlots {
  // ---- main settings page (SettingsRoute) ---------------------------------------------------------------------
  /// Entries of the main Settings page (one card per entry). Built-ins: [SettingsEntryIds].
  static const settingsSections = 'settings.sections';

  /// Entries of the settings tablet layout's side list (same ids as [settingsSections]).
  static const settingsSectionsTablet = 'settings.sections';

  /// Items of a built-in settings sub page: `settings.<section>.items` (see [SettingsEntryIds] for sections).
  static String settingsItems(String section) => 'settings.$section.items';

  // ---- app bar profile dialog -----------------------------------------------------------------------------------
  /// Information boxes at the top of the profile dialog. Built-ins: [ProfileMenuIds.sections].
  static const profileMenuSections = 'profileMenu.sections';

  /// Action rows of the profile dialog. Built-ins: [ProfileMenuIds.items].
  static const profileMenuItems = 'profileMenu.items';

  /// Footer links of the profile dialog. Built-ins: [ProfileMenuIds.footer].
  static const profileMenuFooter = 'profileMenu.footer';

  /// Top row of the profile dialog (close button and logo); `replace`/`wrap`.
  static const profileMenuHeader = 'profileMenu.header';

  // ---- login -------------------------------------------------------------------------------------------------------
  /// Sign-in methods on the login form. Built-ins: [LoginIds.methods].
  static const loginMethods = 'login.methods';

  /// Bottom bar of the login page (version and logs link). Built-ins: [LoginIds.footer].
  static const loginFooter = 'login.footer';

  // ---- backup ---------------------------------------------------------------------------------------------------
  /// Cards of the backup page. Built-ins: [BackupPageIds.sections].
  static const backupSections = 'backup.sections';

  /// Links under the backup toggle. Built-ins: [BackupPageIds.footer].
  static const backupFooterLinks = 'backup.footer';

  // ---- logs -------------------------------------------------------------------------------------------------------
  /// Blocks of the log detail page. Built-ins: [AppLogIds.detailSections].
  static const appLogDetailSections = 'appLogDetail.sections';

  // ---- dialogs ----------------------------------------------------------------------------------------------------
  /// Downloads rule dialog actions. Built-ins: [DownloadsRuleDialogIds.actions].
  static const downloadsRuleDialogActions = 'downloadsRuleDialog.actions';

  /// Downloads rule dialog body (`section` items are added below the built-in form).
  static const downloadsRuleDialogSections = 'downloadsRuleDialog.sections';

  // ---- splash -----------------------------------------------------------------------------------------------------
  /// The splash logo; `replace`/`wrap`.
  static const splashBody = 'splashScreen.body';
}

/// Built-in entries of the main Settings page and the sub pages they open (`settings.<id>.items`).
abstract final class SettingsEntryIds {
  static const advanced = 'advanced';
  static const assetViewer = 'assetViewer';
  static const backup = 'backup';
  static const freeUpSpace = 'freeUpSpace';
  static const languages = 'languages';
  static const networking = 'networking';
  static const notifications = 'notifications';
  static const passkeys = 'passkeys';
  static const preferences = 'preferences';
  static const timeline = 'timeline';

  /// Opens the sync status page (`SyncStatusRoute`); its items slot is `settings.sync.items`.
  static const sync = 'sync';
  static const whatsNew = 'whatsNew';

  /// The block listing every plugin's `contributes.settings` page (hide or move it as a whole).
  static const pluginSettings = 'pluginSettings';

  static const all = [
    advanced,
    assetViewer,
    backup,
    freeUpSpace,
    languages,
    networking,
    notifications,
    passkeys,
    preferences,
    timeline,
    sync,
    whatsNew,
    pluginSettings,
  ];
}

/// Built-in item ids of each settings sub page (`settings.<section>.items`).
abstract final class SettingsItemIds {
  static const advanced = [
    'troubleshooting',
    'syncRemoteDeletions',
    'logLevel',
    'preferRemote',
    'proxyHeaders',
    'sslClientCert',
    'readonlyMode',
    'clearImageCache',
  ];
  static const assetViewer = ['imageQuality', 'tapToNavigate', 'video', 'slideshow'];
  static const backup = [
    'networkTitle',
    'cellularVideos',
    'cellularPhotos',
    'backgroundTitle',
    'charging',
    'backupDelay',
    'albumSyncTitle',
    'albumSync',
  ];
  static const freeUpSpace = ['cleanup'];
  static const languages = ['languageList'];
  static const networking = ['currentServer', 'autoSwitching', 'localNetwork', 'externalNetwork'];
  static const notifications = ['permission'];
  static const passkeys = ['create', 'passkeys'];
  static const preferences = ['theme', 'haptics', 'share'];
  static const timeline = ['storageIndicator', 'smoothScrubbing', 'layout', 'groupBy'];
  static const sync = ['stats', 'syncLocal', 'syncRemote', 'syncCloudIds', 'hashAssets', 'clearFileCache', 'exportDatabase', 'resetDatabase'];

  static const bySection = {
    SettingsEntryIds.advanced: advanced,
    SettingsEntryIds.assetViewer: assetViewer,
    SettingsEntryIds.backup: backup,
    SettingsEntryIds.freeUpSpace: freeUpSpace,
    SettingsEntryIds.languages: languages,
    SettingsEntryIds.networking: networking,
    SettingsEntryIds.notifications: notifications,
    SettingsEntryIds.passkeys: passkeys,
    SettingsEntryIds.preferences: preferences,
    SettingsEntryIds.timeline: timeline,
    SettingsEntryIds.sync: sync,
  };
}

/// Built-in ids of the app bar profile dialog.
abstract final class ProfileMenuIds {
  static const profile = 'profile';
  static const storage = 'storage';
  static const server = 'server';
  static const sections = [profile, storage, server];

  static const readonlyBanner = 'readonlyBanner';
  static const appLogs = 'appLogs';
  static const freeUpSpace = 'freeUpSpace';
  static const settings = 'settings';
  static const signOut = 'signOut';
  static const items = [readonlyBanner, appLogs, freeUpSpace, settings, signOut];

  static const documentation = 'documentation';
  static const github = 'github';
  static const licenses = 'licenses';
  static const footer = [documentation, github, licenses];
}

/// Built-in action ids of the shared app bars (rendered in `<page>.appBar.actions` of the page showing them).
abstract final class AppBarIds {
  // ImmichSliverAppBar (main timeline, library, album pages)
  static const syncStatus = 'syncStatus';
  static const cast = 'cast';

  /// The actions the page itself passes to the app bar, as one block.
  static const pageActions = 'pageActions';
  static const backup = 'backup';
  static const profile = 'profile';
  static const immichAppBar = [syncStatus, cast, pageActions, backup, profile];

  // RemoteAlbumSliverAppBar
  static const slideshow = 'slideshow';
  static const activity = 'activity';
  static const menu = 'menu';
  static const remoteAlbumAppBar = [slideshow, activity, menu];

  // SelectionSliverAppBar
  static const done = 'done';
  static const selectionAppBar = [done];
}

abstract final class LoginIds {
  static const password = 'password';
  static const oauth = 'oauth';
  static const passkey = 'passkey';
  static const back = 'back';
  static const methods = [password, oauth, passkey, back];

  static const version = 'version';
  static const logs = 'logs';
  static const footer = [version, logs];
}

abstract final class BackupPageIds {
  static const options = 'options';
  static const appBarActions = [options];

  static const albums = 'albums';
  static const total = 'total';
  static const backedUp = 'backedUp';
  static const remainder = 'remainder';
  static const toggle = 'toggle';
  static const error = 'error';
  static const footerLinks = 'footer';
  static const sections = [albums, total, backedUp, remainder, toggle, error, footerLinks];

  static const notificationReliability = 'notificationReliability';
  static const batteryOptimization = 'batteryOptimization';
  static const uploadDetails = 'uploadDetails';
  static const footer = [notificationReliability, batteryOptimization, uploadDetails];
}

abstract final class AppLogIds {
  static const clear = 'clear';
  static const share = 'share';
  static const appBarActions = [clear, share];

  static const message = 'message';
  static const details = 'details';
  static const logger = 'logger';
  static const stack = 'stack';
  static const detailSections = [message, details, logger, stack];
}

abstract final class DownloadsRuleDialogIds {
  static const runNow = 'runNow';
  static const done = 'done';
  static const actions = [runNow, done];
}

/// Hooks run by the shell (`kernel.run` / `PluginHooks.run`).
abstract final class ShellHooks {
  /// Before every navigation to an app route. args `{ route, path, params, query, stack }`.
  /// `before` may cancel, or change `path` (or `route`) to redirect.
  static const navPush = 'nav.push';

  /// The splash screen leaving for the home screen. args `{ routes, deepLink }`. `before` may change `path` to open an
  /// extra page on top of the home screen; `instead` takes over navigation entirely.
  static const splashNavigate = 'splash.navigate';

  /// A login attempt from the login form. args `{ method, email?, password?, serverUrl }`; cancellable.
  static const loginSubmit = 'login.submit';

  /// Upload of shared files from the share intent page. args `{ files: [{ path, type, size }] }`; `before` may cancel
  /// or reduce `files`; `instead` uploads them some other way.
  static const shareIntentUpload = 'shareIntent.upload';

  /// A file opened in the app with an Android VIEW intent. args `{ path, mimeType, localAssetId }`; `before` may
  /// cancel; `instead` handles it (the app does not open its viewer).
  static const intentView = 'intent.view';

  /// Clearing the app log; cancellable.
  static const logsClear = 'logs.clear';

  /// Sharing the app log; `instead` replaces sharing (for example uploading it somewhere).
  static const logsShare = 'logs.share';

  /// The app log list shown on the logs page; `after` may filter, sort or extend `[LogV1]`.
  static const logsQuery = 'logs.query';

  /// Changing the app language. args `{ locale }`; `before` may cancel or change `locale`.
  static const localeSet = 'locale.set';

  /// Starting a foreground backup. args `{ userId }`; cancellable.
  static const backupStart = 'backup.start';

  /// Stopping the foreground backup. args `{ reason }`; cancellable.
  static const backupStop = 'backup.stop';

  /// Selecting, deselecting or excluding a device album for backup. args `{ albumId, name }`; cancellable.
  static const backupAlbumSelect = 'backupAlbum.select';
  static const backupAlbumDeselect = 'backupAlbum.deselect';
  static const backupAlbumExclude = 'backupAlbum.exclude';

  static const all = [
    navPush,
    splashNavigate,
    loginSubmit,
    shareIntentUpload,
    intentView,
    logsClear,
    logsShare,
    logsQuery,
    localeSet,
    backupStart,
    backupStop,
    backupAlbumSelect,
    backupAlbumDeselect,
    backupAlbumExclude,
  ];
}

/// Events emitted by the shell.
abstract final class ShellEvents {
  static const appResumed = 'app.resumed';
  static const appInactive = 'app.inactive';
  static const appPaused = 'app.paused';
  static const appHidden = 'app.hidden';
  static const appDetached = 'app.detached';

  /// The splash screen finished and the home screen is showing. `{ deepLink }`.
  static const appReady = 'app.ready';
  static const themeChanged = 'theme.changed';
  static const stringsChanged = 'strings.changed';
  static const localeChanged = 'locale.changed';
  static const loginSucceeded = 'login.succeeded';
  static const loginFailed = 'login.failed';
  static const shareIntentReceived = 'shareIntent.received';
  static const shareIntentUploaded = 'shareIntent.uploaded';
  static const intentViewed = 'intent.viewed';
  static const logsCleared = 'logs.cleared';
  static const logRecorded = 'log.recorded';
  static const backupStarted = 'backup.started';
  static const backupStopped = 'backup.stopped';
  static const backupProgress = 'backup.progress';
  static const backupUploaded = 'backup.uploaded';
  static const backupFailed = 'backup.failed';
  static const backupStatusChanged = 'backup.statusChanged';
  static const backupAlbumChanged = 'backupAlbum.changed';
  static const settingsOpened = 'settings.opened';

  static const all = [
    appResumed,
    appInactive,
    appPaused,
    appHidden,
    appDetached,
    appReady,
    themeChanged,
    stringsChanged,
    localeChanged,
    loginSucceeded,
    loginFailed,
    shareIntentReceived,
    shareIntentUploaded,
    intentViewed,
    logsCleared,
    logRecorded,
    backupStarted,
    backupStopped,
    backupProgress,
    backupUploaded,
    backupFailed,
    backupStatusChanged,
    backupAlbumChanged,
    settingsOpened,
  ];
}

/// Host functions registered by the shell.
abstract final class ShellHostNames {
  static const navPush = 'nav.push';
  static const navPop = 'nav.pop';
  static const navReplace = 'nav.replace';
  static const navReplaceAll = 'nav.replaceAll';
  static const navStack = 'nav.stack';
  static const navRoutes = 'nav.routes';
  static const themeGet = 'theme.get';
  static const themeSet = 'theme.set';
  static const stringsGet = 'strings.get';
  static const stringsSet = 'strings.set';
  static const stringsLocale = 'strings.locale';
  static const stringsSetLocale = 'strings.setLocale';
  static const logsWrite = 'logs.write';
  static const logsRead = 'logs.read';
  static const logsClear = 'logs.clear';
  static const appOpenSettings = 'app.openSettings';
  static const appSettingsPages = 'app.settingsPages';
  static const appLifecycle = 'app.lifecycle';
  static const backupStatus = 'backup.status';
  static const backupStart = 'backup.start';
  static const backupStop = 'backup.stop';
  static const backupAlbums = 'backup.albums';
  static const backupSetAlbum = 'backup.setAlbum';

  static const all = [
    navPush,
    navPop,
    navReplace,
    navReplaceAll,
    navStack,
    navRoutes,
    themeGet,
    themeSet,
    stringsGet,
    stringsSet,
    stringsLocale,
    stringsSetLocale,
    logsWrite,
    logsRead,
    logsClear,
    appOpenSettings,
    appSettingsPages,
    appLifecycle,
    backupStatus,
    backupStart,
    backupStop,
    backupAlbums,
    backupSetAlbum,
  ];
}
