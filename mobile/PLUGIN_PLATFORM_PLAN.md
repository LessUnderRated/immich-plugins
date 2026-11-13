# Plugin platform plan: plugins can do everything

Status: implemented (kernel, all seven areas, native host) and analyzer-clean; not yet built into an APK or run on a
device. `PLUGINS.md` is the reference and `docs/plugins/*.md` the per-area catalogs; each catalog ends with what is
not wired yet. Plugins stay Aliucord-style native dex plugins; this plan changed the **app** so that every surface,
action, data path and setting is reachable, changeable or replaceable from a plugin.

## 1. The honest constraint, and what "everything" means here

Aliucord reaches all of Discord because Discord is Java/Kotlin and Aliucord patches any method at runtime. Immich's UI
and logic are Dart compiled ahead of time to machine code; nothing in a release build can be patched at runtime.
So "plugins can do everything" is achieved by building the patch points into the app **systematically**:

1. **Every surface has slots.** Every page, app bar, overflow (⋮) menu, bottom sheet, action bar, list, settings page,
   dialog, tab bar, editor and viewer exposes named slots where plugins add buttons, menu items, tiles, sections,
   chips, badges, panels, tabs, tools or whole native views.
2. **Every built-in item has an id** and can be hidden, reordered, wrapped or replaced by a plugin.
3. **Every action and data mutation runs through a hook** (`before` / `instead` / `after`), the equivalent of Aliucord's
   method patches: a plugin can cancel it, change its arguments, replace it entirely, or change its result.
4. **Every state change emits an event** plugins can subscribe to.
5. **Everything the app can do is a host function** plugins can call: assets, albums, tags, people, search, timeline,
   viewer, video player, editor, navigation, settings, theme, strings, database (raw SQL), files, network, backup and
   sync, notifications, dialogs and pickers.
6. **Plugin UI can be native Flutter** (a JSON UI tree rendered with the app's own theme and widgets) or a native
   Android view; pages, dialogs, sheets, tabs, settings pages, editor panels and overlays all accept either.
7. **Whole screens can be replaced** (route override, already present) and **the theme and every string can be
   overridden**.

The coverage checklist in section 8 is the definition of done. Anything not listed there is a bug in this plan.

## 2. Ground rules for everyone working on this

- No APK build. `dart analyze lib` (with the bundled SDK:
  `/root/.local/share/mise/installs/aqua-flutter-flutter/3.47.9/flutter/bin/dart analyze <paths>`) must report
  **0 errors and 0 warnings**; do not add infos. Baseline before this work: 0 errors, 0 warnings, 22 infos.
- **No code generation changes.** Do not add or change `@freezed` classes, `@RoutePage` routes, Drift tables, pigeon
  APIs or translation keys; generated files are git-ignored and are not regenerated here. Use `router.pushWidget`
  for new screens, plain Dart classes for models, raw SQL through Drift's `customSelect`/`customStatement` for data.
- Follow `mobile/AGENTS.md` layering: models and pure logic in `lib/domain/`, implementations in `lib/infrastructure/`,
  widgets in `lib/presentation/`, wiring in `lib/providers/`. Legacy folders (`lib/pages`, `lib/widgets`,
  `lib/services`, `lib/repositories`, `lib/entities`) may be **edited** to add hook points but get **no new files**.
- **Zero cost when unused.** A slot with no contributions renders nothing (`SizedBox.shrink()` or the untouched
  original). A hook with no subscribers calls the original synchronously-equivalent path with no extra awaits beyond
  the original's. Check `kernel.hasHook(id)` before building hook arguments that are expensive.
- **Never break the built-in behaviour.** A plugin error in a slot shows nothing (logged); a plugin error in a hook
  logs and falls back to the original; timeouts (default 10 s for hooks, configurable per hook in the manifest)
  fall back to the original.
- **Backwards compatible.** Existing manifests (`buttons`, `pages`, `overlays`, `events`, `routes`, method `types`
  such as `CensorStyleV1`, `ViewerFilterV1`, `GalleryViewV1`, `AssetActionV1`, `AssetV1`) keep working unchanged.
- Agents do not commit; the orchestrator commits and pushes.
- Each area documents everything it exposes in `mobile/docs/plugins/<area>.md` (format in section 9).

## 3. Kernel (phase 1)

Files (new unless noted):

| File | Purpose |
| --- | --- |
| `lib/domain/models/device_plugin.model.dart` (edit) | manifest v2 parsing: slots, hooks, events (patterns), tools, settings, tabs, theme, strings, hide/order rules |
| `lib/domain/plugins/plugin_ids.dart` | id conventions, call type names (`SlotV1`, `HookV1`, ...), condition matching for `when` |
| `lib/infrastructure/plugins/plugin_kernel.dart` | `PluginKernel`: contribution index, hook runner, event bus, host function registry, plugin calls, asset JSON |
| `lib/infrastructure/plugins/plugin_api/` | one registration file per area, each exporting `void register<Area>PluginApi(PluginKernel kernel, Ref ref)`; phase 1 creates empty stubs, phase 2 fills them |
| `lib/providers/plugin_kernel.provider.dart` | `pluginKernelProvider` (ChangeNotifierProvider) and the global `pluginKernel` accessor for non-Riverpod code |
| `lib/presentation/plugins/plugin_slot.dart` | `PluginSlot` widgets for every presentation, `PluginReplaceable`, `PluginBuiltins` (hide/order/rename built-ins) |
| `lib/presentation/plugins/plugin_ui.dart` (edit) | keep existing API; add JSON UI pages, sheets, dialogs, extended commands |
| `lib/presentation/plugins/plugin_ui_renderer.dart` | JSON UI renderer |
| `lib/presentation/plugins/plugin_icons.dart` | icon registry (all Material icons by name, plus plugin files) |
| `android/.../plugins/DexPluginHost.kt`, `api/ImmichPlugin.kt` (edit) | view composition option, host API v2 additions (default methods, source compatible) |

### 3.1 PluginKernel API (Dart)

```dart
class PluginKernel extends ChangeNotifier {
  // ---- contributions -------------------------------------------------------------
  List<SlotContribution> slot(String slotId, {Map<String, dynamic> context = const {}});   // filtered by `when`
  BuiltinRules builtins(String slotId);           // hide / order / rename rules for built-in items in that slot
  List<ToolContribution> tools(String surface);   // e.g. 'editor.image', 'editor.video'
  List<TabContribution> get tabs;
  List<SettingsContribution> get settingsPages;
  ThemeOverride? get themeOverride;               // merged from all plugins (last enabled wins per key)
  Map<String, String> strings(String locale);     // translation overrides

  // ---- hooks: the "patch" mechanism ----------------------------------------------
  bool hasHook(String hookId);
  /// Runs [original] wrapped by every plugin hook registered for [hookId].
  /// before:  plugin may return {"cancel": true, "message"?} -> throws PluginCancelled (callers show message if any)
  ///          or {"args": {...}} -> replaces args (shallow merge) for later hooks and the original.
  /// instead: first plugin (by priority) returning {"result": x} replaces the original; {"fallthrough": true} or null
  ///          continues to the next / the original.
  /// after:   receives {"args", "result"}; may return {"result": y} to replace the result.
  Future<T> run<T>(String hookId, Map<String, dynamic> args, Future<T> Function(Map<String, dynamic> args) original,
      {Object? Function(T value)? encode, T Function(Object? json)? decode});
  /// Fire-and-forget variant for synchronous call sites (void actions): before/instead/after still apply.
  void runVoid(String hookId, Map<String, dynamic> args, FutureOr<void> Function(Map<String, dynamic> args) original);

  // ---- events ---------------------------------------------------------------------
  /// Delivers to plugins whose manifest `events` match the name exactly, by prefix pattern ("asset.*") or "*".
  /// Never blocks the caller; high-frequency events (declared "throttle" in the catalog) are rate limited.
  void emit(String event, Map<String, dynamic> data);

  // ---- host functions -------------------------------------------------------------
  void registerHost(String name, HostFunction handler, {String? doc});   // name: "<namespace>.<verb>" or legacy names
  // HostFunction = Future<Object?> Function(String plugin, List<dynamic> args)

  // ---- calling plugins --------------------------------------------------------------
  Future<Map<String, dynamic>?> call(String plugin, String method, String type, Map<String, dynamic> data,
      {Map<String, dynamic> config = const {}, Duration? timeout});
  Future<Map<String, dynamic>> assetJson(BaseAsset asset);   // AssetV1 for local AND remote assets
  Future<void> perform(String plugin, Map<String, dynamic>? response, {BuildContext? context}); // message/actions/ui
}
```

`PluginCancelled` is an exception type with an optional user message. Every call site that runs a cancellable hook
catches it and shows the message (snackbar) if present.

### 3.2 Manifest v2 (additions; everything optional)

```json
"contributes": {
  "slots": [
    { "id": "upscale", "slot": "viewer.topBar", "kind": "button", "title": "Upscale", "icon": "auto_fix_high",
      "method": "onUpscale", "order": 50, "when": { "assetType": "IMAGE" } },
    { "id": "info", "slot": "viewer.info.sections", "kind": "section", "uiMethod": "infoSection" },
    { "id": "badge", "slot": "timeline.tile", "kind": "badge", "uiMethod": "tileBadge", "when": { "isVideo": true } },
    { "id": "tile", "slot": "timeline.tile", "kind": "replace", "view": "myTile" }
  ],
  "builtins": { "viewer.topBar": { "hide": ["favorite"], "order": ["share", "plugin:my-plugin/upscale"] } },
  "hooks": { "asset.delete": { "before": "confirmDelete", "priority": 10, "timeoutMs": 30000 },
             "image.thumbnail": { "instead": "censorThumb" } },
  "events": { "asset.*": "onAssetEvent", "app.start": "onStart" },
  "tools": [ { "id": "upscale", "surface": "editor.image", "title": "Upscale", "icon": "auto_awesome",
               "method": "upscaleTool" } ],
  "tabs": [ { "id": "stats", "title": "Stats", "icon": "insights", "uiMethod": "statsPage", "order": 99 } ],
  "settings": { "title": "My plugin", "uiMethod": "settingsPage" },
  "theme": { "seedColor": "#FF4150AF", "dark": { "primary": "#FFACCBFA" }, "light": {}, "fontFamily": null },
  "strings": { "en": { "favorites": "Hearts" } },
  "buttons": [], "pages": [], "overlays": [], "routes": {}
}
```

Slot `kind`s: `button` (icon button), `menuItem` (overflow menu entry), `tile` (list tile), `section` (a block of UI in
a page or sheet), `chip`, `badge` (decoration on a thumbnail or icon), `panel` (side or bottom panel), `tab`,
`view` (native view), `overlay`, `page` (Plugins page and settings entries), `replace` (replaces the slot's built-in
content), `wrap` (decorates it: rendered in a Stack over it).
Content comes from one of: static fields (`title`, `subtitle`, `icon`), `ui` (static JSON UI tree), `uiMethod`
(plugin method returning `{ "ui": tree }`, called with the slot context, cached per context until `refresh`), or
`view` (native view; `"composition": "hybrid"` selects Hybrid Composition instead of texture layer).
`when` matches slot context fields: exact values, lists (any of), `{ "not": ... }`, and the special keys
`route`, `assetType`, `isVideo`, `isImage`, `isLocal`, `isRemote`, `isFavorite`, `selectionCount`, `platform`.

### 3.3 Calls into plugins (new `type`s)

| type | When | data | response |
| --- | --- | --- | --- |
| `SlotV1` | slot item tapped / `uiMethod` content requested | `{ "slot", "id", "context", "assets"? }` | `{ "ui"?, "message"?, "actions"? }` |
| `HookV1` | hook phase | `{ "hook", "phase": "before"|"instead"|"after", "args", "result"? }` | see 3.1 |
| `EventV1` | event (existing) | `{ "event", ... }` | `{ "message"?, "actions"? }` |
| `UiEventV1` | JSON UI interaction | `{ "surface", "event", "id", "value", "state", "context" }` | `{ "ui"?, "state"?, "message"?, "actions"?, "close"?: result }` |
| `PageV1` | JSON UI page/tab/settings opened | `{ "page", "params" }` | `{ "ui", "title"? }` |
| `EditorToolV1` | editor tool | `{ "phase": "panel"|"preview"|"apply", "tool", "source": { "path", "width", "height", "format": "rgba"|"encoded" }, "state" }` | panel: `{ "ui" }`; preview/apply: `{ "image": { "path", "width", "height", "format" } }` (size may differ from the source) |
| existing | `AssetV1`, `ButtonV1`, `AssetActionV1`, `CensorStyleV1`, `ViewerFilterV1`, `GalleryViewV1` | unchanged | unchanged |

### 3.4 JSON UI

A node is `{ "type": "...", "id"?: "...", ...props, "children"?: [...] }`, rendered with the app's Theme so plugin UI
looks native. Required node types:

layout: `column`, `row`, `stack`, `wrap`, `padding`, `center`, `align`, `expanded`, `flexible`, `sizedBox`, `container`
(color, radius, border, padding, margin, gradient), `card`, `scroll`, `list` (lazy), `grid` (columns or maxExtent),
`divider`, `spacer`, `safeArea`;
content: `text` (style token `displayLarge`…`labelSmall`, color, weight, maxLines, align, selectable), `icon`,
`image` (`file`, `url`, `base64`, fit), `assetThumbnail` (`assetId`), `assetImage` (full image), `progress`
(linear/circular, value or indeterminate), `badge`, `avatar`, `tooltip`, `nativeView` (`view`, `params`, `height`,
`composition`);
input: `button` (`style`: filled/tonal/outlined/text/elevated; `icon`, `label`, `action`), `iconButton`, `fab`,
`listTile` (title, subtitle, leading, trailing, action), `switch`, `checkbox`, `radio`, `slider` (min, max, divisions,
label), `rangeSlider`, `textField` (hint, label, multiline, keyboard, obscure), `dropdown`, `segmented`, `chip`,
`choiceChips`, `filterChips`, `colorPicker`, `datePicker` field, `expansionTile`, `tabs`.
Values: colors `#AARRGGBB` or theme tokens (`primary`, `onPrimary`, `primaryContainer`, `surface`,
`surfaceContainer`, `surfaceContainerHigh`, `onSurface`, `onSurfaceVariant`, `outline`, `error`, ...).
Actions: `"action": { "method": "name", "params": {} }` calls the plugin with `UiEventV1`; or
`"action": { "command": { ...command } }` runs a command directly. Inputs carry an `id`; the renderer keeps their
current values and sends them all as `state` with every event; `onChange` on an input sends `event: "change"`
(debounced 250 ms for text and sliders). A response's `ui` replaces the tree; `state` replaces input values.

### 3.5 Commands (extended)

Existing: `toast`, `openUrl`, `openPage`, `closePage`/`back`, `navigate`, `showOverlay`, `hideOverlay`, `refresh`,
`routes`. New: `openUiPage` (`page`, `title`, `params`; JSON UI), `dialog` / `sheet` (`ui`, `title`, `actions`;
returns the chosen value or `close` result), `confirm` (`title`, `message`; returns bool), `snackbar`
(`message`, `action`), `pickAssets` (multi-select picker; returns AssetV1 list), `pickAlbum`, `pickDate`,
`openAsset` (viewer at an asset), `openAlbum`, `select` / `clearSelection`, `refreshSlots` (one slot id), `setTheme`,
`haptic`, `copy` (clipboard), `share` (text, files or assets).

### 3.6 Host functions

`kernel.registerHost` makes every function callable with `host.callHost(name, argsJson)`. Existing names stay. New
names are namespaced (`assets.*`, `albums.*`, `tags.*`, `people.*`, `search.*`, `timeline.*`, `viewer.*`, `video.*`,
`editor.*`, `nav.*`, `settings.*`, `theme.*`, `strings.*`, `db.*`, `files.*`, `net.*`, `backup.*`, `sync.*`,
`notify.*`, `ui.*`, `app.*`, `plugins.*`). The kernel itself registers `plugins.list`, `plugins.call` (one plugin
calling another), `app.info`, `ui.*` wrappers for every command, `kernel.slots`, `kernel.hooks`, `kernel.events`
(introspection: what exists and is documented).

### 3.7 Native (Kotlin) additions in phase 1

- Plugin views: `composition` param; `"hybrid"` uses `PlatformViewLink` + `initExpensiveAndroidView` on the Dart side.
- `PluginHost` gains, as interface default methods so existing plugins compile and run unchanged:
  `fun callHostAsync(name: String, argsJson: String, callback: (String) -> Unit)` and
  `fun emit(event: String, payloadJson: String)` (plugin-originated events other plugins can subscribe to).
  Phase 2 (native area) adds the rest.

## 4. Naming conventions

- Slots: `<surface>.<part>`; pages use their route name in lower camel case without `Route`, e.g.
  `mainTimeline.appBar.actions`, `mainTimeline.appBar.menu`, `albumOptions.sections`, `settings.sections`.
  Generic suffixes every page gets: `.appBar.actions` (buttons), `.appBar.menu` (overflow menu items),
  `.header`, `.footer`, `.empty` (replaces or adds to the empty state), `.fab`, `.body` (`replace`/`wrap` the body).
- Built-in item ids: short stable names (`share`, `favorite`, `delete`, `edit`, ...) listed per slot in the catalog.
- Hooks: `<domain>.<verb>`: `asset.favorite`, `asset.delete`, `album.create`, `nav.push`, `settings.set`,
  `upload.asset`, `image.thumbnail`, `action.<actionId>` for UI actions.
- Events: `<domain>.<pastTense>` or `<domain>.<noun>Changed`: `asset.favorited`, `asset.deleted`,
  `selection.changed`, `viewer.opened`, `video.position` (throttled 4/s), `route.changed` (existing),
  `app.resumed`.

## 5. Areas and file ownership (phase 2)

Each agent edits **only** files in its area plus its own new files and its own
`lib/infrastructure/plugins/plugin_api/<area>_plugin_api.dart` and `docs/plugins/<area>.md`. Kernel files belong to
nobody in phase 2: if a kernel change is needed, implement a local adapter in your area and report the need.
If a hook point is needed in another area's file, report it (file, line, what) instead of editing.

| Area | Owns |
| --- | --- |
| **viewer** (viewer, video, images, memories, slideshow) | `lib/presentation/widgets/asset_viewer/**`, `lib/presentation/widgets/images/**`, `lib/presentation/widgets/slideshow/**`, `lib/presentation/widgets/memory/**`, `lib/presentation/pages/{video,slideshow,memory,memory_list}.page.dart`, `lib/widgets/asset_viewer/**`, `lib/widgets/photo_view/**`, `lib/widgets/memories/**`, `lib/providers/asset_viewer/**`, `lib/providers/infrastructure/asset_viewer/**`, `lib/infrastructure/loaders/**`, `lib/infrastructure/plugins/viewer_filter.dart`, `lib/providers/viewer_censor.provider.dart` |
| **editor** | `lib/presentation/pages/edit/**`, `lib/presentation/actions/edit_asset.action.dart`, `lib/infrastructure/repositories/device_edit.repository.dart`, `lib/utils/asset_edit_renderer.utils.dart`, `lib/utils/censor_geometry.dart`, `lib/infrastructure/plugins/censor_styles.dart` |
| **timeline** (timeline, selection, actions, tabs) | `lib/presentation/widgets/{timeline,action_buttons,bottom_sheet,sliver_app_bar,gallery_view}/**`, `lib/presentation/actions/**` (except `edit_asset.action.dart`), `lib/presentation/pages/{archive,favorite,recently_added,recently_taken,local_timeline,trash,asset_selection_timeline,cleanup_preview}.page.dart`, `lib/presentation/pages/{trash,picker,dev}/**`, `lib/pages/common/tab_shell.page.dart`, `lib/providers/timeline/**`, `lib/providers/infrastructure/timeline.provider.dart`, `lib/domain/services/timeline.service.dart`, `lib/widgets/asset_grid/**` |
| **library** (albums, people, places, map, search, folders, partners, shared links, locked/private) | `lib/presentation/pages/{album,album_options,app_album,create_album,library,local_album,remote_album,people_collection,person,place,place_detail,map,partner_detail,user_selection,activities,download_info,locked_folder}.page.dart`, `lib/presentation/pages/{private,search}/**`, `lib/presentation/widgets/{album,remote_album,people,search,map}/**`, `lib/pages/library/**`, `lib/pages/search/**`, `lib/widgets/{album,map,search,activities,shared_link}/**`, `lib/providers/{album,search,map}/**` |
| **shell** (app shell, settings, backup/sync UI, auth, theme, strings, logs, share intent, profile) | `lib/main.dart`, `lib/pages/common/**` (except `tab_shell.page.dart`), `lib/pages/{settings,backup,login,share_intent}/**`, `lib/widgets/{settings,backup,forms,common}/**`, `lib/presentation/widgets/{backup,feature_message}/**`, `lib/presentation/pages/{profile,feature_message}/**`, `lib/presentation/widgets/downloads_rule_dialog.widget.dart`, `lib/theme/**`, `lib/routing/**`, `lib/providers/{backup,view_intent}/**`, `lib/providers/theme.provider.dart`, `lib/providers/locale_provider.dart`, `lib/providers/app_settings.provider.dart` |
| **data** (services, repositories, sync, upload, network, database, store) | `lib/domain/services/**` (except `timeline.service.dart`), `lib/domain/utils/**`, `lib/infrastructure/repositories/**` (except `device_edit.repository.dart`), `lib/infrastructure/utils/**`, `lib/data/**`, `lib/repositories/**`, `lib/services/**`, `lib/models/**`, `lib/entities/**`, `lib/extensions/**`, `lib/utils/**` (except the two editor files), `lib/providers/infrastructure/**` (except timeline/asset_viewer), remaining `lib/providers/*.dart` not owned above |
| **native** (Android plugin host) | `android/app/src/main/kotlin/**`, `android/app/src/main/AndroidManifest.xml`, `android/app/proguard-rules.pro` |

Phase 1 (kernel) owns `lib/infrastructure/plugins/**` (except the three files handed to viewer/editor above),
`lib/presentation/plugins/**`, `lib/presentation/pages/plugins/**`, `lib/domain/models/device_plugin.model.dart`,
`lib/domain/plugins/**`, `lib/providers/device_plugins.provider.dart`, `lib/providers/plugin_kernel.provider.dart`,
`lib/routing/app_navigation_observer.dart`, the plugin lines of `lib/main.dart`, the Kotlin plugin host, `PLUGINS.md`.

## 6. Hook placement rules

- UI actions: every `ActionBuilder`/`ActionItem` gets an id; `onAction` runs through `kernel.run('action.<id>', ...)`
  with the selected assets as AssetV1, and the action list in every surface is filtered by `PluginBuiltins` so plugins
  can hide/reorder built-ins and add their own (`menuItem`/`button` slot contributions) in the same bar or menu.
- Data mutations: every service method that changes data (assets, albums, tags, people, settings, edits, trash,
  locked folder, stacks, uploads, downloads, sync) runs through a hook at the service layer (`asset.update`,
  `asset.delete`, ...), and emits the matching event after success.
- Queries: timeline, search, album lists, people, places and map markers run through hooks whose `after` phase can
  filter, sort or extend results (`timeline.query`, `search.query`, ...).
- Media: thumbnail and full image loading (`image.thumbnail`, `image.full`), video source (`video.source`) and
  playback state (events and `video.*` host functions) are hookable.
- Navigation: `nav.push` (`before` can redirect or cancel), `route.changed` event (existing).
- Network: every server API call (`net.request` hook with method, url, headers, body) if the app talks to a server.
- Settings: `settings.set` hook and `settings.changed` event for every Store key and app setting; `settings.get` and
  `settings.set` host functions with the full key list.

## 7. Delivery order

1. Phase 1 kernel (one agent). Analyzer clean. Existing censor/gallery plugins keep working.
2. Phase 2 areas (seven agents in parallel), each analyzer-clean on its own files.
3. Phase 3: audit against section 8, fix gaps, merge `docs/plugins/*.md` into `PLUGINS.md`, full analyzer run,
   commit, push. No APK build.

## 8. Coverage checklist (definition of done)

For **every route** in `lib/routing/router.dart` (66 route entries): `<page>.appBar.actions`, `<page>.appBar.menu` (where the
page has or can have an overflow menu: add one if it has an app bar), `<page>.header`, `<page>.footer`,
`<page>.empty` where an empty state exists, `<page>.body` (`replace`/`wrap`), page-specific slots for every list,
sheet and panel on the page, built-in ids for every existing button and menu item, route override (existing).

For **every action** in `lib/presentation/actions/`: a hook `action.<id>`, a built-in id in every bar or menu it
appears in, and plugin items possible in those same bars and menus (viewer top bar, viewer ⋮ menu, viewer bottom bar,
selection bottom sheet, album/timeline app bars).

For **every domain service and repository method that mutates data**: a hook and an event.
For **every query the UI shows**: an `after` hook able to change the results.
Viewer: top bar, ⋮ menu, bottom bar, info/details sheet sections, overlays (exists), gestures (`viewer.gesture`
hook: tap, double tap, long press, swipe up/down), page change events, video player control and position.
Editor: plugin tools in the tool selector (any output size, so upscalers work), plugin panels, save hook
(`editor.save`), built-in tool ids hideable.
Timeline: tile badges/wrap/replace, header slots, scrubber labels, group headers, selection bar, empty state,
query hooks (filter/sort/group), multi-select actions.
Shell: bottom navigation tabs (plugin tabs), app bar profile menu items, settings page sections and plugin settings
pages, theme override, string override, splash, login, backup/sync pages, logs (plugins can write app logs and read
them), share intent hook, notifications.
Data: raw database read/write, every Store key, files, network, backup/sync control, upload hooks.
Native: activity lifecycle, intents (incoming share/view intents), permissions, notifications, background work,
MediaStore writes, fast host calls.

## 9. Catalog format (`docs/plugins/<area>.md`)

For each slot: id, kinds supported, context fields, built-in item ids. For each hook: id, args JSON, result JSON,
cancellable or not. For each event: name, payload JSON, throttling. For each host function: name, args, result.
Keep entries terse; this becomes `PLUGINS.md`.

## 10. Generic capabilities (no workarounds, no half-working surfaces)

Everything today's plugins do must be possible through first-class, fully working APIs that **any** plugin can use.
Where a plugin needed a workaround, the capability is built into the app now, generically:

| Today's workaround (censor plugin and others) | Generic capability built into the app | Owner |
| --- | --- | --- |
| Censor while viewing: `ViewerFilterV1` regions plus a fake brush style (`viewerRender`) to hand back a whole image | **Image pipeline hooks** `image.full`, `image.preview`, `image.thumbnail`: any plugin may transform or replace any displayed image (receives decoded pixels as an RGBA file plus asset and size; returns an image or "unchanged"); results cached per asset/size/plugin version; the viewer shows the app's placeholder while waiting. `ViewerFilterV1` keeps working on top of this. | viewer |
| Live video censoring: searching the activity's view tree for the player's `SurfaceView`, inserting a view into the platform view, PixelCopy, reading playback state indirectly | **Video sessions**: every playing video is a session with an id, asset, frame rect on screen, position/state events (`video.position` throttled, `video.state`), control host functions (play, pause, seek, speed, volume), **frame capture** at any size from the real player (native side gets the player view with `PlatformViewsController.getPlatformViewById(viewId)` and copies it), and two **overlay layers** placed exactly over the video frame: a declarative layer (shapes, images, text, with per-item velocity and validity window, eased and extrapolated by the app against its own playback clock) and a native overlay view slot inside the player container (correct z-order, size and lifecycle). | viewer (Dart, declarative layer, session model), native (frame capture, native overlay slot) |
| Reading the app's SQLite database to learn whether the viewer shield is on | **Toggles**: a slot kind `toggle` (icon on/off, persisted by the app, per plugin and id) usable anywhere (viewer top bar, app bars, settings); read/write with `toggles.get/set`, event `toggle.changed`. The built-in viewer censor shield becomes a toggle on the same mechanism and its state is readable and settable by plugins. | kernel (mechanism), viewer (shield) |
| Settings built as hand-made native dialogs and windows because embedded views did not work well | **Plugin settings and pages in JSON UI** rendered by Flutter with the app theme, listed in Settings and on the Plugins page; nested pages with back; every input the censor settings needed (sections, collapsible groups, chips, sliders with live value, switches, color picker with RGB/hex/presets, text fields, previews); **plugin-pushed live updates** (`ui.update(surface, tree)` / partial `ui.patch`) for status lines and progress | kernel, shell (Settings entries) |
| Drawing areas on a photo or a video frame in a hand-made native dialog | **Region and drawing input** JSON UI nodes: `regionEditor` (draw, move, resize, delete boxes or ellipses over an asset image or a video frame at a time, with a scrubber for videos) and `canvas` (freehand strokes, points), returning normalized shapes; `image.load(assetId, {size, timeMs, format})` for photos and video frames | kernel (nodes), viewer (`image.load` incl. video frames) |
| Native plugin views with rendering, touch and keyboard problems | **Platform views done properly**: choose composition (`hybrid` or texture), interactive views get eager gesture forwarding, keyboard/focus works, plugins can report their content height for inline views, the app passes theme info (dark/light, colour scheme, font) in params, lifecycle callbacks | kernel (Dart), native (Kotlin) |
| Model downloads, upscaling and other long jobs with hand-made progress text | **Tasks**: `tasks.start(title, {cancellable, progress})` shows app-native progress (in-app indicator and notification), `tasks.update/finish`, cancel delivered as an event; **downloads** helper `files.download(url, {sha256, path})` with progress events, resume and checksum | kernel (tasks UI), data (downloads), native (notification) |
| Plugin-specific per-photo data kept in private JSON files | **Per-asset plugin data**: `assetData.get/set/delete/list(assetId, key)` per plugin, plus events when assets are deleted so data can be cleaned | kernel |
| Saving results (censored copy, upscaled image) through ad-hoc paths | **Media writes**: `media.saveImage/saveVideo` (new item, folder, name) and `media.replace(assetId, ...)` (with original backup), used by the editor and any plugin | data (Dart host functions), native (MediaStore) |

These capabilities are part of the coverage checklist (section 8). When a capability is useful beyond its first user, it
is exposed generically; nothing is special-cased for one plugin.
