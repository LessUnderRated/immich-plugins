# Data: assets, albums, tags, people, settings, database, files, network, sync, uploads, media writes

Everything the data area (services, repositories, the Drift database, the Store, the HTTP client, sync and uploads)
exposes to plugins. Ids live in code in `lib/domain/utils/plugin_data_ids.dart` (`DataHooks`, `DataEvents`); the call
sites use the facade `lib/domain/utils/plugin_hooks.dart` (`PluginHooks`), host functions live in
`lib/infrastructure/plugins/plugin_api/data/` (`DataPluginServices.build` assembles them).

## How data hooks behave

Every hook below is a normal kernel hook (`contributes.hooks.<id>`: `before` / `instead` / `after`, `HookV1` calls):

* **before** gets `{ "args" }`. `{ "cancel": true, "message"? }` cancels (the caller shows the message, background
  paths such as uploads skip the item), `{ "args": {...} }` changes the arguments the operation runs with. Only the
  argument fields listed as *changeable* are read back; the others are informational.
* **instead** may answer `{ "result": ... }` in the result shape listed and the built-in operation does not run (its
  event is then not emitted either).
* **after** gets `{ "args", "result" }` and may answer `{ "result": ... }`.

Events are emitted after the built-in operation succeeded; subscribe with `contributes.events` (exact names,
`"asset.*"`, or `"*"`).

**Query hooks** (`*.query`) are `after` hooks on lists the UI shows. The result is a JSON list of items with an `id`.
Answer with a list of items or ids: dropping an item hides it, reordering sorts, and where noted, items with an
unknown `id` are built from the JSON (extending the list).

**Not hookable in background isolates.** Device library scans, hashing and the server sync stream run in background
isolates; their start (`sync.run`) and end (`sync.*` events) are hooked from the main isolate, and `db.changed`
reports the tables they wrote. Background (iOS URLSession) uploads are hooked when their tasks are built.

## Shapes

* **AssetLite**: `{ id, localId, remoteId, storage: "local" | "remote" | "merged", type: "IMAGE" | "VIDEO" | "AUDIO" |
  "OTHER", name, checksum, createdAt, updatedAt, width, height, durationMs, isFavorite, isEdited, playbackStyle }`
  plus for device assets `{ orientation, latitude, longitude, cloudId, adjustmentTime }` and for server assets
  `{ ownerId, visibility, stackId, livePhotoVideoId, thumbHash, uploadedAt, deletedAt }`. Dates are ISO 8601 UTC.
  (The kernel's AssetV1 is the richer single-asset form.)
* **Album**: `{ id, kind: "app" | "device" | "remote", name, ... }`. app: `{ description, createdAt, coverAssetId,
  assetCount, assetIds }`; device: `{ updatedAt, assetCount, backupSelection, isIosSharedAlbum, linkedRemoteAlbumId }`;
  remote: `{ description, ownerId, ownerName, createdAt, updatedAt, coverAssetId, isActivityEnabled, order,
  assetCount, isShared }`.
* **Tag**: `{ id, value, name }` (device tags: `id` = `value`, a `/` path such as `Trips/2024`; `name` is its last part).
* **Person**: `{ id, name, birthDate, updatedAt }`. **User**: `{ id, email, name, isAdmin, avatarColor, ... }`.
* **Bulk result** (asset operations): `{ count, ids, unsupported?, unknown?, errors?: [{ ids, message, cancelled? }] }`.
* `source` in asset hook args: `"local"` (device asset, MediaStore), `"remote"` (server asset), `"device"` (Android
  system trash item).

## Hooks

Mutations (cancellable: yes for all, through `before`).

| Hook | Args (changeable in bold) | Result | Call site |
| --- | --- | --- | --- |
| `asset.favorite` | `{ **ids**, **favorite**, source }` | null | device favorite (`DeviceAlbumRepository.setFavorite`), server `AssetService.update` |
| `asset.visibility` | `{ **ids**, **visibility**: "timeline" \| "archive" \| "hidden" \| "locked", source: "remote" }` | null | archive / lock actions |
| `asset.setDate` | `{ **ids**, **dateTime** (ISO with offset), source, dateTakenMs? }` | null | edit date (server), `assets.setDate` (device) |
| `asset.setLocation` | `{ **ids**, **latitude**, **longitude**, source }` | null | edit location |
| `asset.setDescription` | `{ **id** or **ids**, **description**, source }` | `true` | description editor (server), `assets.setDescription` (device) |
| `asset.setRating` | `{ **id**, **rating**, source: "remote" }` | `true` | rating (server) |
| `asset.update` | `{ **ids**, favorite?, visibility?, latitude?, longitude?, dateTime? }` | null | several fields at once |
| `asset.trash` | `{ **ids**, source: "remote" }` | null | move to server trash |
| `asset.restore` | `{ **ids**, source: "remote" \| "device", items? }` | null / `true` (device: system confirmation granted) | restore from server trash / system trash |
| `asset.delete` | `{ **ids**, source, permanent, **trash** (local) }` | local: deleted count; device trash: `true` if granted; remote: null | delete actions, cleanup, system trash "delete forever" |
| `trash.empty` | `{ userId, source: "remote" }` | count | empty server trash |
| `trash.restoreAll` | `{ userId, source: "remote" }` | count | restore all |
| `asset.stack` | `{ **ids**, userId }` | null | stack |
| `asset.unstack` | `{ **stackIds** }` | null | unstack |
| `asset.edit` | `{ **id**, **edits**: [{ action, parameters }], source: "remote" }` | null | server non-destructive edits (device edits: editor area `editor.save`) |
| `asset.move` | `{ **ids**, **relativePath**, source: "local" }` | moved count | move to device folder |
| `asset.private` | `{ **ids**, **private** }` | changed count | Private tab add / remove |
| `private.hide` | `{ **ids**, mode: "files" \| "vault" }` | files: hidden ids; vault: count | hide from every app |
| `private.unhide` | `{ **files**: [{ file, originalPath, name, ... }], mode }` | restored count | unhide |
| `private.delete` | `{ **files**, mode }` | null | delete hidden files |
| `album.create` | `{ kind, **name**, **assetIds**, **description** (remote), ownerId? }` | Album | create album (app, remote) |
| `album.rename` | `{ kind, **id**, **name** }` | app: null; remote: Album | rename |
| `album.update` | `{ kind, **id**, **name**?, **description**?, **coverAssetId**?, **isActivityEnabled**?, **order**? }` | app: null; remote: Album | cover, description, order, activity |
| `album.delete` | `{ kind, **id** }` | null | delete album |
| `album.addAssets` | `{ kind, **id**, **assetIds** }` | app: added count; remote: `{ added, failed }` | add to album |
| `album.removeAssets` | `{ kind, **id**, **assetIds** }` | removed count | remove from album |
| `album.share` | `{ kind: "remote", **id**, **userIds** }` | null | share |
| `album.unshare` | `{ kind: "remote", **id**, **userId** }` | null | remove user |
| `album.setBackup` | device album JSON with **backupSelection**, **linkedRemoteAlbumId** | null | backup album selection |
| `tag.create` | `{ **values**, source: "device" \| "remote" }` | `[Tag]` | create tags |
| `tag.delete` | `{ **id**, source: "device" }` | null | delete tag |
| `tag.assign` | `{ **assetIds**, **tagIds**, source }` | count | tag assets |
| `tag.unassign` | `{ **tagId**, **assetIds**, source }` | count | untag |
| `person.update` | `{ **id**, **name**? \| **birthDate**? }` | rows updated | rename person, birthday |
| `partner.add` / `partner.remove` / `partner.update` | `{ sharedById, sharedWithId, **inTimeline** (update) }` | null | partner sharing |
| `sharedLink.create` | `{ **albumId**, **assetIds**, **showMetadata**, **allowDownload**, **allowUpload**, **description**, **slug**, **expiresAt**, hasPassword }` | link `{ id, key, slug, type, ... }` or null | create shared link |
| `sharedLink.update` / `sharedLink.delete` | `{ id, ...changed fields }` / `{ id }` | link / null | edit / delete link |
| `user.update` | `{ field: "profileImage", name, size }` | path | profile picture |
| `activity.add` | `{ albumId, **assetId**, type: "comment" \| "like", **comment** }` | `{ id, albumId, assetId, type, comment, createdAt, userId, userName }` | comments and likes |
| `activity.remove` | activity JSON | null | delete comment / like |
| `settings.set` | `{ key, store: "app" \| "store", **value**, previous, reset?, keys? (reset of several) }` | null | every write of an app setting or Store key (`value: null` = reset) |
| `downloadsRule.set` | `{ **enabled**, **targetName**, **targetRelativePath** }` | null | Download folder rule |
| `downloads.organize` | `{ **ids**, **relativePath**, force }` | moved count | moving new files out of Download |
| `download.assets` | `{ **ids**, assets: [AssetLite] }` | `[bool]` queued | download server assets into the gallery |
| `files.download` | `{ id, plugin, **url**, **path**, **headers** }` | `{ id, path, size, sha256, resumed }` | `files.download` |
| `media.save` | `{ kind: "image" \| "video", **folder**, **name**, **mimeType**, **path**, size, **createdAt** }` | `{ outcome, assetId, createdId }` | every new gallery item from the editor or a plugin |
| `media.replace` | `{ assetId, **path**, size, **width**, **height** }` | `{ outcome, assetId, createdId }` | editor replace, `media.replace` |
| `upload.asset` | `{ kind: "asset" \| "livePhotoVideo" \| "shareIntent" \| "background", localId, asset: AssetLite, **path**, **fileName**, **fields** (multipart fields), group? }` | foreground: `{ success, cancelled, remoteId, error, status }`; background: `{ taskId, fileName, fields }` | before every upload; cancel = skip this asset; `instead` may upload by itself and answer `{ remoteId }` |
| `backup.start` | `{ mode: "foreground" \| "background", userId, sequential? }` | null | backup run starts |
| `backup.stop` | `{ mode: "background" }` | tasks left | background backup cancelled |
| `sync.run` | `{ kind: "local" \| "hash" \| "remote", **full** (local), enqueue? }` | remote: success bool | a new sync starts (joining a running one does not run the hook) |
| `net.request` | `{ **method**, **url**, **headers**, **body** \| **bodyBase64**, bodyType: "none" \| "text" \| "bytes" \| "stream", contentLength, **captureResponse** }` | `{ status, headers, reasonPhrase, contentLength, body? \| bodyBase64? }` (body only with `captureResponse` or from `instead`) | every request of the app's HTTP client: server API, uploads, sync, map styles |
| `db.execute` | `{ **sql**, **args**, database, plugin }` | `{ rowsAffected, tables }` | `db.execute` / `db.batch` from any plugin |

Queries (`after` changes the list; not cancellable).

| Hook | Args | Items | Extendable | Call site |
| --- | --- | --- | --- | --- |
| `album.query` | `{ kind: "app" }` / `{ kind: "device", sortBy }` / `{ kind: "remote" }` | Album | app albums | album lists (library, pickers, gallery view) |
| `album.assets.query` | `{ kind: "remote", id }` | AssetLite | no | assets of a server album |
| `search.query` | `{ filter: { context, filename, description, ocr, language, assetId, tags, people, country, state, city, make, model, takenBefore, takenAfter, rating?, isNotInAlbum, isArchive, isFavorite, mediaType }, **page** }` | result `{ assets: [AssetLite], nextPage }` (a full hook: `instead` can implement search, e.g. on the device) | yes (AssetLite builds assets) | search page |
| `person.query` | `{ minFaces }` | Person | no | people list |
| `place.query` | `{ userId }` | `{ id, name, assetId }` | yes | places |
| `map.query` | `{ north, east, south, west }` | `{ id, assetId, latitude, longitude }` | yes | map markers |
| `memory.query` | `{ scope: "lane" \| "all", ownerId, onlyFavorites? }` | `{ id, type, year, personName, memoryAt, isSaved, assetIds, ... }` | no | memories |
| `partner.query` | `{ userId, direction }` | `{ id, name, email, inTimeline, ... }` | no | partners |
| `tag.query` | `{ source: "device" \| "remote" }` | Tag | yes | tag lists |
| `sharedLink.query` | `{}` | link | no | shared links |
| `folder.query` | `{ scope: "paths", order }` / `{ scope: "assets", path, order }` | `{ id, path }` / AssetLite | paths: yes | server folders |
| `trash.query` | `{ source: "device" }` | `{ id, name, type, expiresAt, takenAt }` | no | Android system trash |
| `private.query` | `{ mode: "files" }` | `{ id (= file), file, originalPath, name, ... }` | no | Private tab hidden files |

## Events

| Event | Payload | Notes |
| --- | --- | --- |
| `asset.favorited` | hook args `{ ids, favorite, source }` | |
| `asset.visibilityChanged`, `asset.dateChanged`, `asset.locationChanged`, `asset.descriptionChanged`, `asset.ratingChanged`, `asset.updated` | hook args | |
| `asset.trashed` | `{ ids, source }` | |
| `asset.restored` | `{ ids, source }`; restore-all: `{ userId, all: true, count }` | |
| `asset.deleted` | `{ ids, source, permanent, trash? }` (local: the ids really deleted) | use it to clean per-asset plugin data |
| `asset.stacked`, `asset.unstacked`, `asset.edited`, `asset.moved` (`+ moved`), `asset.privateChanged` (`+ changed`) | hook args | |
| `asset.uploaded` | `{ localId, remoteId, kind }` | foreground and background uploads |
| `asset.downloaded` | `{ remoteId, localId, fileName }` | server asset saved into the gallery |
| `trash.emptied` | `{ userId, source, count }` | |
| `album.created` | Album | |
| `album.renamed`, `album.updated`, `album.deleted`, `album.shared`, `album.unshared`, `album.backupChanged` | hook args | |
| `album.assetsAdded` / `album.assetsRemoved` | `{ kind, id, assetIds, added \| removed, failed? }` | |
| `tag.created` (`+ tags`), `tag.deleted`, `tag.assigned` (`+ count`), `tag.unassigned` (`+ count`) | hook args | |
| `person.updated`, `partner.added`, `partner.removed`, `partner.updated`, `sharedLink.created`, `sharedLink.updated`, `sharedLink.deleted`, `user.updated`, `activity.added`, `activity.removed` | hook args / created item | |
| `private.hidden` (`{ ids, mode }`), `private.unhidden`, `private.deleted` | | |
| `settings.changed` | `{ key, store, value, previous, reset? }` | every app setting and Store key |
| `downloadsRule.changed`, `downloads.organized` (`+ moved`) | | |
| `download.started`, `download.completed`, `download.failed` (`+ error`), `download.cancelled` | `{ id, plugin, url, path, received, total, progress, state }` | `files.download` |
| `download.progress` | same | at most every 250 ms per download (throttled) |
| `media.saved` / `media.replaced` | hook args + `{ outcome, assetId, createdId }` | |
| `media.restored` | `{ assetId }` | |
| `upload.started`, `upload.completed` (`+ remoteId`), `upload.failed` (`+ error, status`), `upload.skipped` (`+ message`) | `{ kind, localId, fileName }` | |
| `upload.progress` | `{ kind, localId, fileName, progress \| bytes + total }` | throttled |
| `backup.started` / `backup.stopped` | `{ mode, userId?, cancelled?, remaining? }` | |
| `sync.started` / `sync.completed` / `sync.failed` | `{ kind: "local" \| "hash" \| "remote", full?, success?, error? }` | a finished local sync is the moment to reconcile per-asset data with the library |
| `net.completed` | `{ method, url, status, durationMs }` | every request of the app's client (only while someone listens) |
| `db.changed` | `{ database: "main", tables: [names] }` | coalesced over 250 ms; includes writes from background isolates |

## Host functions

All take a JSON argument array; failures are `{ "success": false, "status", "message" }` with 400 (bad arguments),
401 (no user), 403, 404, 408, 409, 415, 422 (checksum), 499 (cancelled), 501 (not available on this device or
build), 503 (no server). Relative paths are inside the plugin's data folder; absolute paths are used as given.

### `db.*` (raw database)

| Name | Args | Result |
| --- | --- | --- |
| `db.query` | `[sql, args?, { database: "main" \| "logs" }]` | `[{ column: value }]`; blobs as base64; args: null, bool, number, string, `{ "blob": base64 }`, lists/objects as JSON text |
| `db.execute` | `[sql, args?, { database?, tables? }]` | `{ rowsAffected, tables }`. Writes to app tables refresh every app query at once (Drift is told which tables changed, from the SQL or `tables`); DDL refreshes everything. Plugins may create their own tables. |
| `db.batch` | `[[{ sql, args? }], { database? }]` | `{ results, tables }` in one transaction (all or nothing) |
| `db.tables` | `[{ database? }]` | `[{ name, type, sql, managed, columns: [{ name, type, notNull, defaultValue, primaryKey }] }]` |
| `db.notify` | `[tables?, { database? }]` | refreshes app queries on those tables (all when empty) |

### `settings.*`

| Name | Args | Result |
| --- | --- | --- |
| `settings.get` | `[key]` | value |
| `settings.set` | `[key, value]` | `{ key, value }`; `null` resets; runs `settings.set`, emits `settings.changed`; the UI follows at once |
| `settings.reset` | `[key]` | `{ key, value }` |
| `settings.list` | `[{ prefix? }]` | `[{ key, type, value, default, values? (enum names), writable, sensitive? }]` |

Keys. App settings (`app.<name>`): `themePrimaryColor`, `themeMode`, `themeDynamic`, `themeColorfulInterface`,
`imagePreferRemote`, `imageLoadOriginal`, `viewerLoopVideo`, `viewerLoadOriginalVideo`, `viewerAutoPlayVideo`,
`viewerTapToNavigate`, `networkAutoEndpointSwitching`, `networkExternalEndpointList`, `networkCustomHeaders`,
`networkPreferredWifiName`, `networkLocalEndpoint`, `albumSortMode`, `albumIsReverse`, `albumIsGrid`, `backupEnabled`,
`backupUseCellularForVideos`, `backupUseCellularForPhotos`, `backupRequireCharging`, `backupTriggerDelay`,
`backupSyncAlbums`, `timelineTilesPerRow`, `timelineGroupAssetsBy`, `timelineStorageIndicator`,
`timelineSmoothScrubbing`, `logLevel`, `mapShowFavoriteOnly`, `mapRelativeDate`, `mapCustomFrom`, `mapCustomTo`,
`mapIncludeArchived`, `mapThemeMode`, `mapWithPartners`, `cleanupKeepFavorites`, `cleanupKeepMediaType`,
`cleanupKeepAlbumIds`, `cleanupCutoffDaysAgo`, `cleanupDefaultsInitialized`, `shareFileType`, `slideshowRepeat`,
`slideshowDuration`, `slideshowLook`, `slideshowDirection`, `featureMessageSeenRelease`.
Store keys (`store.<name>`): `version` (read only), `currentUser` (read only, user JSON), `deviceId`, `serverUrl`,
`accessToken` (sensitive), `serverEndpoint`, `advancedTroubleshooting`, `enableHapticFeedback`,
`manageLocalMediaAndroid`, `readonlyModeEnabled`, `galleryViews`, `viewerCensor`, `viewerCensorConfig`,
`syncMigrationStatus` (read only).

### `assets.*`, `trash.*`

| Name | Args | Result |
| --- | --- | --- |
| `assets.query` | `[{ source: "local" \| "remote" \| "all" = "local", ids?, type?, favorite?, from?, to?, name? (contains), albumId? (any kind), tag? (with children), hasLocation?, private: "exclude" \| "include" \| "only" = "exclude", visibility = "timeline" \| "archive" \| "hidden" \| "locked" \| "any", trashed?, orderBy: "createdAt" \| "updatedAt" \| "name", order: "desc" \| "asc", limit = 100 (max 5000), offset }]` | `[AssetLite]` (`all`: device assets plus server assets without a device copy) |
| `assets.count` | `[filter]` | int |
| `assets.get` | `[id]` | AssetLite + `{ exif?, tags, private, albumIds }` |
| `assets.file` | `[id, { motion? }]` | `{ path, size, name }` (device file) |
| `assets.favorite` | `[ids, bool]` | bulk result (device and server) |
| `assets.archive` | `[ids, bool]` | bulk result (server) |
| `assets.setVisibility` | `[ids, visibility]` | bulk result (server) |
| `assets.trash` | `[ids]` | bulk result (device: system trash; server: server trash) |
| `assets.restore` | `[ids]` | bulk result (system trash ids and server trash) |
| `assets.delete` | `[ids, { permanent? }]` | bulk result (without `permanent` same as trash; system trash ids are deleted for good) |
| `assets.setDate` | `[ids, isoDateTime]` | bulk result (device: EXIF date and MediaStore date taken) |
| `assets.setLocation` | `[ids, { latitude, longitude }]` | bulk result (device: EXIF GPS) |
| `assets.setDescription` | `[ids, text]` | bulk result (device: EXIF image description) |
| `assets.setRating` | `[ids, 0-5 \| null]` | bulk result (server) |
| `assets.stack` / `assets.unstack` | `[ids]` (first is primary) / `[asset or stack ids]` | bulk result / `{ count, stackIds }` (server) |
| `assets.move` | `[ids, folder]` | bulk result (device; folder like `Pictures/Trips`) |
| `assets.setPrivate` | `[ids, bool]` | `{ count, ids }` |
| `assets.tag` / `assets.untag` | `[ids, tags]` | `{ count }` (device tags) |
| `assets.tags` | `[id]` | `[Tag]` |
| `trash.list` | `[{ source: "device" \| "remote" = "device" }]` | device: `[{ id, name, type, expiresAt, takenAt }]`; remote: `[AssetLite]` |
| `trash.empty` | `[{ source }]` | `{ count }` (device: one system confirmation) |

### `albums.*` (data operations; opening and picking albums is the library area's)

| Name | Args | Result |
| --- | --- | --- |
| `albums.list` | `[{ kind: "app" \| "device" \| "remote" \| "all" = "all" }]` | `[Album]` |
| `albums.get` | `[id]` | Album |
| `albums.assets` | `[id, { limit?, offset? }]` | `[AssetLite]` |
| `albums.containing` | `[assetId]` | `[Album]` |
| `albums.create` | `[name, { kind = "app", assetIds?, description? }]` | Album (device: moves `assetIds` into `Pictures/<name>/`) |
| `albums.rename` | `[id, name]` | Album (device: moves the files into a sibling folder with the new name) |
| `albums.delete` | `[id]` | null (app, remote) |
| `albums.addAssets` / `albums.removeAssets` | `[id, assetIds]` | `{ added, failed? }` / `{ removed }` (device add = move into the folder) |
| `albums.setCover` / `albums.setDescription` | `[id, assetId]` / `[id, text]` | Album (app, remote) |
| `albums.setOrder` | `[id, "asc" \| "desc"]` | Album (remote) |
| `albums.share` / `albums.unshare` | `[id, userIds]` / `[id, userId]` | null (remote) |

### `tags.*` (device tags, any asset id)

`tags.list []` -> `[Tag]`; `tags.create [values]` -> `[Tag]`; `tags.delete [id]`; `tags.assign [assetIds, tagIds]` ->
`{ count }` (creates missing tags); `tags.unassign [tagId, assetIds]` -> `{ count }`; `tags.forAsset [assetId]` ->
`[Tag]`; `tags.assets [tagId, { includeChildren? }]` -> `[assetId]`.

### `people.*` (server people as synced)

`people.list [{ minFaces = 1 }]` -> `[Person]`; `people.get [id]`; `people.forAsset [assetId]`;
`people.faces [assetId]` -> `[{ id, personId, imageWidth, imageHeight, x1, y1, x2, y2, sourceType }]`;
`people.assets [id]` -> `[assetId]`; `people.rename [id, name]`; `people.setBirthDate [id, isoDate]`.

### `files.*` (beyond `readFile` / `writeFile` / `listFiles` / `deleteFile`)

| Name | Args | Result |
| --- | --- | --- |
| `files.read` | `[path, { encoding: "utf8" \| "base64", offset?, length? }]` | string |
| `files.write` | `[path, data, { encoding?, append? }]` | `{ path, size }` (objects are written as JSON) |
| `files.stat` / `files.exists` | `[path]` | `{ path, name, type, size, modifiedAt }` / bool |
| `files.list` | `[dir?, { recursive? }]` | entries |
| `files.mkdir` / `files.copy` / `files.move` / `files.delete` | `[path]` / `[from, to]` / `[from, to]` / `[path, { recursive? }]` | |
| `files.hash` | `[path, { algorithm: "sha256" \| "sha1" \| "md5" }]` | hex |
| `files.zip` / `files.unzip` | `[[paths], zipPath]` / `[zipPath, dir]` | `{ path, size }` / `{ files }` |
| `files.paths` | `[]` | `{ data, cache, temp, documents, support, external? }` |
| `files.download` | `[url, { path?, sha256?, headers?, resume = true, background = false, timeoutSeconds = 60, id? }]` | `{ id, path, size, sha256, resumed }`; `background` answers `{ id, path }` at once. Resumes `<path>.part` with a range request, verifies `sha256` (422 and the file is deleted on mismatch), progress through `download.*` events |
| `files.cancelDownload` | `[id, { discard? }]` | bool (the partial file stays for a resume unless `discard`) |
| `files.downloads` | `[{ all? }]` | running downloads |

### `net.*` (beyond `httpRequest`)

| Name | Args | Result |
| --- | --- | --- |
| `net.fetch` | `[url, { method, headers, body \| bodyBase64 \| bodyFile, multipart: { fields, files: [{ field, path, fileName?, contentType? }] }, responseType: "text" \| "json" \| "base64" \| "file", responsePath?, timeoutSeconds = 120, followRedirects = true, maxRedirects = 5, useAppClient = false }]` | `{ ok, status, headers, body \| path, size, durationMs }`; `useAppClient` uses the app's client (its TLS settings, through `net.request`) |
| `net.api` | `[method, path, { query?, body?, headers? }]` | `{ ok, status, headers, body }`: the Immich server API with the app's login (503 without a server) |
| `net.server` | `[]` | `{ endpoint, serverUrl, loggedIn, headers }` |
| `net.status` | `[]` | `{ connected, cellular, wifi, vpn, unmetered }` |

### `media.*` (gallery writes; also used by the editor)

| Name | Args | Result |
| --- | --- | --- |
| `media.saveImage` | `[{ path \| bytesBase64 \| rgba + width + height, folder?, name?, mimeType?, createdAt?, latitude?, longitude?, description? }]` | `{ outcome: "saved", assetId, createdId }` in `Pictures/<folder>/` (or the folder as given when it starts with `DCIM/`, `Pictures/`, ...) |
| `media.saveVideo` | `[{ path, folder?, name?, createdAt?, latitude?, longitude?, description? }]` | same, in `Movies/<folder>/` |
| `media.replace` | `[assetId, { path \| bytesBase64 \| rgba + width + height, width?, height? }]` | `{ outcome: "replaced" \| "savedCopy", assetId, createdId? }`. JPEG/PNG photos are replaced in place through the editor's base (re-encoded to the asset's format when needed), the original is kept; other photo formats get a copy next to them; videos are replaced in place with their original kept |
| `media.restoreOriginal` | `[assetId]` | `{ outcome: "restored" \| "unchanged", assetId }` (also drops editor edits) |

Items created by `media.*` and the editor are announced on `MediaWriter.created`, so device workflows skip them.

### `downloads.*`

`downloads.assets [ids]` -> `{ queued, unknown }` (server assets into the gallery); `downloads.rule []`;
`downloads.setRule [{ enabled?, targetName?, targetRelativePath? }]`; `downloads.organize [{ force? }]` -> `{ moved }`.

### `sync.*`, `upload.*` (backup control `backup.*` is the shell area's)

| Name | Args | Result |
| --- | --- | --- |
| `sync.run` | `[{ kind: "local" \| "hash" \| "remote" \| "all" = "local", full? }]` | `{ kind, success }` after the sync finished |
| `sync.status` | `[]` | `{ local, remote, hash, cloudIds: "idle" \| "syncing" \| "success" \| "error", error, running: { local, remote, hash, cloudIds, linkedAlbums, websocket } }` |
| `upload.assets` | `[ids]` | `{ uploaded: [{ localId, remoteId }], failed: [{ localId, error }] }` (runs `upload.asset` per asset) |
| `upload.files` | `[paths]` | `{ uploaded: [{ path, remoteId }], failed }` |
| `upload.cancel` | `[]` | stops manual uploads after the current file |

## Native channel methods used (`immich/device_media`)

Existing: `moveToFolder`, `overwriteImage`, `listTrashed`, `trashThumbnail`, `restoreTrashed`, `deleteTrashed`,
`privateHide`, `privateUnhide`, `privateDelete`, `exportToFiles`. Needed from the native area:

* `overwriteMedia { id, sourcePath, video: bool }` -> true: overwrite a video (or image) item in place through
  `ContentResolver.openOutputStream(uri, "wt")` on the `Video`/`Images` collection, with the same write-permission
  prompt flow as `overwriteImage` (errors `write_denied`, `write_failed`).
* `updateMetadata { items: [{ id, video }], dateTakenMs?, dateTime?, latitude?, longitude?, description? }` -> count:
  write EXIF `DateTimeOriginal`/`OffsetTimeOriginal`, GPS tags and `ImageDescription` (photos, via `ExifInterface` on
  a `rw` file descriptor) and `MediaStore.MediaColumns.DATE_TAKEN` (photos and videos), with the same permission flow.
  Until it exists, `assets.setDate` / `setLocation` / `setDescription` on device assets answer 501.
