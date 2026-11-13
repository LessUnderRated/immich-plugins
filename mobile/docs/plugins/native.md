# Native (Android plugin host)

The Kotlin API plugins compile against lives in `android/app/src/main/kotlin/app/alextran/immich/plugins/api/`
(`ImmichPlugin.kt`, `NativeApi.kt`, `VideoApi.kt`, `ImmichNative.kt`). Those files are the exact reference for every
signature; this page is the map.

## Entry points

| API | How a plugin gets it |
| --- | --- |
| `PluginHost` (v1: `call`, `callHost`, `runOnUi`, `sendEvent`; v2: `callHostAsync`, `emit`, `hostApiVersion`) | passed to `ImmichPlugin.call` and `createView` |
| `NativeHost` | `host.native` (Kotlin) or `ImmichNative.of(host)` (works for Java plugins, which cannot see Kotlin interface defaults) |
| Version and features | `ImmichNative.apiVersion()`, `ImmichNative.features()`, `native.hasFeature("video.capture")` |
| Load/unload callbacks | implement `ImmichPluginLifecycle` (`onLoad`, `onUnload`) |

Existing plugins keep working unchanged: the v1 interfaces kept every signature, and new members have defaults.

## `NativeHost` members

| Member | What it does |
| --- | --- |
| `events` | `emit(event, payloadJson)` on the app's plugin event bus; `addListener(pattern, listener)` for app events (`asset.*`, `app.resumed`, ...) |
| `lifecycle` | current activity, foreground state, activity lifecycle callbacks (created, started, resumed, paused, stopped, destroyed, configuration changes) |
| `intents` | incoming share/view intents and deep links as events, plus a handler that can consume or change them |
| `permissions` | runtime permission requests with the result delivered back to the plugin (the activity forwards results) |
| `activityResults` | start activities for a result and get it back |
| `notifications` | channels, post/update/cancel, actions that call back into the plugin; the app's task progress notification with a cancel action |
| `work` | scheduled and periodic plugin method calls that keep running when the app is closed (WorkManager where available) |
| `media` | MediaStore writes: save images/videos as new items, replace an item (original backed up), update metadata |
| `video` | video sessions of the players on screen: position, state, frame rect, frame capture, plugin overlay views inside the player (`VideoApi.kt`) |
| `views` | plugin view helpers: theme info (dark/light, colour scheme, font) and content-height reporting for inline views |
| `plugins` | calls into other plugins natively |
| `hostFunctions` | register host functions implemented natively (reachable from Dart and other plugins) |
| `binaryMessenger`, `flutterEngine` | the app's Flutter engine, for advanced plugins that ship their own channels |
| `log`, `runGuarded`, `setLoadOnStartup` | app log, crash isolation (a throwing plugin never crashes the app), load at app start |

## Channels between Dart and the native host

| Channel | Methods |
| --- | --- |
| `immich/dex_plugins` | `load`, `unload`, `call` (Dart → native); `host`, `event` (native → Dart) |
| `immich/plugin_native` | native API info, native host functions, event forwarding (`lib/infrastructure/plugins/plugin_api/native/plugin_native_channel.dart`) |
| `immich/plugin_video` | `registerSession`, `updateSession`, `unregisterSession`, `captureFrame`, `extractFrame`, `attachOverlay`, `detachOverlay` (contract in `viewer.md`) |
| `immich/device_media` | media writes used by `media.*` host functions, including `overwriteMedia` and `updateMetadata` |
