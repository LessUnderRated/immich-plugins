# Plugins

Plugins are native Android code (Java or Kotlin compiled to `classes.dex`), loaded at runtime with `DexClassLoader`,
the same way Aliucord loads plugins. They run inside the app with its full permissions. There is no sandbox.

The app is built around a **plugin kernel** (`lib/infrastructure/plugins/plugin_kernel.dart`). Plugins reach the app
through five mechanisms, all declared in the manifest or called at runtime:

| Mechanism | What it does |
| --- | --- |
| **Slots** | Add buttons, menu items, tiles, sections, chips, badges, panels, toggles, tabs, views and overlays to any surface; replace or wrap built-in widgets; hide, reorder and rename built-in items. |
| **Hooks** | `before` / `instead` / `after` handlers around app operations (the equivalent of Aliucord patches): cancel, change arguments, replace, change results. |
| **Events** | Subscribe to state changes (exact names, `prefix.*`, `*`), emit your own. |
| **Host functions** | Everything the app can do, callable with `host.callHost(name, argsJson)`. |
| **UI** | JSON UI rendered natively with the app theme (pages, dialogs, sheets, settings, sections, live updates) or native Android views. |

Manifest v1 plugins keep working unchanged: `buttons`, `pages`, `overlays`, `events`, `routes` and the v1 call types.

## Package

A plugin is a zip installed from the Plugins page (+) or dropped into the plugin drop folder
(`Android/data/<app>/files/plugins`, then the folder button):

```
manifest.json            required
classes.dex              required (or the file named by "dexPath")
lib/<abi>/*.so           optional native libraries (arm64-v8a, armeabi-v7a, x86_64)
anything/else            optional files (models, icons, fonts, data)
```

Every file other than `manifest.json` and the dex is extracted to the plugin's folder (`PluginHost.pluginDir`). Native
libraries for the phone's ABI are put on the plugin class loader's library path, so `System.loadLibrary` works.

## Manifest

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "title": "My Plugin",
  "description": "What it does",
  "author": "you",
  "runtime": "dex",
  "entry": "com.example.MyPlugin",
  "dexPath": "classes.dex",
  "methods": [ ... ],
  "templates": [ ... ],
  "contributes": {
    "slots": [ ... ],
    "builtins": { ... },
    "hooks": { ... },
    "events": { ... },
    "tools": [ ... ],
    "tabs": [ ... ],
    "settings": { ... },
    "theme": { ... },
    "strings": { ... },
    "buttons": [ ... ], "pages": [ ... ], "overlays": [ ... ], "routes": { ... }
  }
}
```

`name` uses lowercase letters, digits and `-`. `runtime` must be `"dex"`. `entry` is the class the app instantiates;
it needs a public no-argument constructor. Everything under `contributes` is optional. `methods` describes methods for
workflows and the v1 types (`types`, `uiHints`, `schema`, `hostFunctions`, `pixels`); methods used only by slots,
hooks, events and UI do not need to be listed.

A complete v2 example:

```json
"contributes": {
  "slots": [
    { "id": "upscale", "slot": "viewer.topBar", "kind": "button", "title": "Upscale", "icon": "auto_fix_high",
      "method": "onUpscale", "order": 50, "when": { "assetType": "IMAGE" } },
    { "id": "hud", "slot": "viewer.topBar", "kind": "toggle", "icon": "visibility_off", "activeIcon": "visibility",
      "title": "Show HUD", "default": false },
    { "id": "info", "slot": "viewer.info.sections", "kind": "section", "uiMethod": "infoSection" },
    { "id": "badge", "slot": "timeline.tile", "kind": "badge", "icon": "star", "alignment": "topLeft",
      "when": { "isVideo": true } },
    { "id": "stats", "slot": "plugins.page", "kind": "page", "title": "Statistics", "icon": "insights",
      "uiMethod": "statsPage" }
  ],
  "builtins": { "viewer.topBar": { "hide": ["favorite"], "order": ["share", "plugin:my-plugin/upscale", "*"],
                                   "rename": { "edit": "Adjust" } } },
  "hooks": { "asset.delete": { "before": "confirmDelete", "priority": 10, "timeoutMs": 30000 },
             "timeline.query": { "after": "filterTimeline", "when": { "scope": "main" } } },
  "events": { "asset.*": "onAssetEvent", "app.start": "onStart",
              "video.position": { "method": "onPosition", "throttleMs": 500 } },
  "tools": [ { "id": "upscale", "surface": "editor.image", "title": "Upscale", "icon": "auto_awesome",
               "method": "upscaleTool" } ],
  "tabs": [ { "id": "stats", "title": "Stats", "icon": "insights", "uiMethod": "statsPage", "order": 99 } ],
  "settings": { "title": "My plugin", "icon": "tune", "uiMethod": "settingsPage" },
  "theme": { "seedColor": "#FF4150AF", "dark": { "primary": "#FFACCBFA" }, "light": {}, "fontFamily": null },
  "strings": { "en": { "favorites": "Hearts" } }
}
```

## Java/Kotlin API

Compile against these interfaces (package `app.alextran.immich.plugins.api`). Do not put them in your dex; the app
provides them.

```kotlin
interface ImmichPlugin {
  fun call(method: String, input: String, host: PluginHost): String?   // JSON in, JSON out
}

interface ImmichViewPlugin {                                            // optional
  fun createView(context: Context, viewType: String, params: String, host: PluginHost): View
}

interface ImmichViewLifecycle {                                         // optional
  fun onViewDisposed(viewType: String, view: View)
}

fun interface HostCallback {                                            // v2
  fun onResult(resultJson: String)
}

interface PluginHost {
  val context: Context            // application context
  val activity: Activity?         // the app's activity: dialogs, popups, startActivity, permissions
  val dataDir: File               // private storage for this plugin (native side)
  val pluginDir: File             // files shipped in the zip (models, icons, ...)
  val pluginName: String
  fun callHost(name: String, argsJson: String): String   // blocking host call (never on the UI thread)
  fun runOnUi(block: Runnable)
  fun sendEvent(name: String, payloadJson: String)        // app commands, see "Commands"

  // v2, with default implementations (plugins built against v1 keep loading)
  val hostApiVersion: Int                                  // 2 in this app
  fun callHostAsync(name: String, argsJson: String, callback: HostCallback)   // any thread, result on a worker
  fun emit(event: String, payloadJson: String)            // plugin event on the app's event bus
}
```

`call` runs on a background thread; calls into one plugin may run concurrently (a `cancel` call can arrive while a long
`apply` call still runs). Touch views only through `runOnUi` or `activity.runOnUiThread`. An exception thrown from
`call` is returned to the app as a failed call; for buttons it is shown to the user. `callHost` from the UI thread
returns status 409 immediately (it would deadlock): use `callHostAsync` there.

**Java plugins**: the app is built with Kotlin 2.2 (`-jvm-default=enable` is the default; the build sets no
`-Xjvm-default`), so the v2 methods are real JVM default methods of `PluginHost` and Java code calls them directly.
If you compile against hand-written stub interfaces, add them to your stub, e.g.
`default void callHostAsync(String name, String argsJson, HostCallback callback) {}` and
`default void emit(String event, String payloadJson) {}` plus `@FunctionalInterface interface HostCallback { void
onResult(String resultJson); }` (stub bodies never run; the app's implementation does). Without updated stubs, the same
features are reachable as host functions: `callHost("events.emit", "[\"my.event\", {...}]")`.

Build:

```sh
javac --release 11 -cp "$ANDROID_HOME/platforms/android-36/android.jar:api-stubs" -d out $(find src -name '*.java')
$ANDROID_HOME/build-tools/36.0.0/d8 --release --min-api 26 --lib $ANDROID_HOME/platforms/android-36/android.jar \
  --output . $(find out -name '*.class' ! -path '*/plugins/api/*') [extra.jar ...]
zip -r my-plugin.zip manifest.json classes.dex lib models
```

## Calls into the plugin

`call(method, input)` receives JSON shaped as:

```json
{ "type": "<kind>", "config": { ... }, "workflow": { "id": "...", "authToken": "", "stepId": "..." }, "data": { ... } }
```

`config` is the slot item's / button's `params` (or the workflow step config). Return a JSON object (or nothing).

| `type` | When | `data` | Response |
| --- | --- | --- | --- |
| `AssetV1` | workflow step for each new photo | `{ "asset": AssetV1 }` | `{ "workflow": { "continue": false } }` to stop, `{ "changes": { "asset": { "isFavorite": true } } }` |
| `ButtonV1` | v1 button / page tapped | `{ "slot", "assets": [AssetV1] }` | optional `{ "message", "actions": [command] }` |
| `SlotV1` | slot item tapped / toggled, or `uiMethod` content requested | `{ "slot", "id", "event": "tap" \| "toggle" \| "content", "value"?, "context", "surface", "assets"? }` | tap: `{ "ui"?, "message"?, "actions"? }` (`ui` opens as a sheet); content: `{ "ui": tree }` |
| `HookV1` | hook phase | `{ "hook", "phase": "before" \| "instead" \| "after", "args", "result"? }` | see "Hooks" |
| `EventV1` | event | `{ "event", ...payload, "source"? }` | optional `{ "message", "actions", "ui" }` |
| `UiEventV1` | JSON UI interaction | `{ "surface", "event", "id", "value", "state", "context", "page", "params" }` | `{ "ui"?, "state"?, "message"?, "actions"?, "title"?, "appBarActions"?, "fab"?, "close"? }` |
| `PageV1` | JSON UI page, tab or settings page opened | `{ "page", "params", "surface", "context" }` | `{ "ui", "title"?, "state"?, "appBarActions"?, "fab"? }` |
| `EditorToolV1` | editor tool | `{ "phase": "panel" \| "preview" \| "apply" \| "cancel", "tool", "source": { "path", "width", "height", "format" }, "state" }` | panel: `{ "ui" }`; preview / apply: `{ "image": { "path", "width", "height", "format" } }` (see the editor catalog) |
| `PluginCallV1` | another plugin called you (`plugins.call`) | caller's data plus `"from"` | any JSON |
| `AssetActionV1` | v1 selection action | `{ "assets": [AssetV1] }` | optional `{ "message" }` |
| `CensorStyleV1` | mosaic brush style | `{ "width", "height", "size", "grid": { "width", "height", "cell", "rgba": base64 }, "source"?: { "path", "width", "height", "format": "rgba" } }` (source only with `"pixels": true`) | `{ "tiles": { "polygons", "a", "b" } }`, `{ "cells": { "grid": { "size", "jitter" }, "borders"? } }`, `{ "shapes": [...] }`, `{ "blur": radius }` or `{ "image": { "path" or "rgba", "width", "height" } }` |
| `ViewerFilterV1` | photo/video opened with the shield on | image: `{ "kind": "image", "source": { "path", "width", "height", "format": "rgba" } }`; video: `{ "kind": "video", "source": { "path" }, "fromMs", "toMs", "stepMs" }` | image: `{ "regions": [{ "x", "y", "width", "height", "shape" }], "style"?, "styleOptions"?, "size"? }`; video: `{ "frames": [{ "timeMs", "regions" }] }` (0–1 coordinates) |
| `GalleryViewV1` | gallery view settings applied | `{ "scope": "main" \| "album", "albumId"?, "albums": [{ "id", "name" }] }` | `{ "view": { "sort": { "field", "direction" }, "include": { "photos", "videos", "gifs" }, "excludeAlbumIds" } }` |

**AssetV1** is the Immich asset JSON (`id`, `type`, `originalFileName`, `originalPath`, `isFavorite`, `visibility`,
`checksum`, `fileCreatedAt`, `localDateTime`, `duration`, `tags`, `exifInfo`, ...) for local **and** remote assets,
plus `isLocal`, `isRemote`, `localId`, `remoteId`, `width`, `height`, `durationMs`, `isEdited`, `storage`
(`local` / `remote` / `merged`); remote assets add `ownerId`, `thumbhash`, `stackId`, `uploadedAt`, `isTrashed`,
`isArchived`, `isLocked` and their exif.

## Slots

A slot is a named place in the UI. Plugins add items with `contributes.slots` (or at runtime with `slots.add`):

| Field | Meaning |
| --- | --- |
| `id` | item id, unique in the plugin; in builtins rules it is `plugin:<plugin>/<id>` |
| `slot` | slot id (see the catalog; naming below) |
| `kind` | `button`, `menuItem`, `tile`, `section`, `chip`, `badge`, `panel`, `tab`, `view`, `overlay`, `page`, `replace`, `wrap`, `toggle` |
| `title`, `subtitle`, `tooltip`, `icon` | static content; `icon` is a Material icon name or a file in the zip |
| `method` | called with `SlotV1` on tap (`toggle`: after the app flipped the state, `event: "toggle"`, `value`) |
| `ui` / `uiMethod` | JSON UI content: static tree, or a method returning `{ "ui": tree }` for `SlotV1` `event: "content"` (cached per slot, plugin, item and context until `refreshSlots`) |
| `view`, `composition`, `height`, `interactive` | native view content (see "Native views") |
| `order` | position among built-ins (built-in `i` has `(i + 1) * 100`; default: after them) |
| `when` | condition on the slot context (below) |
| `params` | sent as `config` |
| `alignment`, `position` | badges and overlays: `topLeft` ... `bottomRight`, or `{ left, top, right, bottom, width, height }` |
| `activeIcon`, `activeTitle`, `default` | toggles |
| `destructive` | menu items shown in the error color |
| `surface` | surface id of the item's JSON UI (default `slot:<slot>/<id>`, plus `#<assetId>` for one-asset contexts) |

Without `kind`, items with `view` are `view`, items with `ui` / `uiMethod` are `section`, others `button`. An item with
neither `method` nor content opens its `view` (native page) or `ui` / `uiMethod` (JSON UI page) when tapped.

The call site decides how a slot is presented; each presentation renders the kinds that fit it: icon-button rows
(`button`, `toggle`), menus (`menuItem`, `button`, `toggle`, `page`), tile lists (`tile`, `page`, `button`,
`menuItem`, `toggle` as a switch), content areas (`section`, `panel`, `view`), chip rows (`chip`, `button`, `toggle`
as a filter chip). Replaceable widgets take `replace` (renders instead of the built-in), `wrap` (drawn over it) and
`badge` (a small decoration in a corner).

**Slot names**: `<surface>.<part>`; pages use their route name in lower camel case without `Route`
(`MainTimelineRoute` → `mainTimeline`). Every page gets `<page>.appBar.actions`, `<page>.appBar.menu`, `<page>.header`,
`<page>.footer`, `<page>.empty`, `<page>.fab`, `<page>.body` (`replace` / `wrap`); page-specific slots are in the
catalog. Overlays use `global` (every screen), `route:<RouteName>` and `viewer.overlay` / `viewer`.

**v1 slot ids keep working where they render today**: `viewer.topBar`, `main.appBar`, `album.appBar`, `selection`
(selection sheet), `plugins.page`, overlay slots `viewer`, `global`, `route:<RouteName>`. They are **not** aliases of
the new ids; the new ids are additional places.

**Slot context and `when`**: every slot has a JSON context (asset fields, album id, ...). The kernel adds `slot`,
`route` (current route name) and `platform`, and for asset slots `assetId`, `assetIds`, `assetType`, `isVideo`,
`isImage`, `isLocal`, `isRemote`, `isFavorite`, `selectionCount`. `when` matches it:

```json
{ "assetType": "IMAGE" }                         exact value
{ "assetType": ["IMAGE", "VIDEO"] }              any of
{ "isFavorite": { "not": true } }                negation (also { "not": { ...conditions } } at the top)
{ "selectionCount": { "gte": 2, "lt": 50 } }     gt, gte, lt, lte
{ "albumId": { "exists": true } }                present and not null
{ "tags": { "contains": "cats" } }               list or string contains
{ "route": { "matches": "^Album" } }             regular expression
{ "asset.exifInfo.make": "Apple" }               dotted paths
{ "any": [ {...}, {...} ], "all": [ ... ] }      combinators
```

**Built-in items** have stable ids (listed per slot in the catalog). `contributes.builtins.<slot>`:
`{ "hide": [ids], "order": [ids], "rename": { id: label }, "icons": { id: iconName } }`. `order` lists built-in ids and
`plugin:<plugin>/<id>` ids that move to the front in that order; `"*"` (or `"..."`) marks where the rest goes. Rules
from several plugins merge (hide: union; order: concatenated; rename / icons: the later plugin wins).

### Toggles

`kind: "toggle"` is an on/off icon whose state the app persists per plugin and id (`<plugin>/<id>`), shown as an icon
button, a checked menu item, a switch tile or a filter chip. Tapping flips it, emits `toggle.changed`
(`{ "key", "owner", "id", "value", "source" }`) and then calls `method` (if any) with `SlotV1` `event: "toggle"`.
Read and change toggles with `toggles.get` / `toggles.set` / `toggles.toggle` (ids without an owner are yours;
`app/<id>` are the app's built-in toggles, e.g. the viewer censor shield).

## Hooks

`contributes.hooks.<hookId>`: `{ "before"?: method, "instead"?: method, "after"?: method, "priority"?: int,
"timeoutMs"?: int, "when"?: condition }` (or a list of such objects). Hook ids may be patterns (`action.*`, `*`).

* **before** (higher `priority` first): return `{ "cancel": true, "message"? }` to cancel the operation (the app shows
  the message), or `{ "args": { ... } }` to change arguments (shallow merge) for later handlers and the operation.
* **instead**: the first handler returning `{ "result": x }` replaces the operation; `{ "fallthrough": true }`, `null`
  or no `result` continue with the next handler, then the app's own code.
* **after**: receives `{ "args", "result" }`; `{ "result": y }` replaces the result (query hooks filter, sort or extend
  lists this way: return a subset, another order, or extra items).
* **when** scopes a handler to calls whose `args` match (same matcher as slots), e.g. one timeline scope.

A handler that throws, times out (default 10 s, `timeoutMs` per handler) or returns something unusable is logged and
skipped; only an explicit `cancel` changes what happens. Hooks declared non-cancellable ignore `cancel`. Hooks cost
nothing while no plugin handles them. Naming: `<domain>.<verb>` (`asset.delete`, `album.create`, `settings.set`,
`image.thumbnail`, `nav.push`) and `action.<actionId>` for every UI action (args carry the assets as AssetV1).

## Events

`contributes.events`: `{ "<event or pattern>": "method" }` or `{ "<pattern>": { "method", "throttleMs" } }`.
Patterns: exact names, `prefix.*` (`asset.*` matches `asset.deleted`, not `assets.x`) and `*`. Delivery is
asynchronous (the app never waits), in order per plugin, as `EventV1` `{ "event", ...payload, "source"? }`; the
response's `message` / `actions` / `ui` are performed. High-frequency events are throttled (declared in the catalog,
or per subscription with `throttleMs`): the latest value wins. Naming: `<domain>.<pastTense>` or
`<domain>.<noun>Changed`.

Emit your own events with `host.emit(event, payloadJson)`, the `events.emit` host function or the `emit` command;
they reach every other plugin subscribed to them (with `"source": "<your plugin>"`).

Kernel events: `app.start`, `route.changed` (`{ "route", "previous", "action": "push" | "pop" }`), `toggle.changed`,
`task.started`, `task.finished`, `task.failed`, `task.cancelled` (`{ "id", "plugin", "title" }`),
`assetData.changed` (`{ "plugin", "assetId", "key", "value" }`). Area events are in the catalog.

## JSON UI

A node is `{ "type": "...", "id"?: "...", ...props, "children"?: [...] }`, rendered with the app's widgets and theme.
Every node accepts `visible` (false hides it), `padding`, `margin`, `opacity`, `tooltip`, `onTap` / `onLongPress`
(actions). Unknown or broken nodes show a small error in place; the rest of the tree still renders.

Layout: `column` (`spacing`, `mainAxis`, `crossAxis` default `stretch`, `expand`), `row` (`spacing`, `mainAxis`,
`crossAxis`, `shrink`), `stack` (`alignment`, `fit`), `positioned` (`left`, `top`, `right`, `bottom`, `width`,
`height`), `wrap` (`spacing`, `runSpacing`, `alignment`), `padding`, `center`, `align`, `expanded` / `flexible`
(`flex`), `spacer`, `sizedBox`, `aspectRatio` (`ratio`), `container` (`color`, `radius`, `border` `{ color, width }`,
`padding`, `gradient` `{ colors, begin, end }`, `width`, `height`, `alignment`), `card` (`variant`: `filled` /
`outlined`, `padding`, `color`), `scroll` (`direction`), `list` (lazy; `children` or `items`, `separated`,
`itemExtent`), `grid` (`columns` or `maxExtent`, `spacing`, `aspectRatio`), `divider`, `verticalDivider`, `safeArea`,
`clip` (`radius`), `section` / `group` (`title`, `subtitle`, `icon`, `collapsible`, `expanded`, `children`).

Content: `text` (`text`, `style`: `displayLarge` … `labelSmall`, `color`, `weight`, `size`, `italic`, `underline`,
`maxLines`, `align`, `selectable`), `icon` (`icon`, `color`, `size`), `image` (`file` (relative: in your zip), `url`,
`base64`, `assetId`, `fit`, `width`, `height`, `radius`, `version` to reload a changed file), `assetThumbnail` /
`assetImage` (`assetId`, `size`, `fit`), `progress` (`variant`: `linear` / `circular`, `value` or indeterminate),
`badge` (`label`, `child`), `avatar` (`text`, `icon`, `file`, `url`), `tooltip` (`message`, `child`), `nativeView`
(`view`, `params`, `height`, `composition`, `interactive`), `compare` (`before` / `after` image nodes or paths,
`mode`: `slider` / `hold`, `value`, `aspectRatio`, `labels`).

Input (each with an `id`; its value is kept in the state): `button` (`style`: `filled` / `tonal` / `outlined` /
`text` / `elevated`, `label`, `icon`, `action`, `destructive`, `enabled`), `iconButton` (`icon`, `selectedIcon`,
`selected`, `style`, `tooltip`, `action`), `fab` (`icon`, `label`, `action`), `listTile` (`title`, `subtitle`,
`leading`, `trailing`, `action`, `chevron`, `dense`), `switch` / `switchTile`, `checkbox`, `radio` (`options`), `slider`
(`min`, `max`, `divisions`, `label`, `showValue`, `decimals`, `unit`, `onChangeEnd`), `rangeSlider`, `textField`
(`label`, `hint`, `helper`, `error`, `multiline`, `minLines`, `maxLines`, `maxLength`, `keyboard`: `text` / `number` /
`integer` / `email` / `url` / `phone`, `obscure`, `onSubmit`), `dropdown` (`options`, `label`), `segmented`
(`options`, `multi`), `chip` (with `id` and `value`: a filter chip; with `action`: an action chip), `choiceChips`,
`filterChips` (`options`), `colorPicker` (`label`, `alpha`, `presets`, `inline`: RGB(A) sliders, hex field and preset
swatches; value `#AARRGGBB`), `datePicker` (`label`, `time`, `firstDate`, `lastDate`, `clearable`; value ISO),
`expansionTile` (`title`, `subtitle`, `leading`, `expanded`, `children`), `tabs` (`tabs`: `[{ label, icon, child }]`;
value = index), `gesture` (`onTap`, `onDoubleTap`, `onLongPress`, `child`).

Editors: `regionEditor` — draw, move, resize and delete boxes or ellipses over a photo or a video frame (`assetId` +
`timeMs`, or `file`), with a scrubber for videos (`durationMs`, `scrubber`); `shapes` (`["rect", "ellipse"]`),
`maxShapes`, `color`, `aspectRatio`; value `[{ "shape", "x", "y", "width", "height" }]` (0–1, extra keys kept); seeking
sends `event: "seek"` and stores `<id>.timeMs`. `canvas` — freehand strokes and points (`mode` / `modes`: `stroke`,
`point`; `color`, `strokeWidth`, `background`, `assetId` / `file`, `aspectRatio`); value
`{ "strokes": [{ "points": [x0, y0, ...], "color", "width" }], "points": [{ "x", "y", "color" }] }` (0–1). Images come
from the `image.load` host function (viewer area: photos and video frames), falling back to the app's image loading.

Options are `[{ "value", "label"?, "icon"? }]` or plain values. Colors are `#AARRGGBB` / `#RRGGBB` or theme tokens
(`primary`, `onPrimary`, `primaryContainer`, `secondary…`, `tertiary…`, `error…`, `surface`, `onSurface`,
`onSurfaceVariant`, `surfaceContainerLowest` … `surfaceContainerHighest`, `outline`, `outlineVariant`,
`inverseSurface`, `transparent`, `white`, `black`), optionally with alpha: `primary@0.5`. Insets: a number, `[h, v]`,
`[l, t, r, b]` or `{ left, top, right, bottom, horizontal, vertical }`. Alignments: `topLeft` … `bottomRight`,
`center`, or `[x, y]`.

**Actions** (`action`, `onTap`, `onSubmit`, ...):

* `"methodName"` or `{ "method": "name", "params": {} }` — calls the plugin with `UiEventV1`;
* `{ "command": { ...command } }` (or a command object itself, or `{ "commands": [...] }`) — runs app commands
  directly; `{ "type": "close", "result": x }` closes the page / dialog / sheet, `{ "type": "setState", "state" }`,
  `{ "type": "reload" }`;
* `{ "host": "name", "args": [...], "result"?: "inputId", "then"?: action, "onError"?: action }` — calls a host
  function directly, without a plugin round trip; in `args`, `"$value"` is the event value, `"$state"` the whole
  state and `{ "$state": "inputId" }` one input value.

**State and change events**: the renderer keeps every input's value by `id` and sends them all as `state` with every
event. An input with `onChange` (`true`, a method name or an action) sends `event: "change"` (text fields and sliders
debounced 250 ms). A response's `ui` replaces the tree, `state` replaces input values (a node's `value` applies when
it changes), `title` / `appBarActions` / `fab` update the page chrome, and `close` closes the surface with a result.

**Surfaces and live updates**: every JSON UI surface (page, settings page, tab, section, dialog, sheet, overlay) has
a surface id, sent to the plugin as `surface`. Defaults: pages `page:<page>`, settings `settings:<id>`, tabs
`tab:<id>`, dialogs `dialog:<page or method or title>`, sheets `sheet:...`, slot content `slot:<slot>/<id>`
(+ `#<assetId>`); commands and slot items accept `surface` to choose one. Push changes at any time:

* `ui.update([surfaceId, tree])` or `ui.update([surfaceId, { "ui"?, "state"? }])` — replace the tree / values;
* `ui.patch([surfaceId, nodeId, { props }])` — merge props into one node (`null` removes a prop; `value` also sets the
  input value);
* `ui.setState([surfaceId, { inputId: value }])`.

Updates reach every mounted instance of the id; an update for a surface that is not mounted yet is kept 10 s.

## Pages, dialogs, sheets, tabs, settings

* **JSON UI pages**: the `openUiPage` command (`method` called with `PageV1`, `page`, `title`, `params`, `ui` for a
  static tree, `surface`, `wait` to get the close result), slot items with `uiMethod` and no `method`, `page` items in
  `plugins.page`, route overrides with `uiMethod`. Nested pages push more pages; `back` / `closePage` / `close` pop.
* **Dialogs / sheets**: the `dialog` / `sheet` commands (`title`, `ui` or `method` + `page`, `params`, `buttons`:
  `[{ "label", "value", "style": "filled" | "text" | "destructive" }]`, `dismissible`, `surface`) return
  `{ "value": chosen button value or close result, "state": { inputs }, "dismissed": bool }`. A plugin response with
  `ui` opens it as a sheet.
* **Tabs** (`contributes.tabs`): `{ id, title, icon, selectedIcon?, uiMethod | view, params, order }` — bottom
  navigation tabs (see the shell catalog).
* **Settings** (`contributes.settings`, one object or a list): `{ id?, title, subtitle?, icon?, uiMethod | view,
  params }` — listed in Settings and on the Plugins page; JSON UI settings pages use surface `settings:<id>`. Open one
  with the `openSettings` command (`id`: `plugin:<plugin>/<id>` or your own page id).

## Commands

Send with `host.sendEvent(type, payloadJson)`, call as host functions `ui.<type>` (`[{ ...fields }]`, or a single
string for the main field), with the legacy `host.callHost("ui", "[{\"type\":...}]")`, or return them in `actions`:

| `type` | Fields | Result |
| --- | --- | --- |
| `toast` | `message` | |
| `snackbar` | `message`, `action`: `{ label, command? \| method?, value? }` | |
| `openUrl` | `url` | bool |
| `openPage` | `view`, `title`, `fullscreen`, `params`, `composition`, `plugin`?, `wait`? | close result with `wait` |
| `openUiPage` | `method`, `page`, `title`, `params`, `ui`?, `context`?, `surface`?, `wait`? | close result with `wait` |
| `closePage` / `back` | `result`? | |
| `navigate` | `path` (app route path) | |
| `showOverlay` | `id`, `view`, `params`, `route` (name, `*` or omitted = all), `interactive`, `position` | |
| `hideOverlay` | `id` | |
| `dialog` / `sheet` | see above | `{ value, state, dismissed }` |
| `confirm` | `title`, `message`, `confirm`, `cancel`, `destructive` | bool |
| `prompt` | `title`, `label`, `hint`, `value`, `obscure` | text or null |
| `pickAssets` | `limit`? | `[AssetV1]` |
| `pickAlbum` | `title`? | `{ id, name, kind: "app" \| "remote" \| "local", assetCount }` or null |
| `pickDate` | `value`? | `YYYY-MM-DD` or null |
| `openAsset` | `assetId` or `assetIds` + `index` | bool |
| `openAlbum` | `albumId`, `kind`? | bool |
| `select` / `clearSelection` | `assetIds`, `replace`? | count |
| `refresh` | | reloads plugin contributions |
| `refreshSlots` | `slot`? | drops cached `uiMethod` content |
| `setTheme` | theme fields (see "Theme") or `{ "reset": true }` | |
| `haptic` | `style`: `selection` / `light` / `medium` / `heavy` / `vibrate` | |
| `copy` | `text`, `toast`? | |
| `share` | `text`, `subject`, `files` (paths), `assetIds` | count of files |
| `setContentHeight` | `instance`, `height` (dp) | bool |
| `emit` | `event`, `data` | |
| `openSettings` | `id` | bool |
| `routes` | | route stack |

Area code can add commands (`kernel.registerCommand`); they appear here in the catalog.

## Host functions

`host.callHost(name, argsJsonArray)` (or `callHostAsync`) returns `{ "success": true, "response": ... }` or
`{ "success": false, "status", "message" }`. Introspect everything with `kernel.hostFunctions`, `kernel.slots`,
`kernel.hooks`, `kernel.events`.

v1 functions (unchanged):

| Name | Arguments | Result |
| --- | --- | --- |
| `listAssets` | `[{ "offset", "limit", "albumId" }]` | `[AssetV1]` |
| `getAsset` | `[assetId]` | AssetV1 |
| `readImage` | `[assetId, { "maxSize", "original" }]` | `{ "width", "height", "rgba": base64 }` |
| `writeImage` | `[assetId, { "width", "height", "rgba" } or { "encoded": base64 }]` | replaces the photo (original kept; the result becomes the base for later edits) |
| `getAssetEdits` / `editAsset` / `removeAssetEdits` | `[assetId]`, `[assetId, { "edits": [...] }]` | non-destructive edits |
| `searchAlbums` / `createAlbum` / `addAssetsToAlbum` / `addAssetsToAlbums` | as in the Immich API | app albums |
| `bulkTagAssets` | `[{ "tagIds", "assetIds" }]` | device tags |
| `httpRequest` | `[url, { "method", "headers", "body", "bodyBase64", "responseType": "base64", "timeoutSeconds" }]` | `{ "ok", "status", "headers", "body" }` |
| `readFile` / `writeFile` / `listFiles` / `deleteFile` | paths relative to the plugin's data folder unless absolute | file access |
| `getStorage` / `setStorage` | `[key]`, `[key, value]` | per-plugin JSON storage |
| `ui` | `[command]` | runs a command |

Kernel functions:

| Name | Arguments | Result |
| --- | --- | --- |
| `plugins.list` | `[]` | `[{ name, title, version, description, author, enabled, loaded, methods, contributes }]` |
| `plugins.call` | `[plugin, method, data?, { type?, timeoutMs?, config? }]` | the other plugin's response (`PluginCallV1`, data gets `from`) |
| `app.info` | `[]` | `{ name, packageName, version, buildNumber, platform, osVersion, locale, brightness, kernelApi, route }` |
| `ui.<command>` | `[{ fields }]` | command result |
| `ui.update` / `ui.patch` / `ui.setState` / `ui.surfaces` | see "JSON UI" | counts / mounted surfaces |
| `views.setHeight` | `[instance, heightDp]` | bool |
| `toggles.get` / `toggles.set` / `toggles.toggle` / `toggles.list` | `[id \| "owner/id", value?]` | value(s) |
| `tasks.start` | `[title, { cancellable?, progress?, message? }]` | task id |
| `tasks.update` | `[id, { progress?, message?, title?, indeterminate? }]` | bool (false once finished or cancelled) |
| `tasks.finish` | `[id, { message?, error? }]` | bool |
| `tasks.cancel` / `tasks.get` / `tasks.isCancelled` / `tasks.list` | `[id]` / `[]` | |
| `assetData.get` / `assetData.set` / `assetData.delete` / `assetData.list` | `[assetId, key?, value?]` / `[assetId?]` | per-asset data |
| `events.emit` | `[event, payload?]` | true |
| `slots.add` / `slots.remove` / `slots.list` | `[item]` / `[id]` / `[slotId, context?]` | runtime slot items (live until the plugin unloads) |
| `kernel.slots` / `kernel.hooks` / `kernel.events` / `kernel.hostFunctions` / `kernel.info` | `[]` | introspection |

Area host functions (`assets.*`, `albums.*`, `tags.*`, `people.*`, `search.*`, `timeline.*`, `viewer.*`, `video.*`,
`image.*`, `editor.*`, `nav.*`, `settings.*`, `theme.*`, `strings.*`, `db.*`, `files.*`, `net.*`, `media.*`,
`backup.*`, `sync.*`, `notify.*`) are in the catalog.

## Native views

Views come from `ImmichViewPlugin.createView(context, viewType, params, host)`; `viewType` is the `view` string.
`params` (JSON) holds the item's `params` plus:

* `instance` — this view's id; report your content height for inline views with `views.setHeight([instance, dp])` or
  the `setContentHeight` command (until then the app uses the declared `height` or a default);
* `viewId` — the platform view id;
* `theme` — `{ "brightness", "isDark", "colors": { token: "#AARRGGBB" }, "fontFamily", "textScale", "density" }`;
* `composition` — `"texture"` (default, texture layer) or `"hybrid"` (Hybrid Composition: exact rendering, best for
  text input, video and SurfaceView content); choose with `"composition": "hybrid"` on the item / command;
* for viewer overlays, `asset` (AssetV1).

`interactive` views get every gesture that starts on them (eager forwarding, also inside scroll views); keyboard
focus works in both modes (prefer `hybrid` for text fields). `ImmichViewLifecycle.onViewDisposed` is called when the
view goes away.

## Tasks

`tasks.start(title, { cancellable, progress })` shows app-native progress: a small indicator above the bottom bar
(tap for the list with cancel buttons) and the Tasks tab of the Plugins page. Update with `tasks.update`, end with
`tasks.finish` (`error` marks it failed). Cancelling marks the task cancelled and emits `task.cancelled` to
subscribers; long loops can also poll `tasks.isCancelled`. Tasks of a plugin that is unloaded fail.

## Per-asset data

`assetData.set([assetId, key, value])` stores small JSON values per asset and per plugin (files under the plugin's
data folder; each plugin sees only its own data). `assetData.get([assetId, key?])`, `assetData.delete([assetId,
key?])`, `assetData.list([assetId?])` (keys, or asset ids with data). Changes emit `assetData.changed`. Listen to the
asset deletion events (catalog) to clean up.

## Theme and strings

`contributes.theme` / the `setTheme` command: `seedColor`, `light` / `dark` color scheme tokens (`#AARRGGBB`),
`fontFamily` (a font file in your zip can be used, see the shell catalog), `mode` (`light` / `dark` / `system`), and
further keys the shell understands (`variant`, `contrast`, `fonts`, ...). Later plugins win per key.
`contributes.strings`: `{ "<locale>": { "<translation key>": "text" } }` (`en`, `en_US`, `*` for all).

## Screens and overlays

* `contributes.routes`: `{ "<RouteName>": { "view": "...", "title", "fullscreen", "params", "composition" } }` or
  `{ "uiMethod": "...", "title" }` (JSON UI) — navigating to that route opens your page instead. Replacing
  `TabShellRoute` replaces the whole home screen.
* `contributes.overlays` (v1) or slot items with `kind: "overlay"` in `global`, `route:<RouteName>`,
  `viewer.overlay` / `viewer`: native views or JSON UI over the screen; not interactive unless `interactive` is true.
  The `showOverlay` / `hideOverlay` commands add and remove overlays at runtime.

Route names: ActivitiesRoute, AlbumOptionsRoute, AppAlbumRoute, AppLogDetailRoute, AppLogRoute, ArchiveRoute,
AssetSelectionTimelineRoute, AssetTroubleshootRoute, AssetViewerRoute, BackupAlbumSelectionRoute,
BackupAssetDetailRoute, BackupOptionsRoute, BackupRoute, ChangePasswordRoute, CleanupPreviewRoute, CreateAlbumRoute,
DeviceTrashRoute, DeviceWorkflowEditorRoute, DownloadInfoRoute, EditImageRoute, FavoriteRoute, FolderRoute,
HeaderSettingsRoute, LibraryRoute, LocalAlbumsRoute, LocalMediaSummaryRoute, LocalTimelineRoute, LockedFolderRoute,
LoginRoute, MainTimelineRoute, MapLocationPickerRoute, MapRoute, MemoryListRoute, MemoryRoute, PartnerDetailRoute,
PartnerRoute, PeopleCollectionRoute, PersonRoute, PinAuthRoute, PlaceDetailRoute, PlaceRoute, PluginsRoute,
PrivateFileViewerRoute, PrivateGalleryRoute, PrivateLegacyRoute, PrivateViewerRoute, ProfilePictureCropRoute,
RecentlyAddedRoute, RecentlyTakenRoute, RemoteAlbumRoute, RemoteMediaSummaryRoute, SettingsRoute, SettingsSubRoute,
ShareIntentRoute, SharedLinkEditRoute, SharedLinkRoute, SlideshowRoute, SplashScreenRoute, SyncStatusRoute,
TabShellRoute, TrashRoute, UploadDetailRoute, UserSelectionRoute, VideoRoute, WhatsNewRoute.

## Icons

`icon` fields take a Material icon name as in Flutter's `Icons` (`auto_fix_high`, `photo_library_outlined`, ...;
about 1700 common icons and their `_outlined` variants; `photoLibrary` and `photo-library` work too) or a file path in
your zip (`files/icon.png`). The v1 short names (`star`, `video`, `magic`, `tag`, ...) keep their v1 icons.

## Workflows

Methods with `types: ["AssetV1"]` are workflow steps (`uiHints: ["Filter"]` for filters) and run on new photos;
`templates` offer ready-made workflows on the Plugins page.

## Catalog

Every slot, built-in id, hook, event and host function is listed per area. `kernel.slots`, `kernel.hooks`,
`kernel.events` and `plugins.list` return the same information at runtime.

| Area | Covers | Catalog |
| --- | --- | --- |
| Viewer | photo/video viewer bars and menu, info sheet, gestures, image pipeline (`image.thumbnail/preview/full`), video sessions, frame capture and overlays, slideshow, memories | [docs/plugins/viewer.md](docs/plugins/viewer.md) |
| Editor | plugin editor tools of any output size (`EditorToolV1`), panels, preview/apply with tasks, save as copy or replace | [docs/plugins/editor.md](docs/plugins/editor.md) |
| Timeline | every asset action (`action.<id>` hooks, ids, rules), selection sheets, tiles (badge/wrap/replace), headers, scrubber, `timeline.query`, bottom-navigation tabs, app menu | [docs/plugins/timeline.md](docs/plugins/timeline.md) |
| Library | albums, people, places, map (plugin layers), search (result providers), folders, partners, shared links, private and locked folder | [docs/plugins/library.md](docs/plugins/library.md) |
| Shell | settings menu and pages, plugin settings, theme and strings, navigation (`nav.push`), login, splash, backup UI, share intent, logs, lifecycle | [docs/plugins/shell.md](docs/plugins/shell.md) |
| Data | hooks and events on every data mutation and query, database, settings store, assets, albums, tags, people, files and downloads, network, media writes, sync and upload | [docs/plugins/data.md](docs/plugins/data.md) |
| Native | Android host: lifecycle, intents, permissions, notifications, background work, media, video, views, crash isolation | [docs/plugins/native.md](docs/plugins/native.md) |

Everything Android offers can still be used directly from plugin code.
