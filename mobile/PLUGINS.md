# Plugins

Plugins are native Android code (Java or Kotlin compiled to `classes.dex`), loaded at runtime with `DexClassLoader`, the same way Aliucord loads plugins. They run inside the app with its full permissions. There is no sandbox.

## Package

A plugin is a zip installed from the Plugins page (+) or dropped into the plugin drop folder:

```
manifest.json            required
classes.dex              required (or the file named by "dexPath")
lib/<abi>/*.so           optional native libraries (arm64-v8a, armeabi-v7a, x86_64)
anything/else            optional files (models, icons, data)
```

Every file other than `manifest.json` and the dex is extracted to the plugin's folder (`PluginHost.pluginDir`). Native libraries for the phone's ABI are put on the plugin class loader's library path, so `System.loadLibrary` works.

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
    "buttons": [ ... ],
    "pages": [ ... ],
    "overlays": [ ... ],
    "events": { "app.start": "onStart" },
    "routes": { "MainTimelineRoute": { "view": "gallery" } }
  }
}
```

`name` uses lowercase letters, digits and `-`. `runtime` must be `"dex"`. `entry` is the class the app instantiates; it needs a public no-argument constructor.

## Java/Kotlin API

Compile against these interfaces (package `app.alextran.immich.plugins.api`). Do not put them in your dex; the app provides them.

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

interface PluginHost {
  val context: Context            // application context
  val activity: Activity?         // the app's activity: dialogs, popups, startActivity, permissions
  val dataDir: File               // private storage for this plugin
  val pluginDir: File             // files shipped in the zip (models, icons, ...)
  val pluginName: String
  fun callHost(name: String, argsJson: String): String   // host functions, see below
  fun runOnUi(block: Runnable)
  fun sendEvent(name: String, payloadJson: String)        // app commands, see "Commands"
}
```

`call` runs on a background thread. Touch views only through `runOnUi` or `activity.runOnUiThread`. An exception thrown from `call` is returned to the app as a failed call; for buttons it is shown to the user.

Build:

```sh
javac --release 11 -cp "$ANDROID_HOME/platforms/android-36/android.jar:api-stubs" -d out $(find src -name '*.java')
$ANDROID_HOME/build-tools/36.0.0/d8 --release --min-api 26 --lib $ANDROID_HOME/platforms/android-36/android.jar \
  --output . $(find out -name '*.class' ! -path '*/plugins/api/*') [extra.jar ...]
zip -r my-plugin.zip manifest.json classes.dex lib models
```

## What a plugin can reach

| Surface | How |
| --- | --- |
| Any screen, replaced entirely | `contributes.routes`: `{ "<RouteName>": { "view": "...", "title": "...", "fullscreen": true, "params": {} } }`. Navigating to that route opens your view instead. |
| Any screen, overlaid | `contributes.overlays` with `"slot": "global"` (every screen) or `"slot": "route:<RouteName>"`, or the `showOverlay` command at runtime. |
| Photo/video viewer overlay | `contributes.overlays` with `"slot": "viewer"`. `params.asset` holds the open asset. |
| Buttons | `contributes.buttons` with `slot` `viewer.topBar`, `main.appBar`, `album.appBar`, `selection` (selection sheet) or `plugins.page`. |
| Pages | `contributes.pages` (listed on the Plugins page) or the `openPage` command. |
| Your own native UI | `host.activity`: dialogs, popups, bottom sheets, toasts, `startActivity`, permission requests. |
| Events | `contributes.events`: `{ "<event>": "<method>" }`. |
| Workflows | methods with `types: ["AssetV1"]` (steps) and `uiHints: ["Filter"]` (filters); `templates`. |
| Mosaic brush styles | methods with `types: ["CensorStyleV1"]`. |
| Censor while viewing | a method with `types: ["ViewerFilterV1"]`. |
| Gallery sort/filter | a method with `types: ["GalleryViewV1"]`. |
| Actions on selected photos | methods with `types: ["AssetActionV1"]`. |
| Data, files, network | host functions, or plain Android APIs (MediaStore, files, sockets, ...). |

Views are created through `ImmichViewPlugin.createView(context, viewType, params, host)`. `viewType` is the `view` string from the manifest or command, and `params` is a JSON string.

Route names: ActivitiesRoute, AlbumOptionsRoute, AppAlbumRoute, AppLogDetailRoute, AppLogRoute, ArchiveRoute, AssetSelectionTimelineRoute, AssetTroubleshootRoute, AssetViewerRoute, BackupAlbumSelectionRoute, BackupAssetDetailRoute, BackupOptionsRoute, BackupRoute, ChangePasswordRoute, CleanupPreviewRoute, CreateAlbumRoute, DeviceTrashRoute, DeviceWorkflowEditorRoute, DownloadInfoRoute, EditImageRoute, FavoriteRoute, FolderRoute, HeaderSettingsRoute, LibraryRoute, LocalAlbumsRoute, LocalMediaSummaryRoute, LocalTimelineRoute, LockedFolderRoute, LoginRoute, MainTimelineRoute, MapLocationPickerRoute, MapRoute, MemoryListRoute, MemoryRoute, PartnerDetailRoute, PartnerRoute, PeopleCollectionRoute, PersonRoute, PinAuthRoute, PlaceDetailRoute, PlaceRoute, PluginsRoute, PrivateFileViewerRoute, PrivateGalleryRoute, PrivateLegacyRoute, PrivateViewerRoute, ProfilePictureCropRoute, RecentlyAddedRoute, RecentlyTakenRoute, RemoteAlbumRoute, RemoteMediaSummaryRoute, SettingsRoute, SettingsSubRoute, ShareIntentRoute, SharedLinkEditRoute, SharedLinkRoute, SlideshowRoute, SplashScreenRoute, SyncStatusRoute, TabShellRoute, TrashRoute, UploadDetailRoute, UserSelectionRoute, VideoRoute, WhatsNewRoute. Replacing `TabShellRoute` replaces the whole home screen with its tabs.

### Manifest contributions

```json
"buttons":  [{ "id": "go", "title": "Go", "slot": "viewer.topBar", "icon": "bolt", "method": "onGo", "params": {} }],
"pages":    [{ "id": "home", "title": "My page", "view": "home", "icon": "files/icon.png", "slot": "plugins.page" }],
"overlays": [{ "id": "hud", "slot": "global", "view": "hud", "interactive": false, "params": {} }]
```

A button with a `method` calls it. A button or page without a `method` but with a `view` opens that view as a page. `icon` is a name (extension, star, favorite, share, edit, delete, info, settings, search, filter, sort, tune, shield, lock, visibility, visibility_off, image, photo, video, album, folder, download, upload, cloud, sync, refresh, play, pause, brush, blur, grid, label, tag, map, person, face, calendar, more, add, check, close, open, link, code, bolt, magic) or a file path inside the zip. Overlays are not interactive unless `interactive` is true.

## Calls into the plugin

`call(method, input)` receives JSON shaped as:

```json
{ "type": "<kind>", "config": { ... }, "workflow": { "id": "...", "stepId": "..." }, "data": { ... } }
```

| `type` | When | `data` | Expected response |
| --- | --- | --- | --- |
| `AssetV1` | workflow step for each new photo | `{ "asset": AssetV1 }` | `{ "workflow": { "continue": false } }` to stop, `{ "changes": { "asset": { "isFavorite": true } } }` |
| `ButtonV1` | button tapped | `{ "slot": "...", "assets": [AssetV1] }` | optional `{ "message": "...", "actions": [command, ...] }` |
| `EventV1` | event fired | `{ "event": "...", ... }` | optional `{ "message", "actions" }` |
| `AssetActionV1` | selection action run | `{ "assets": [AssetV1] }` | optional `{ "message" }` |
| `CensorStyleV1` | mosaic brush style | `{ "width", "height", "size", "grid": { "width", "height", "cell", "rgba": base64 }, "source"?: { "path", "width", "height", "format": "rgba" } }` (source only when the method has `"pixels": true`) | `{ "tiles": { "polygons": [[x,y,...]], "a": [x,y], "b": [x,y] } }`, `{ "cells": { "grid": { "size", "jitter" }, "borders"?: { "width", "color" } } }`, `{ "shapes": [{ "points": [...], "color"?: [r,g,b] }] }`, `{ "blur": radius }`, or `{ "image": { "path" or "rgba", "width", "height" } }` |
| `ViewerFilterV1` | photo/video opened with the shield on | image: `{ "kind": "image", "source": { "path", "width", "height", "format": "rgba" } }`; video: `{ "kind": "video", "source": { "path" }, "fromMs", "toMs", "stepMs" }` | image: `{ "regions": [{ "x", "y", "width", "height", "shape": "rect" or "ellipse" }], "style"?: "plugin#method", "styleOptions"?: {}, "size"?: fraction }`; video: `{ "frames": [{ "timeMs", "regions": [...] }] }`. Coordinates are 0–1. |
| `GalleryViewV1` | gallery view settings applied | `{ "scope": "main" or "album", "albumId"?, "albums": [{ "id", "name" }] }` | `{ "view": { "sort": { "field": "createdAt|updatedAt|name|pixels|duration", "direction": "asc|desc" }, "include": { "photos", "videos", "gifs" }, "excludeAlbumIds": [] } }` |

Events: `app.start`, `route.changed` (`route`, `previous`), `viewer.open` (`asset`).

## Commands (plugin to app)

Send with `host.sendEvent(type, payloadJson)`, `host.callHost("ui", "[{\"type\":...}]")`, or return them in `"actions"`:

| `type` | Fields |
| --- | --- |
| `toast` | `message` |
| `openUrl` | `url` |
| `openPage` | `view`, `title`, `fullscreen`, `params`, optional `plugin` |
| `closePage` / `back` | |
| `navigate` | `path` (app route path) |
| `showOverlay` | `id`, `view`, `params`, `route` (route name, `*` or omitted for all), `interactive`, `position` (`left`, `top`, `right`, `bottom`, `width`, `height`) |
| `hideOverlay` | `id` |
| `refresh` | reloads plugin buttons, pages, overlays and route overrides |
| `routes` | returns the current route stack (via `callHost`) |

## Host functions

`host.callHost(name, argsJsonArray)` returns `{ "success": true, "response": ... }` or `{ "success": false, "status", "message" }`.

| Name | Arguments | Result |
| --- | --- | --- |
| `listAssets` | `[{ "offset", "limit", "albumId" }]` | `[AssetV1]` |
| `getAsset` | `[assetId]` | AssetV1 |
| `readImage` | `[assetId, { "maxSize", "original" }]` | `{ "width", "height", "rgba": base64 }` |
| `writeImage` | `[assetId, { "width", "height", "rgba" } or { "encoded": base64 }]` | replaces the photo, backing up the original |
| `getAssetEdits` / `editAsset` / `removeAssetEdits` | `[assetId]`, `[assetId, { "edits": [...] }]` | non-destructive edits (crop, rotate, mirror, mosaic) |
| `searchAlbums` / `createAlbum` / `addAssetsToAlbum` / `addAssetsToAlbums` | as in the Immich API | app albums |
| `bulkTagAssets` | `[{ "tagIds", "assetIds" }]` | local tags |
| `httpRequest` | `[url, { "method", "headers", "body", "bodyBase64", "responseType": "base64", "timeoutSeconds" }]` | `{ "ok", "status", "headers", "body" }` |
| `readFile` / `writeFile` / `listFiles` / `deleteFile` | paths relative to the plugin's data folder unless absolute | file access |
| `getStorage` / `setStorage` | `[key]`, `[key, value]` | per-plugin JSON storage |
| `ui` | `[command]` | runs a command (see above) |

Everything else Android offers can be used directly from plugin code.
