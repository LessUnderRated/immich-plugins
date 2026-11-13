# Viewer, video, images, slideshow and memories

Catalog of everything the viewer area exposes to plugins (plan sections 8 and 10). Ids live in
`lib/infrastructure/plugins/plugin_api/viewer/viewer_ids.dart`. AssetV1 is the kernel's asset JSON (local and remote
assets); `asset` is `null` when there is none. Coordinates called *normalized* are 0–1, origin top left.

## Slots

Every slot accepts `builtins` rules (`hide`, `order`, `rename`; plugin items are `plugin:<plugin>/<id>`). Action
entries use the action ids of the timeline catalog (`ActionIds`), so one rule covers an action in every bar and menu,
and each runs through its `action.<id>` hook; plugin `button` / `menuItem` contributions of an action slot appear
among them like built-ins. Common
context fields: `asset` (AssetV1), `surface` (`viewer` | `slideshow` | `memory`), `route`, plus the kernel's derived
`when` keys (`assetType`, `isVideo`, `isImage`, `isLocal`, `isRemote`, `isFavorite`).

| Slot | Kinds | Extra context | Built-in ids (display order) |
| --- | --- | --- | --- |
| `viewer.topBar` (alias `assetViewer.appBar.actions`) | `button`, `toggle` | `index`, `total`, `origin` (timeline origin), `albumId`, `isLocked`, `isReadonly` | `motionPhoto`, `activity`, `favorite`, `deviceFavorite`, `plugins`, `censor`, `menu` (locked folder: `menu` only) |
| `viewer.menu` (alias `assetViewer.appBar.menu`) | `menuItem`, `toggle` | as `viewer.topBar` | `openInfo`, `likeActivity`, `shareLink`, `cast`, `setAlbumCover`, `similarPhotos`, `setProfilePicture`, `viewInTimeline`, `slideshow`, `download`, `openInBrowser`, `stack`, `lock`, `removeFromAlbum`, `deleteLocal`, `advancedInfo` (each only where it applies; dividers separate groups; plugin entries join the middle group) |
| `viewer.bottomBar` (alias `assetViewer.footer`) | `button` | as `viewer.topBar` | `restoreTrash`, `share`, `edit`, `moveToPrivate`, `addTo` (the "Add to" menu, slot `viewer.addMenu`), `delete` |
| `viewer.bottomPanels` | `section`, `panel`, `view` | as `viewer.topBar` | `ocr`, `videoControls`, `carousel`, `actions` (the `viewer.bottomBar` row) |
| `viewer.info.sections` | `section`, `tile`, `view` | `exif` (EXIF JSON) | `dateTime`, `owner`, `description`, `people`, `location`, `technical`, `rating`, `appearsIn`, `tags` |
| `viewer.title` | `replace`, `wrap` | `dateTime` (ISO, asset time zone) | – |
| `viewer.overlay` (legacy `viewer`, alias `assetViewer.overlay`) | `overlay`, `view`, `section` | `frame` (photo or video rect on screen, logical px), `zoomed` | – |
| `videoPlayer.overlay` | `view` | `sessionId`, `frameRect` | – (native view inside the player container, see *Video sessions*) |
| `videoPlayer.controls` | `button`, `toggle` | `sessionId`, `positionMs`, `durationMs`, `playing` | `playPause`, `scrubber`, `time` |
| `slideshow.appBar.actions` | `button`, `toggle` | `index`, `total`, `paused` | `playPause`, `settings` |
| `slideshow.appBar.menu` | `menuItem` | as above | – (the ⋮ appears when a plugin adds an item) |
| `slideshow.overlay` | `overlay`, `view`, `section` | as above | – |
| `memory.appBar.actions` | `button`, `toggle` | `memory` (MemoryV1), `index`, `total` | `close` |
| `memory.overlay` | `overlay`, `view`, `section` | as above | – |
| `memory.footer` | `section` | as above | – |
| `memoryList.appBar.actions` | `button`, `toggle` | `onlyFavorites` | `favorites` |
| `memoryList.appBar.menu` | `menuItem` | as above | – |
| `memoryList.tile` | `badge`, `wrap`, `replace` | `memory` (MemoryV1) | – |
| `memoryList.empty` | `replace`, `section` | – | – |

MemoryV1: `{ "id", "type", "year", "personName", "isSaved", "memoryAt", "assetIds": [] }`.

The actions of `viewer.topBar`, `viewer.bottomBar` and `viewer.menu` (in that order) are the action surface `viewer`
of the timeline catalog's `actions.list` / `actions.run` host functions while a viewer is open; they act on the
current asset.

Built-in toggle: `viewer.censor` (the viewer censor shield, kernel `toggle` mechanism): read and set it with
`toggles.get` / `toggles.set`, follow it with `toggle.changed`.

## Hooks

| Hook | Args | Result | Cancellable |
| --- | --- | --- | --- |
| `viewer.gesture` | `{ "gesture": "tap"\|"doubleTap"\|"longPress"\|"swipeUp"\|"swipeDown"\|"pinch", "surface", "asset", "x", "y" (normalized to the page), "px": {x, y}, "zone": "left"\|"center"\|"right", "viewport": {width, height}, "zoomed", "scale"?, "previousScale"? (pinch, 1 = fit), "distance"?, "velocity"? (swipes, px and px/s, + = down) }` | `{ "handled": "builtin" }` | yes: `before` cancel or `instead` skips the built-in (tap: no controls toggle / tap-to-navigate; double tap: no zoom; long press: no motion video; swipe down: viewer stays and settles; swipe up: details sheet closes again; pinch: zoom returns to `previousScale`) |
| `image.thumbnail`, `image.preview`, `image.full` | see *Image pipeline* | image or unchanged | yes: cancel hides the image (error placeholder) |
| `video.source` | `{ "asset", "source": { "path" (file path or URL), "uri", "type": "file"\|"network"\|"asset", "headers" } }` | `{ "path", "type"?, "headers"? }` (another file or URL to play) | yes: the video is not played (its poster stays) |
| `video.control` | `{ "action": "play"\|"pause"\|"restart"\|"seek", "sessionId", "asset", "positionMs", "fromMs"? (seek) }` | `{ "handled": "builtin" }` | yes: play / pause / restart do nothing; a seek jumps back to `fromMs` |

Double tap, pinch and long press on photos that are not motion photos are recognized only while a plugin hooks
`viewer.gesture`, so the viewer behaves exactly as before without one. Seeks are reported when the scrubber is
released (the video already follows the finger). Every action of the bars and menus above also runs through
`action.<id>` (timeline catalog).

## Events

| Event | Payload | Throttling |
| --- | --- | --- |
| `viewer.open` (legacy) | `{ "asset" }`, local assets only | – |
| `viewer.opened` | `{ "asset", "surface": "viewer", "index", "total", "origin" }` | – |
| `viewer.assetChanged` | `{ "asset", "surface", "index", "total", "origin", "previousAssetId" }` | – (after the page settles) |
| `viewer.closed` | `{ "asset", "surface", "index" }` | – |
| `viewer.controlsChanged` | `{ "surface", "visible" }` | – |
| `viewer.detailsChanged` | `{ "asset", "surface", "visible" }` | – |
| `viewer.zoomChanged` | `{ "surface", "zoomed" }` | – |
| `video.sessionStarted`, `video.sessionEnded` | VideoSessionV1 + `asset` | – |
| `video.state` | VideoSessionV1 (state, speed or volume changed) | – |
| `video.position` | `{ "sessionId", "assetId", "positionMs", "durationMs", "playing", "speed" }` | 250 ms per session (4/s), trailing value kept |
| `video.frameRect` | `{ "sessionId", "assetId", "frameRect": {left, top, width, height}, "boxSize": {width, height} }` | 100 ms per session |
| `slideshow.started` | `{ "asset", "index" }` | – |
| `slideshow.slideChanged` | `{ "asset", "index", "previousIndex", "total" }` | – |
| `slideshow.paused`, `slideshow.resumed`, `slideshow.ended` | `{ "asset", "index" }` | – |
| `memory.opened`, `memory.assetChanged`, `memory.closed` | `{ "asset", "memory" (MemoryV1), "index", "total" }` | – |
| `image.invalidated` | `{ "assetId"? }` | – |

VideoSessionV1: `{ "sessionId", "assetId", "localId", "remoteId", "surface", "viewId", "state":
"loading"|"ready"|"playing"|"paused"|"buffering"|"completed"|"error", "positionMs", "durationMs", "speed", "volume",
"isCurrent", "looping", "videoSize"?: {width, height}, "frameRect"?: {left, top, width, height} }`.

## Host functions

Called with `host.callHost(name, argsJsonArray)`. A missing `sessionId` (or `"current"`) means the current page's
session, else the most recent one.

| Name | Args | Result |
| --- | --- | --- |
| `viewer.open` | `[assetId]` or `[{ "assetIds": [...], "index"? }]` (local or remote ids) | `{ "opened": n }` |
| `viewer.close` | `[]` | closes the innermost viewer (asset viewer, slideshow or memory) |
| `viewer.next`, `viewer.previous` | `[]` | `{ "moved", "index" }` |
| `viewer.current` | `[]` | `{ "surface", "asset", "index", "total", "controlsVisible", "detailsVisible", "zoomed" }` or `null` |
| `viewer.showControls` | `[bool]` | – |
| `viewer.showDetails` | `[bool]` | opens / closes the info sheet of the page on screen |
| `video.sessions` | `[]` | `[VideoSessionV1 + asset]` |
| `video.session` | `[sessionId?]` | VideoSessionV1 + asset |
| `video.play`, `video.pause` | `[sessionId?]` | – |
| `video.seek` | `[sessionId?, positionMs]` | – |
| `video.setSpeed` | `[sessionId?, speed]` | – |
| `video.setVolume` | `[sessionId?, volume 0–1]` | – |
| `video.position` | `[sessionId?]` | `{ "positionMs", "durationMs", "playing", "speed" }` (playback clock) |
| `video.capture` | `[sessionId?, { "width"?, "height"?, "format"?: "rgba"\|"png"\|"jpeg", "quality"? }]` | `{ "path", "width", "height", "format", "positionMs" }` from the real player |
| `video.overlay.set` | `[target, { "layer"?, "items": [item] }]` | `{ "items": n }`; replaces the plugin's items in that layer |
| `video.overlay.patch` | `[target, { "layer"?, "upsert"?: [item], "remove"?: [id] }]` | – |
| `video.overlay.clear` | `[target?, { "layer"? }]` | – (no layer: every layer of the plugin; no target: everywhere) |
| `video.nativeOverlay.attach` | `[sessionId?, { "view", "id"?, "params"?, "interactive"? }]` | `{ "overlayId" }` |
| `video.nativeOverlay.detach` | `[sessionId?, { "id"? }]` | – (no id: every native overlay of the plugin) |
| `image.load` | `[assetId, { "size"?: {width, height} \| maxSize, "maxSize"? (default 2048), "timeMs"?, "format"?: "rgba"\|"png"\|"encoded"\|"jpeg", "original"?, "processed"? }]` | `{ "path", "width", "height", "format", "assetId", "timeMs"? }` |
| `image.invalidate` | `[assetId?]` | – (drops pipeline caches and decoded images; shown images reload) |

`target` is a session id or `{ "assetId" }` (every session of that asset, also ones that start later). `image.load`
returns a photo (decoded into the bounding box, preview or original) or, for a video with `timeMs`, that frame
(decoded natively from the file or the server, no player needed); `processed: true` runs the image pipeline so the
result is what the viewer shows. The kernel's `regionEditor` node calls `image.load` by name. Returned files are
temporary (swept after ten minutes): copy what you keep.

## Image pipeline

`image.thumbnail` (timeline grid, carousel, memory lane), `image.preview` (screen-sized: viewer, memories, slideshow)
and `image.full` (originals with "load original", animated images). Any plugin may transform or replace any image of
a stage; nothing changes for a stage no plugin hooks.

Args: `{ "stage": "thumbnail"|"preview"|"full", "asset": AssetV1, "size": {width, height},
"source": { "path", "width", "height", "format": "rgba" } }`. `source` holds the decoded pixels (row-major RGBA,
4 bytes per pixel, `width * 4` bytes per row); the file is deleted when the hook returns.

Result (`instead` → `{ "result": x }`; `after` gets `{ "args", "result" }` and may return a new `result`):

* `null` or `{ "unchanged": true }`: show the decoded image.
* `{ "path", "width", "height", "format": "rgba" }`, `{ "path", "format": "encoded" }` (PNG, JPEG, WebP, ...),
  `{ "rgba": base64, "width", "height" }` or `{ "encoded": base64 }`: show this image instead. Any size (upscalers
  return larger images; the viewer fits it as it fits the original). The app reads the file once the call returns.
* `{ "blocked": true, "message"? }` (or `before` cancel): the image is not shown.

Several plugins chain: `after` handlers transform `result.path` when a result is present, else `args.source.path`.
Built-in Dart transformers (the `ViewerFilterV1` shield) run after the plugin hooks.

Caching: results are kept per stage, asset (local id, remote id, checksum), decoded size and plugin versions
(`plugin@version` of every handler of the hook, plus built-in transformer settings) in memory (512 entries,
including "unchanged" and "blocked") and on disk (1500 raw images). Changing plugins, `image.invalidate` and toggling
the censor shield clear the caches; images on screen reload. Up to three transforms run at a time.

Waiting: the lower-resolution image stays on screen until the hooked stage answers. It is shown as is when
`image.thumbnail` is hooked too (it went through the pipeline), blurred otherwise, so no unprocessed image is ever
shown sharp. A preview shown before a hooked `image.full` is blurred as well. A hook that fails or times out
(manifest `timeoutMs`, default 10 s) shows the decoded image.

Animated images: the first frame of the original goes through `image.full`; a replacement is shown as a still
image, "unchanged" plays the animation from its first frame.

Not in the pipeline: thumbhash placeholders, face and avatar images, and a file opened from another app's share or
view intent.

## Video sessions

Every player (viewer, slideshow, memory) is a session from the moment its native view exists until it is disposed.
Session ids are `vs<n>`. `isCurrent` is true for the player on the current page. The session clock
(`video.position`, overlay evaluation) is the last reported position extrapolated with wall time × speed while
playing, so it advances smoothly between player reports.

Frame rect: the aspect-fit (`contain`, centered) rect of the decoded video size inside the player box, in global
logical pixels, including zoom and page moves (`video.frameRect`, VideoSessionV1 `frameRect`). Multiply by
`devicePixelRatio` for physical pixels.

### Declarative overlay layer

Items drawn by Flutter exactly over the video frame, evaluated every frame against the session clock (ticks only
while items exist and the video plays). Owner of a layer is `<plugin>/<layer>` (`layer` default `default`).

```json
{
  "id": "face-1",
  "shape": "rect" | "ellipse" | "roundRect" | "path" | "image" | "text" | "fill",
  "rect": { "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.3 },
  "atMs": 1200, "fromMs": 1200, "toMs": 1700, "fadeMs": 0,
  "velocity": { "x": 0.01, "y": 0, "width": 0, "height": 0 },
  "keyframes": [ { "atMs": 1200, "rect": { ... } }, { "atMs": 1700, "rect": { ... } } ],
  "easing": "linear" | "easeIn" | "easeOut" | "easeInOut" | "step",
  "radius": 0.2,
  "points": [x0, y0, x1, y1, ...],
  "image": { "path": "/abs/file.png" }, "fit": "contain" | "cover" | "fill",
  "text": "🙂", "fontSize": 0.1, "fontWeight": "bold",
  "color": "#AARRGGBB", "blur": 24, "stroke": { "color": "#FFFFFFFF", "width": 2 },
  "opacity": 1, "z": 0
}
```

* Shown while `fromMs <= t <= toMs` (open-ended when missing), fading over `fadeMs`.
* Position at `t`: interpolated between `keyframes` with `easing`; before the first / after the last keyframe (or
  without keyframes, from `rect` at `atMs`) it moves by `velocity` (normalized units per second): extrapolation keeps
  a tracked box on its object between detections.
* `fill` covers the frame; `path` is a closed polygon (normalized, moved and scaled with its rect); `radius` is a
  fraction of the shorter side; `fontSize` a fraction of the frame height (default: fits the rect).
* `color` fills the shape; `blur` (sigma, logical px) blurs the video under it; both may be combined.

### Native overlay view

`video.nativeOverlay.attach` (or a `videoPlayer.overlay` slot item of kind `view`) puts the plugin's native view
(`ImmichViewPlugin.createView(context, view, params, host)`) inside the player container, above the video surface
and below Flutter, sized and positioned exactly over the video frame, following resizes and removed with the session.
`params` gets `sessionId`, `assetId`, `viewId` and the plugin's own `params`.

### Dart ↔ native channel

`MethodChannel("immich/plugin_video")`, standard codec. Implemented natively by the native area; the Dart side is
`PluginVideoChannel` in `plugin_api/viewer/video_sessions.dart`. Every call carries the session fields
`{ "sessionId", "viewId", "assetId", "localId", "remoteId", "surface" }`; the native side finds the player with
`flutterEngine.platformViewsController.getPlatformViewById(viewId)` (the native_video_player container
`FrameLayout` → `AspectRatioFrameLayout` → `SurfaceView`, ExoPlayer behind it).

| Method (Dart → native) | Extra args | Returns |
| --- | --- | --- |
| `registerSession` | state fields: `state`, `positionMs`, `durationMs`, `speed`, `volume`, `videoWidth`, `videoHeight`, `frameRect` {left, top, width, height} (logical px), `devicePixelRatio` | `null`. Sent lazily, before the first capture or native overlay. |
| `updateSession` | state fields | `null`. Sent on state changes and frame moves of registered sessions. |
| `unregisterSession` | – | `null`. Detach every native overlay of the session. |
| `captureFrame` | `width`?, `height`? (default: video size), `format`: `rgba`\|`png`\|`jpeg`, `quality`, `positionMs` | `{ "path", "width", "height", "format", "positionMs" }`. PixelCopy of the `SurfaceView` scaled to the size asked; file in the app cache. |
| `extractFrame` | `path`? (file) or `url`? + `headers`?, `localId`?, `timeMs`, `width`?, `height`?, `format`, `quality` | same as `captureFrame`. `MediaMetadataRetriever.getScaledFrameAtTime(timeMs * 1000, OPTION_CLOSEST)`. |
| `attachOverlay` | state fields, `plugin`, `view`, `id`, `params`, `interactive` | `{ "overlayId": "<plugin>/<id>" }`. Creates the plugin view and adds it inside the `AspectRatioFrameLayout` (exact frame) above the `SurfaceView`; not touchable unless `interactive`. Replaces an overlay with the same id. |
| `detachOverlay` | `plugin`, `id`? | `null`. Removes that overlay, or all of the plugin's overlays in the session; calls `ImmichViewLifecycle.onViewDisposed`. |

Errors are `PlatformException`s; a missing implementation (`MissingPluginException`) makes `video.capture` and
`video.nativeOverlay.*` fail with a message and is ignored for `updateSession` / `unregisterSession`.

## ViewerFilterV1 (censor while viewing)

Unchanged for plugins. Photos: the shield is a built-in pipeline transformer on `image.preview` / `image.full`
(local photos) that calls the `ViewerFilterV1` method and composites its regions with the style it names, so the
censored image shows wherever the photo shows (viewer, memories, slideshow). A plugin that returned a fake brush
style to hand back a whole image can instead hook `image.full` / `image.preview` and return the image. Videos: the
`ViewerFilterV1` video frames become declarative overlay items (`blur`, one item per region and frame window) on the
session; plugins can push such items themselves with `video.overlay.set`, capture frames with `video.capture` and
attach native views with `video.nativeOverlay.attach`, instead of searching the view tree for the player.

## Status

Wired: ids, rules and plugin actions in every viewer bar and menu, `action.<id>` for every action, all events,
`viewer.gesture`, `video.source`, `video.control`, the image pipeline in every image provider, video sessions and the
declarative overlay layer, `image.load`, every host function (registered with the kernel), `ViewerPlugins` and
`ImagePipeline` bound to the kernel (cache invalidated when image hooks change).
Also wired: `viewer.info.sections` (below the built-in details) and `viewer.bottomPanels` content, the censor shield as
the generic toggle `app/viewer.shield`, plugin toggles and buttons merged into every action bar next to actions.
Not yet: `viewer.title` and the memory and slideshow slots render nothing; `ViewerFilterV1` video results are not yet
turned into overlay items.
