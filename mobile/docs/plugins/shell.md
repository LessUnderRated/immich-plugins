# App shell: settings, profile menu, app bars, theme, strings, navigation, login, backup, logs, intents

Everything the shell area exposes to plugins. Ids live in code in
`lib/infrastructure/plugins/plugin_api/shell/shell_ids.dart` (`ShellSlots`, `SettingsSectionIds`, `SettingsEntryIds`,
`SettingsItemIds`, `ProfileMenuIds`, `AppBarIds`, `LoginIds`, `BackupPageIds`, `AppLogIds`, `DownloadsRuleDialogIds`,
`ShellHooks`, `ShellEvents`, `ShellHostNames`). Every built-in list goes through one widget,
`ShellList` (`lib/presentation/widgets/shell/shell_list.widget.dart`), which applies the plugin rules and adds plugin
items of the slot through the same bridge as the timeline area (`TimelinePluginBridge`: `arrangeButtons` for button
rows, `arrangeMenuItems` for menus, rules plus content blocks for tile and section lists).

Rules (`contributes.builtins.<slot>`: `hide`, `order`, `rename`) work on every slot below that lists built-in ids.
Plugin items are named `plugin:<plugin>/<id>`. Page slots are named after the route without `Route`, in lower camel
case (`SettingsRoute` -> `settings`, `AppLogRoute` -> `appLog`).

## Settings menu (`SettingsRoute`)

The Settings page is the app's settings menu: a search field, then sections with headers. Sections and tiles that
need a server only show while signed in to a server or while a server is configured.

| Slot | Kinds | Context | Built-in ids |
| --- | --- | --- | --- |
| `settings.sections` | `section` (a JSON UI block with its own header) | `{ "query" }` | `general`, `media`, `plugins`, `privacy`, `account` (server), `advanced`, `about` |
| `settings.general.tiles` | `tile`, `page` | `{ "section" }` | `preferences`, `languages`, `notifications` |
| `settings.media.tiles` | same | same | `timeline`, `assetViewer`, `freeUpSpace` (server) |
| `settings.plugins.tiles` | same | same | `plugins` (opens the Plugins page), then one tile per plugin `contributes.settings` page (`plugin:<plugin>/<settingsId>`) |
| `settings.privacy.tiles` | same | same | `privateGallery` (Private tab), `lockedFolder` (signed in) |
| `settings.account.tiles` | same | same | `networking`, `backup`, `sync`, `passkeys` (signed in and enabled on the server) |
| `settings.advanced.tiles` | same | same | `advanced`, `appLogs`, `sync` (when no server is configured) |
| `settings.about.tiles` | same | same | `whatsNew`, `version` (tap copies), `licenses` |
| `settings.appBar.actions`, `settings.appBar.menu`, `settings.header`, `settings.footer` | `button` / `menuItem` / `section` | `{}` | none |

A tile item: `{ "id", "slot": "settings.media.tiles", "kind": "tile", "title", "subtitle"?, "icon", "keywords"?: [..],
"method"? | "uiMethod"? | "page"? }`. `keywords` feed the settings search. Plugin tiles are searched by title, subtitle
and keywords like built-ins.

**Plugin settings pages.** Every enabled plugin's `contributes.settings` (`{ "id"?, "title", "subtitle"?, "icon"?,
"uiMethod" }`, or `"view"` for a native view) becomes a tile in `settings.plugins.tiles` with the plugin's icon and
title, and is also listed on the Plugins page. Opening it shows a page rendered by the app from the plugin's JSON UI
(`PageV1` call to `uiMethod`, `UiEventV1` for interactions, live updates with `ui.update`/`ui.patch`), themed like
the rest of the app, with back navigation and nested pages. Plugins never need native dialogs for settings.
`app.openSettings("plugin:<plugin>/<id>")` opens it directly.

### Settings sub pages (`SettingsSubRoute`, `SyncStatusRoute`)

| Slot | Built-in ids |
| --- | --- |
| `settings.preferences.items` | `theme`, `haptics`, `share` |
| `settings.timeline.items` | `storageIndicator`, `smoothScrubbing`, `layout`, `groupBy` |
| `settings.assetViewer.items` | `imageQuality`, `tapToNavigate`, `video`, `slideshow` |
| `settings.notifications.items` | `permission` |
| `settings.networking.items` | `currentServer`, `autoSwitching`, `localNetwork`, `externalNetwork` |
| `settings.backup.items` (also `BackupOptionsRoute`) | `networkTitle`, `cellularVideos`, `cellularPhotos`, `backgroundTitle` (Android), `charging` (Android), `backupDelay` (Android), `albumSyncTitle`, `albumSync` |
| `settings.passkeys.items` | `create`, `passkeys` |
| `settings.advanced.items` | `troubleshooting`, `syncRemoteDeletions` (Android 12+), `logLevel`, `preferRemote`, `proxyHeaders`, `sslClientCert`, `readonlyMode`, `clearImageCache` |
| `settings.sync.items` | `stats`, `jobsTitle`, `syncLocal`, `syncRemote`, `syncCloudIds` (iOS), `hashAssets`, `actionsTitle`, `clearFileCache`, `exportDatabase` (debug), `resetDatabase` |
| `settings.languages.header` / `.footer`, `settings.freeUpSpace.header` / `.footer` | the language list and the cleanup wizard are single blocks (`languageList`, `cleanup`) |

Kinds: `tile`, `section` (JSON UI or native view block), `wrap`/`replace` of a built-in item. Context:
`{ "page": "<sub page id>" }`. Every sub page also has `settingsSub.appBar.actions` and `settingsSub.appBar.menu`
with context `{ "page" }`. Setting values are read and written with the data area's `settings.get`/`settings.set`
host functions; the `settings.set` hook and `settings.changed` event cover changes made on these pages.

## Profile menu (app bar avatar dialog)

| Slot | Kinds | Built-in ids |
| --- | --- | --- |
| `profileMenu.header` | `replace`, `wrap` | the close button and logo row |
| `profileMenu.sections` | `section` | `profile`, `storage`, `server` |
| `profileMenu.items` | `tile`, `menuItem` | `readonlyBanner` (read-only mode), `appLogs`, `freeUpSpace`, `settings`, `signOut` |
| `profileMenu.footer` | `button` (text link) | `documentation`, `github`, `licenses` |

## Shared app bars

The shared app bars render the `<page>.appBar.actions` slot of the route that shows them (page = route name, see
above), so pages using them need no slot of their own; a page can pass `slot:` to `ImmichSliverAppBar` to use
another id. The buttons a page passes in keep the ids the page gives them (`BuiltinSlotItem`, action widgets; see
`timeline.md`, e.g. `localTimeline`'s `galleryView`) and sit between the bar's own built-ins, so one set of
`hide`/`order`/`rename` rules covers the whole row. Kinds: `button`, `toggle`. Rules and plugin items use the same
mechanism as the timeline area's bars (`arrangeButtons`).

| App bar | Used by | Built-in ids | Extra context |
| --- | --- | --- | --- |
| `ImmichSliverAppBar` | Library, album pages | `syncStatus`, `cast` (while casting), the page's own buttons, `backup`, `profile` (signed in), `settings` (gear, while no server account is signed in; `showSettingsButton: false` turns it off; same id as the timeline's app menu gear) | |
| `MesmerizingSliverAppBar` | Favorites, Archive, Recently added/taken, Videos, Places, Partner, Locked folder, device and app albums | the page's own buttons | |
| `RemoteAlbumSliverAppBar` | Server album | `slideshow`, `activity` (shared albums with activity), `menu` (the album's ⋮ menu) | `albumId` |
| `PersonSliverAppBar` | Person | `menu` (options) | |
| `SelectionSliverAppBar` | Asset picker timelines | `done` | `selectionCount` |

## Login (`LoginRoute`), change password, splash

| Slot | Built-in ids |
| --- | --- |
| `login.methods` | `password`, `oauth`, `passkey`, `disabled` (no method allowed), `back` |
| `login.footer` | `version`, `logs` |
| `login.header`, `login.body` (`replace`/`wrap`) | logo and title; the whole form |
| `changePassword.body` | the form |
| `splashScreen.body` (`replace`/`wrap`) | the logo |

## Backup (`BackupRoute` and sub pages)

| Slot | Built-in ids |
| --- | --- |
| `backup.appBar.actions` | `options` |
| `backup.sections` | `albums`, `total`, `backedUp`, `remainder`, `toggle`, `error`, `footer` (all but `albums` need selected albums) |
| `backup.footer` | `notificationReliability` (Android), `batteryOptimization` (Android), `uploadDetails` |
| `backupAlbumSelection.appBar.actions`, `uploadDetail.header`, `backupAssetDetail.header`, `backupOptions.footer` | page slots |

## Logs (`AppLogRoute`, `AppLogDetailRoute`)

| Slot | Built-in ids | Context |
| --- | --- | --- |
| `appLog.appBar.actions` | `clear`, `share` | |
| `appLog.header`, `appLog.empty` | | |
| `appLogDetail.sections` | `message`, `details`, `logger`, `stack` | `{ "log": LogV1 }` |

`LogV1`: `{ "level": "finest|finer|fine|config|info|warning|severe|shout", "message", "logger"?, "error"?, "stack"?,
"createdAt" }` (ISO 8601 UTC).

## Other shell pages and dialogs

Every shell route also has the generic page slots `<page>.appBar.actions`, `.appBar.menu`, `.header`, `.footer`,
`.body` (`replace`/`wrap`): `whatsNew`, `headerSettings` (built-in action `add`), `syncStatus`, `shareIntent`
(context `{ "files": [{ "path", "type", "size" }] }`), `profilePictureCrop` (built-in action `done`).

| Slot | Built-in ids |
| --- | --- |
| `downloadsRuleDialog.actions` | `runNow`, `done` |
| `downloadsRuleDialog.sections` | the rule form (plugin `section` items below it) |

## Theme

`contributes.theme`, and at runtime `theme.set`:

```json
{ "seedColor": "#FF4150AF", "variant": "fidelity", "contrast": 0.0,
  "light": { "primary": "#FF4150AF", "surface": "#FFFFFFFF" }, "dark": { "primary": "#FFACCBFA" },
  "fontFamily": "Inter", "fonts": { "Inter": "fonts/Inter.ttf" }, "mode": "dark" }
```

All fields optional. Colors `#AARRGGBB`, `#RRGGBB`, `#RGB`, `0xAARRGGBB` or an int. `seedColor` replaces the color
preset (light and dark) with a generated scheme (`variant`: `tonalSpot`, `fidelity`, `neutral`, `vibrant`,
`expressive`, `content`, `rainbow`, `fruitSalad`, `monochrome`; `contrast` -1..1). `light`/`dark` override single
`ColorScheme` tokens (`primary`, `onPrimary`, `primaryContainer`, ..., `surface`, `surfaceContainer`,
`surfaceContainerHigh`, `onSurface`, `onSurfaceVariant`, `outline`, `outlineVariant`, `error`, `inversePrimary`,
`surfaceTint`, every `ColorScheme` field). `fontFamily` sets the app font; `fonts` loads font files from the plugin's
files first. `mode` forces `light`, `dark` or `system`.

Order: the user's preset (or system colors) -> `seedColor` -> the user's "colorful interface" surface setting ->
token overrides. Manifest themes merge in plugin order (later wins per key); runtime `theme.set` overrides win over
manifests, the most recent call first. Disabling a plugin removes its theme. Native views receive the current
colors in their params (kernel). Event `theme.changed`.

## Strings

`contributes.strings`, and at runtime `strings.set`: `{ "<locale>": { "<key>": "<text>" } }`. Keys are the app's
translation keys (`favorites`, `errors.unable_to_add_album`; see `i18n/en.json`), texts use the same placeholders
(`{count}`, ICU plurals). Locales: `*` (every language), `en`, `pt_BR`, `zh_Hant` (`-` or `_`); the most specific
wins, runtime over manifest. Overrides apply on every translation load and live (no restart); untouched keys keep the
app's text. Event `strings.changed`.

## Hooks

| Hook | Args | `before` | `instead` | `after` result |
| --- | --- | --- | --- | --- |
| `nav.push` | `{ route, path, params, query, stack: [routeName], redirected }` | cancel, or change `path` / `route` to redirect | takes over (the app does not navigate) | none |
| `splash.navigate` | `{ routes: [routeName], deepLink, path: null }` | cancel, or set `path` to open a page over the home screen | takes over navigation | none |
| `login.submit` | `{ method: "password"|"oauth"|"passkey", email?, password?, serverUrl }` | cancel (message shown), or change `email`/`password` | none | none |
| `share.intent` | `{ files: [{ path, type: "image"|"video", size }] }` | cancel, or reduce `files` | handle the files (the share page does not open) | none |
| `shareIntent.upload` | `{ files: [{ path, type, size }] }` | cancel, or reduce `files` | upload elsewhere | none |
| `intent.view` | `{ path, mimeType, localAssetId }` | cancel, or change the fields | handle the file (the app viewer does not open) | none |
| `locale.set` | `{ locale, previous }` | cancel, or pick another supported `locale` | none | none |
| `logs.clear` | `{}` | cancel | none | none |
| `logs.share` | `{}` | cancel | share/upload the log some other way | none |
| `logs.query` | `{ count }` | none | none | `[LogV1]` (filter, sort, add entries; entries keep their `id`) |
| `backup.start` | `{ userId }` | cancel, or change `userId` | run the backup some other way | none |
| `backupAlbum.select`, `backupAlbum.deselect`, `backupAlbum.exclude` | `{ albumId, name, selection }` | cancel | none | none |

Upload of each asset, sync and settings writes are hooked by the data area (`upload.asset`, `sync.*`,
`settings.set`).

## Events

| Event | Payload | Notes |
| --- | --- | --- |
| `app.start` | `{}` | kernel |
| `app.resumed`, `app.inactive`, `app.paused`, `app.hidden`, `app.detached` | `{ state }` | app lifecycle |
| `app.ready` | `{ deepLink, path }` | splash done, home screen showing |
| `route.changed` | `{ route, previous }` | kernel (navigation observer) |
| `settings.opened` | `{ page }` | a settings page opened |
| `theme.changed` | `{ plugin, override }` | |
| `strings.changed` | `{ plugin, locale }` | |
| `locale.changed` | `{ locale, previous }` | |
| `login.succeeded` | `{ method, serverUrl }` | |
| `login.failed` | `{ method, serverUrl, error }` | |
| `shareIntent.received` | `{ files }` | files shared to the app |
| `shareIntent.uploaded` | `{ files }` | |
| `intent.viewed` | `{ path, mimeType, localAssetId }` | |
| `logs.cleared` | `{ plugin? }` | |
| `log.recorded` | `{ records: [LogV1] }` | batched, at most once per second, 200 records max |
| `backup.started` | `{ userId, running, total, backedUp, remainder, ... }` | |
| `backup.stopped` | `{ reason }` | |
| `backup.progress` | `{ localAssetId, filename, bytes, totalBytes, progress }` | throttled 2/s |
| `backup.uploaded` | `{ localAssetId, remoteAssetId, ...status }` | |
| `backup.failed` | `{ localAssetId, error }` | |
| `backup.statusChanged` | backup status (see `backup.status`) | |
| `backupAlbum.changed` | `{ albumId, name, selection }` | |

## Host functions

| Name | Args | Result |
| --- | --- | --- |
| `nav.push` | `[path]` or `[{ path | route, wait? }]` | `true`, or with `wait` the result the page pops with |
| `nav.pop` | `[result?]` | `bool` (popped the top page, plugin pages included) |
| `nav.replace` | `[path]` or `[{ path | route }]` | `true` |
| `nav.replaceAll` | `[[path, ...]]` | `true` (back to the home screen, then each path) |
| `nav.stack` | `[]` | `[{ route, path, params, query }]` |
| `nav.routes` | `[]` | `[{ route, path }]` (routes with required arguments cannot be pushed by path) |
| `theme.get` | `[]` | `{ mode, brightness, light: {token: color}, dark: {...}, fontFamily, override, own }` |
| `theme.set` | `[override]` or `[null]` (clears the caller's) | `true` |
| `strings.get` | `[{ keys?, locale? }]` | `{ locale, strings }` (texts as shown; without keys: the overrides in effect) |
| `strings.set` | `[locale, { key: text }]` or `[locale, null]` | `true` |
| `strings.locale` | `[]` | `{ locale, fallback }` |
| `strings.setLocale` | `[locale]` | `true` (through `locale.set`) |
| `logs.write` | `[level, message, { error?, stack?, logger? }?]` | `true` (logger `plugin.<name>[.<logger>]`) |
| `logs.read` | `[{ limit?, level? (minimum), logger? (prefix), since? }?]` | `[LogV1]`, newest first |
| `logs.clear` | `[]` | `true` |
| `app.openSettings` | `[page?]`: none, a sub page id (`preferences`, `languages`, `notifications`, `timeline`, `assetViewer`, `freeUpSpace`, `networking`, `backup`, `sync`, `passkeys`, `advanced`) or `plugin:<plugin>/<id>` | `bool` |
| `app.settingsPages` | `[]` | `[{ id, title, plugin? }]` |
| `app.lifecycle` | `[]` | `{ state }` |
| `backup.status` | `[]` | `{ running, syncing, total, backedUp, remainder, processing, uploading, error }` |
| `backup.start` | `[]` | `true` (foreground backup of the signed-in user; `backup.start` hook applies) |
| `backup.stop` | `[reason?]` | `true` |
| `backup.albums` | `[]` | `[{ id, name, assetCount, selection: "selected"|"none"|"excluded" }]` |
| `backup.setAlbum` | `[albumId, selection]` | `true` (through the `backupAlbum.*` hooks) |
