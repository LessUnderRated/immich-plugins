# Library: albums, people, places, map, search, folders, partners, shared links, locked and private folders

Everything the library area exposes to plugins. Ids live in code in
`lib/infrastructure/plugins/plugin_api/library/library_ids.dart` (`LibraryPages`, `LibrarySlots`, `libraryBuiltins`,
`LibraryHooks`, `LibraryEvents`); host functions in `library_host_functions.dart`; JSON shapes in `library_json.dart`;
map layers in `map_plugin_layers.dart`.

Rules (`contributes.builtins.<slot>`: `hide`, `order`, `rename`) work on every slot below that lists built-in ids.
In `order`, `*` marks where unnamed items go; plugin items are named `plugin:<plugin>/<id>`. Built-in `i` (in the
order listed) has order `(i + 1) * 100`; plugin items without `order` go after the built-ins. Hiding a built-in item
also removes its gesture where it has one (`sharedLink.tile.actions`: `edit` = tap, `copy` = long press, `delete` =
swipe).

## Pages and generic slots

Page keys (route name in lower camel case without `Route`): `albums`, `albumOptions`, `appAlbum`, `createAlbum`,
`library`, `localAlbums` (Albums tab), `remoteAlbum`, `peopleCollection`, `person`, `place`, `placeDetail`, `map`,
`mapLocationPicker`, `partner`, `partnerDetail`, `userSelection`, `activities`, `downloadInfo`, `lockedFolder`,
`pinAuth`, `privateGallery` (Private tab), `privateLegacy`, `privateViewer`, `privateFileViewer`, `search`, `folder`,
`sharedLink`, `sharedLinkEdit`.

Every page has these slots (context: `page`, plus the page fields listed below):

| Slot | Kinds | Notes |
| --- | --- | --- |
| `<page>.appBar.actions` | `button`, `toggle` | built-ins per page below |
| `<page>.appBar.menu` | `menuItem`, `toggle` | pages without a ⋮ menu get one when plugins add items |
| `<page>.header` | `section`, `view` | above the content |
| `<page>.footer` | `section`, `view` | below the content |
| `<page>.empty` | `section`, `view`, `replace` | replaces or adds to the empty state |
| `<page>.body` | `replace`, `wrap` | the whole page body |
| `<page>.fab` | `button`, `section` | floating action area |

Pages whose app bar is a shared one render `<page>.appBar.actions` / `.menu` through it: `library`, `albums`
(`ImmichSliverAppBar`), `appAlbum`, `placeDetail`, `partnerDetail`, `lockedFolder` (`MesmerizingSliverAppBar`),
`remoteAlbum` (`RemoteAlbumSliverAppBar`), `person` (`PersonSliverAppBar`). Timeline pages (`remoteAlbum`,
`appAlbum`, `person`, `placeDetail`, `partnerDetail`, `lockedFolder`, `privateGallery` in timeline mode) pass their
key to the `Timeline` widget, which renders `<page>.header` / `.footer` / `.empty` / `.body` and all `timeline.*`
slots (tiles, group headers, selection sheet: see `timeline.md`). The search result grid is the timeline page
`search.results`. The Albums and Private tabs end their app bar with the app menu (`appMenu`: settings gear and ⋮,
slots `app.appBar.actions` / `app.menu`, see `timeline.md`).

## Objects

All JSON. Dates are ISO 8601 UTC strings.

- **Album** `{ "id", "kind": "remote"|"device"|"app", "name", ... }`. Remote: `description`, `ownerId`, `ownerName`,
  `createdAt`, `updatedAt`, `thumbnailAssetId`, `assetCount`, `isShared`, `isActivityEnabled`, `order`
  (`asc`|`desc`). Device: `updatedAt`, `assetCount`, `backupSelection`, `isIosSharedAlbum`, `linkedRemoteAlbumId`.
  App (albums kept by this app on the phone): `createdAt`, `assetCount`, `assetIds`.
- **Person** `{ "id", "name", "birthDate", "updatedAt" }`.
- **Place** `{ "id" (city), "name", "assetId" (cover) }`.
- **User** `{ "id", "name", "email", "isAdmin", "hasProfileImage", "profileChangedAt", "avatarColor",
  "isPartnerSharedBy", "isPartnerSharedWith", "inTimeline" }`.
- **Partner** `{ "id", "name", "email", "hasProfileImage", "profileChangedAt", "avatarColor", "inTimeline" }`.
- **SharedLink** `{ "id", "title", "description", "type": "album"|"individual", "key", "slug", "password",
  "hasPassword", "allowDownload", "allowUpload", "showMetadata", "expiresAt", "thumbAssetId" }`.
- **Folder** `{ "path", "name", "subfolderCount" }` (server folders by original path).
- **Activity** `{ "id", "albumId", "assetId", "type": "comment"|"like", "comment", "createdAt", "user": User }`.
- **PrivateFile** `{ "id" (= path), "path", "thumbPath", "originalPath", "name", "mime", "takenAt", "width",
  "height", "durationMs", "isVideo" }`.
- **Asset** (compact AssetV1) `{ "id", "remoteId", "localId", "type": "IMAGE"|"VIDEO"|"AUDIO"|"OTHER",
  "originalFileName", "checksum", "fileCreatedAt", "fileModifiedAt", "isFavorite", "isEdited", "width", "height",
  "durationMs", "isLocal", "isRemote" }` plus for server assets `"ownerId", "visibility", "thumbhash", "stackId"`.
  Full AssetV1: `assets.get`.
- **SearchFilter** `{ "context", "filename", "description", "ocr", "language", "assetId", "people": [personId],
  "peopleNames": { id: name }, "tags": [{ "id", "value" }], "location": { "country", "state", "city" },
  "camera": { "make", "model" }, "date": { "takenAfter", "takenBefore" }, "rating": null|"unrated"|1..5,
  "display": { "notInAlbum", "archive", "favorite" }, "mediaType": "ALL"|"IMAGE"|"VIDEO", "isEmpty" }`. When a
  plugin passes a filter, missing fields keep their current value.
- **MapSettings** `{ "themeMode": "system"|"light"|"dark", "onlyFavorites", "includeArchived", "withPartners",
  "relativeDays", "timeRange": { "from", "to" } }`.
- **Bounds** `{ "north", "south", "east", "west" }` (degrees).

## Slots by page

| Slot | Kinds | Context | Built-in ids |
| --- | --- | --- | --- |
| `albums.appBar.actions` | `button`, `toggle` | | `create` |
| `albumSelector.sections` | `section` | `scope` | `search`, `filters`, `toolbar`, `list` |
| `albumSelector.filters` | `chip` | `scope`, `mode`, `query` | `all`, `sharedWithMe`, `myAlbums` |
| `albumSelector.toolbar` | `button`, `toggle` | `scope`, `isGrid` | `sort`, `viewMode` |
| `albumSelector.sort` | `menuItem` | `scope`, `mode`, `reverse` | `title`, `assetCount`, `lastModified`, `created`, `mostRecent`, `mostOldest` |
| `albumSelector.tile` | `badge`, `wrap`, `replace` | `scope`, `album`, `isOwner`, `view`: `list`\|`grid` | |
| `albumSelector.tile.actions` | `menuItem` (long press menu) | `scope`, `album`, `isOwner` | `open` (tap), `delete` (swipe, owner) |
| `albumSelector.header`, `.footer`, `.empty` | `section` | `scope` | |
| `albumOptions.sections` | `section`, `tile` | `album`, `isOwner` | `activity` (owner), `people` |
| `albumOptions.people.actions` | `tile` | `album` | `invite` (owner) |
| `albumOptions.user` | `badge`, `wrap`, `replace` | `album`, `user`, `isOwner` | |
| `albumOptions.user.menu` | `menuItem` | `album`, `user` | `leave` (self), `remove` (owner) |
| `appAlbum.appBar.actions` | `button`, `toggle` | `album` | `galleryView`, `menu` (+ legacy `album.appBar` buttons) |
| `appAlbum.appBar.menu` | `menuItem` | `album` | `rename`, `delete` |
| `createAlbum.appBar.actions` | `button` | `title`, `assets` | `create` |
| `createAlbum.fields` | `section` | `title`, `description` | `title`, `description` |
| `createAlbum.actions` | `button` | `assets` | `addPhotos` (once photos are picked) |
| `createAlbum.empty` | `section`, `replace` | | `hint`, `selectPhotos` |
| `library.sections` | `section` | | `actions`, `collections`, `quickAccess` |
| `library.actions` | `button` | | `favorites`, `archived`, `sharedLinks`, `trash` (server trash on) |
| `library.collections` | `tile`, `section` | | `people`, `places`, `onThisDevice`, `memories` |
| `library.quickAccess` | `tile` | `partners` | `folders`, `lockedFolder`, `partners`, `partner:<userId>` per partner |
| `localAlbums.appBar.actions` | `button`, `toggle` | | `downloads`, `findDuplicates`, `newAlbum`, `appMenu` |
| `localAlbums.sections` | `section` | | `appAlbums`, `deviceTitle`, `deviceAlbums` |
| `localAlbums.appAlbum` | `badge`, `wrap`, `replace` | `album` (app) | |
| `localAlbums.appAlbums.empty` | `section`, `replace` | | |
| `localAlbums.deviceAlbum` | `badge`, `wrap`, `replace` | `album` (device) | |
| `localAlbums.deviceAlbums.empty` | `section`, `replace` | | |
| `remoteAlbum.appBar.actions` | `button`, `toggle` | `album`, `isOwner`, `isEditor` | `slideshow`, `activity`, `menu` |
| `remoteAlbum.appBar.menu` | `menuItem` | as above | `editAlbum`, `addPhotos`, `addUsers`, `leaveAlbum`, `toggleOrder`, `createSharedLink`, `options`, `deleteAlbum` (each only where it applies) |
| `remoteAlbum.header` | `section` | `album` | `pendingUploads` |
| `remoteAlbum.pendingUploads` | `section` | `albumId`, `count`, `failed` | (sheet of in-flight uploads) |
| `remoteAlbum.pendingUploads.actions` | `button` | `albumId` | `cancelUploads`, `clearFailed` |
| `remoteAlbum.editDialog` | `section` | `album` | `name`, `description` |
| `peopleCollection.appBar.actions` | `button` | `search` | `search` |
| `peopleCollection.tile` | `badge`, `wrap`, `replace` | `person` | |
| `peopleCollection.tile.actions` | `menuItem` (long press menu) | `person` | `open` (avatar tap), `editName` (name tap) |
| `person.appBar.actions` | `button`, `toggle` | `person` | `options` |
| `person.options` | `tile` | `person` | `editName`, `editBirthday` |
| `place.appBar.actions` | `button` | `search` | `search` |
| `place.sections` | `section` | `search` | `map`, `list` |
| `place.tile` | `badge`, `wrap`, `replace` | `place` | |
| `place.tile.menu` | `menuItem` (long press menu) | `place` | |
| `placeDetail.appBar.actions` | `button`, `toggle` | `place` | |
| `map.appBar.actions` | `button`, `toggle` (floating, top) | `settings` | `back`, `settings` |
| `map.controls` | `button` (floating, above the sheet) | `settings` | `myLocation` (the attribution stays) |
| `map.settings` | `tile`, `section` (settings sheet) | `settings` | `systemTheme`, `darkMode`, `divider`, `favoritesOnly`, `includeArchived`, `withPartners`, `timeRange` |
| `map.overlay` | `section`, `view`, `panel` | `settings`, `bounds`, `zoom` | (floating panels over the map) |
| `mapLocationPicker.appBar.actions` | `button` | `lat`, `lng` | `back` |
| `mapLocationPicker.actions` | `button` | `lat`, `lng` | `useLocation`, `currentLocation` |
| `partner.appBar.actions` | `button` | | `add` |
| `partner.tile` | `badge`, `wrap`, `replace` | `partner` | |
| `partner.tile.actions` | `button` | `partner` | `remove` |
| `partner.empty` | `section`, `replace` | | `message`, `add` |
| `partnerDetail.header` | `section` | `partner` | `inTimeline` |
| `userSelection.appBar.actions` | `button` | `album`, `userIds` | `add` |
| `userSelection.selected` | `chip` | `album`, `user` | |
| `userSelection.user` | `badge`, `wrap`, `replace` | `album`, `user`, `selected` | |
| `activities.appBar.actions` | `button` | `album`, `assetId` | `like` |
| `activities.item` | `badge`, `wrap`, `replace` | `activity` | |
| `activities.footer` | `section` | `album`, `assetId` | `input` |
| `downloadInfo.task` | `badge`, `wrap`, `replace` | `taskId`, `fileName`, `progress`, `status` | |
| `downloadInfo.footer` | `button` | | `clearAll` |
| `lockedFolder.appBar.actions` | `button`, `toggle` | | |
| `pinAuth.actions` | `button` | | `biometric` (when the phone supports it) |
| `privateGallery.appBar.actions` | `button`, `toggle` | `unlocked`, `legacyCount` | `olderItems` (when there are any), `lock` (unlocked), `appMenu` |
| `privateGallery.selection.appBar.actions` | `button` | `selectionCount` | `close`, `selectAll` |
| `privateGallery.selection.actions` | `button` | `files` | `share`, `unhide`, `delete` |
| `privateGallery.timeline.actions` | (selection sheet `private`, see `timeline.md`) | | `share`, `moveToPrivate`, `delete` |
| `privateGallery.header` | `section` | | `fullHiding` (timeline mode) |
| `privateGallery.locked` | `section`, `replace` | `message` | `unlock` |
| `privateGallery.tile` | `badge`, `wrap`, `replace` | `file` | |
| `privateFileViewer.appBar.actions` | `button` | `file` | `share`, `unhide`, `delete` |
| `privateViewer.appBar.actions` | `button` | `id`, `name`, `isVideo` | `restore`, `delete` |
| `search.appBar.actions` | `button`, `toggle` | `filter`, `type` | `searchType` |
| `search.appBar.menu` | `menuItem` | `type` | `context` (smart search on), `filename`, `description`, `ocr` (OCR on) |
| `search.filters` | `chip` | `filter` | `people`, `location`, `tags` (tags on), `camera`, `date`, `mediaType`, `rating` (ratings on), `display` |
| `search.filterSheet` | `section` | `filter`, `sheet` (a `search.filters` id) | (extra content in a filter sheet) |
| `search.suggestions` | `section` | | `illustration`, `quickLinks` |
| `search.quickLinks` | `tile` | | `recentlyTaken`, `recentlyAdded`, `videos`, `favorites` |
| `search.results.header` | `section`, `view` | `filter`, `count`, `nextPage` | (result provider sections: a plugin renders its own results here) |
| `search.results.footer` | `section` | `filter`, `count` | `noMoreResults` |
| `search.empty` | `section`, `replace` | `filter` | `noResults` |
| `folder.appBar.actions` | `button` | `folder`, `order` | `sort` |
| `folder.header` | `section` | `folder` | `path` |
| `folder.subfolder` | `badge`, `wrap`, `replace` | `folder` | |
| `folder.asset` | `badge`, `wrap`, `replace` | `asset`, `folder` | |
| `sharedLink.tile` | `badge`, `wrap`, `replace` | `link` | |
| `sharedLink.tile.actions` | `menuItem` | `link` | `edit`, `copy`, `delete` |
| `sharedLinkEdit.fields` | `section` | form (see `action.sharedLinkEdit.submit`) | `title`, `link` (editing), `description`, `password`, `slug`, `showMetadata`, `allowDownload`, `allowUpload`, `expiry` |
| `sharedLinkEdit.actions` | `button` | form | `delete` (editing), `submit` |
| `sharedLinkEdit.created` | `section` | `url` | `link`, `done` |

Tile decorations (`badge`, `wrap`, `replace`) are app-rendered JSON UI (`ui` / `uiMethod`), never a native view per
tile. `albumSelector` is also the "add to album" picker of the viewer and the partner sheet (`scope: "picker"`) and
of `albums.pick` (`scope: "plugin"`); use `when: { "scope": "albums" }` to target only the album list page.

## Hooks

Built-in actions: every built-in id above that does something when tapped runs through `action.<page>.<item>`
(`page` = page key or `albumSelector`). Arguments are `{ "page", "item", ...extra }`; the result is none.
`before` may cancel (`{ "cancel": true, "message"? }`, the message shows in a snackbar) and, where marked ✎, change
the arguments the action then uses; `instead` replaces the action; `after` runs once it finished.

| Hook | Extra args |
| --- | --- |
| `action.albums.create`, `action.albums.refresh` | |
| `action.albumSelector.open`, `.delete` | `scope`, `album` |
| `action.albumSelector.all`, `.sharedWithMe`, `.myAlbums` | `scope`, `mode` |
| `action.albumSelector.title`, `.assetCount`, `.lastModified`, `.created`, `.mostRecent`, `.mostOldest` | `scope`, `mode`, `reverse` |
| `action.albumSelector.viewMode` | `scope`, `isGrid` (new value) |
| `action.albumSelector.createAlbum` ✎ | `scope`: `selection`\|`viewer`, `title`, `assets` |
| `action.albumOptions.activity` | `album`, `enabled` |
| `action.albumOptions.invite`, `.leave` | `album` |
| `action.albumOptions.remove` | `album`, `user` |
| `action.appAlbum.rename`, `.delete` | `album` |
| `action.createAlbum.create` ✎ | `title`, `description`, `assets` |
| `action.createAlbum.selectPhotos`, `.addPhotos` | `assets` |
| `action.library.<id>` (`favorites`, `archived`, `sharedLinks`, `trash`, `people`, `places`, `onThisDevice`, `memories`, `folders`, `lockedFolder`, `partners`) | |
| `action.library.partner` | `partner` |
| `action.localAlbums.downloads`, `.findDuplicates`, `.newAlbum` | |
| `action.localAlbums.openAppAlbum`, `.openDeviceAlbum` | `album` |
| `action.remoteAlbum.<id>` (`editAlbum`, `addPhotos`, `addUsers`, `toggleOrder`, `createSharedLink`, `options`, `deleteAlbum`, `activity`) | `album` |
| `action.remoteAlbum.pendingUploads` | `albumId`, `count` |
| `action.remoteAlbum.cancelUploads`, `.clearFailed` | `albumId` |
| `action.peopleCollection.search` | `open` |
| `action.peopleCollection.open`, `.editName` | `person` |
| `action.person.options`, `.editName`, `.editBirthday` | `person` |
| `action.place.search` | `open` |
| `action.place.map` | |
| `action.place.open` | `place` |
| `action.map.back`, `.settings`, `.myLocation` | |
| `action.map.<setting>` (`systemTheme`, `darkMode`, `favoritesOnly`, `includeArchived`, `withPartners`, `timeRange`) | `value` (new value; `timeRange`: days, `{ from, to }`, `"custom"` or `"relative"`) |
| `action.mapLocationPicker.back`, `.currentLocation` | |
| `action.mapLocationPicker.useLocation` ✎ | `lat`, `lng` |
| `action.partnerDetail.inTimeline` | `partner`, `enabled` (new value) |
| `action.userSelection.add` ✎ | `album`, `userIds` |
| `action.activities.comment` ✎ | `album`, `assetId`, `comment` |
| `action.activities.delete`, `.openAsset` | `activity` |
| `action.downloadInfo.cancel` | `taskId`, `fileName`, `progress` |
| `action.downloadInfo.clearAll` | `taskIds` |
| `action.pinAuth.biometric` | |
| `action.privateGallery.unlock`, `.lock`, `.olderItems`, `.fullHiding`, `.close`, `.selectAll` | |
| `action.privateGallery.share`, `.unhide`, `.delete` | `files` |
| `action.privateGallery.open` | `file` |
| `action.privateLegacy.open` | `id`, `name`, `isVideo` |
| `action.privateFileViewer.share`, `.unhide`, `.delete` | `file` |
| `action.privateViewer.restore`, `.delete` | `id`, `name`, `isVideo` |
| `action.search.context`, `.filename`, `.description`, `.ocr` | `type` |
| `action.search.<filter>` (`people`, `location`, `tags`, `camera`, `date`, `mediaType`, `rating`, `display`) | `filter` |
| `action.search.recentlyTaken`, `.recentlyAdded`, `.videos`, `.favorites` | |
| `action.folder.sort` | `order` (new: `asc`\|`desc`) |
| `action.folder.openFolder` | `folder` |
| `action.folder.openAsset` | `asset`, `folder` |
| `action.sharedLink.edit`, `.copy`, `.delete` | `link` |
| `action.sharedLinkEdit.copy`, `.share` | `url` |
| `action.sharedLinkEdit.submit`, `.delete` | `link` (null when creating), `albumId`, `assetIds`, `description`, `password`, `slug`, `showMetadata`, `allowDownload`, `allowUpload`, `expiresAt` |

Actions of the selection sheets and of shared widgets (`PartnerAddAction`, `PartnerRemoveAction`, the like button,
share / delete / move to private) run through the timeline area's `action.<actionId>` hooks (`timeline.md`). Data
changes behind these actions (album update, person update, shared link create, ...) also run through the data
area's hooks (`data.md`), so a plugin can act at either level.

UI flows:

| Hook | Args | Result | Cancellable |
| --- | --- | --- | --- |
| `search.apply` | `{ "filter": SearchFilter, "previous": SearchFilter }`, fired for every new filter of the search page (text, chips, pre-filter) | none | yes; `before` may change `filter` ✎ |
| `private.unlock` | `{}` | `true` to unlock | yes (refuses, message shown on the lock screen); `instead` may authenticate on its own |
| `lockedFolder.autoLock` | `{ "reason": "paused" }` | none | yes (the folder stays open) |
| `map.featureTap` | `{ "plugin", "layer", "featureId", "feature", "lat", "lng", "data", "action" }` | none | yes (the feature's action does not run); `instead` replaces it |

Page views: `after` filters, sorts or extends the list a page is about to show, after the page's own search text,
filters and sort (the data area's `album.query`, `person.query`, `place.query`, `map.query`, `partner.query`,
`sharedLink.query`, `folder.query`, `private.query` and `search.query` run first, at the source). `after` gets
`args` (the fields below plus `count`) and `result`: `[item]`, and answers `{ "result": [item or id] }`: known ids
keep the original objects (a subset filters, another order sorts); unknown items extend the list where marked +.
`instead` may answer the whole list. Not cancellable (a failing plugin leaves the list unchanged). While a plugin
is asked, the list shows nothing rather than items it may hide.

| Hook | Args | Items |
| --- | --- | --- |
| `albumSelector.list.query` | `scope`, `filter`: `{ query, mode }`, `sort`: `{ mode, reverse }` | Album (remote) |
| `albumOptions.users.query` | `album` | User |
| `localAlbums.appAlbums.query` | | Album (app) |
| `localAlbums.deviceAlbums.query` | | Album (device) |
| `peopleCollection.list.query` | `search` | Person + |
| `place.list.query` | `search` | Place + |
| `map.markers.query` | `bounds` | `{ "id", "assetId", "lat", "lng" }` + |
| `folder.subfolders.query` | `folder` | Folder with `id` = `path/name` |
| `folder.assets.query` | `folder` | Asset |
| `partner.list.query` | `direction` | Partner |
| `sharedLink.list.query` | | SharedLink |
| `activities.list.query` | `album`, `assetId` | Activity |
| `userSelection.users.query` | `album` | User |
| `privateGallery.files.query` | | PrivateFile |

Search results: plugins contribute results three ways. `search.query` (data area) filters, sorts, extends or
replaces each result page (`{ assets, nextPage }`); `search.results.header` sections render a plugin's own result
groups (JSON UI with `assetThumbnail` nodes, `openAsset` commands) for the current `filter`; `search.apply` rewrites
or redirects the query.

## Events

| Event | Payload | Throttle |
| --- | --- | --- |
| `album.opened` | `{ "album" }` (remote album page) | |
| `albums.filterChanged` | `{ "scope", "mode", "query" }` | |
| `albums.sortChanged` | `{ "scope", "mode", "reverse" }` | |
| `albums.viewModeChanged` | `{ "scope", "isGrid" }` | |
| `person.opened` | `{ "person" }` | |
| `place.opened` | `{ "place" }` (city) | |
| `partner.opened` | `{ "partner" }` | |
| `folder.opened` | `{ "folder" }` (null for the root) | |
| `map.opened` | `{ "initialLocation": { lat, lng } \| null }` | |
| `map.moved` | `{ "bounds", "zoom" }` | after the camera settles (500 ms debounce) |
| `map.settingsChanged` | `{ "key", "value", "settings": MapSettings }` | |
| `map.markerTapped` | `{ "assetId", "lat", "lng" }` (built-in photo markers) | |
| `map.featureTapped` | `{ "plugin", "layer", "featureId", "feature", "lat", "lng", "data" }` (plugin layers) | |
| `search.performed` | `{ "filter", "page", "count", "total", "nextPage" }` | |
| `search.cleared` | `{}` | |
| `search.typeChanged` | `{ "type": "context"\|"filename"\|"description"\|"ocr" }` | |
| `lockedFolder.unlocked` | `{ "method": "pin"\|"biometric" }` | |
| `lockedFolder.locked` | `{ "reason": "paused"\|"closed" }` | |
| `private.unlocked` | `{}` | |
| `private.locked` | `{ "reason": "button"\|"hidden" }` | |

## Map layers

Plugins draw markers, polylines and areas on the map page with tap actions, kept for the app session (also while
the map is closed):

```json
{ "markers":   [{ "id", "lat", "lng", "color"?, "radius"?, "opacity"?, "label"?, "labelColor"?, "action"?, "data"? }],
  "polylines": [{ "id", "points": [[lat, lng], ...], "color"?, "width"?, "opacity"?, "action"?, "data"? }],
  "areas":     [{ "id", "points": [[lat, lng], ...] | "rings": [[[lat, lng], ...], ...], "color"?, "opacity"?,
                  "outlineColor"?, "action"?, "data"? }],
  "visible"?: true, "minZoom"?, "maxZoom"?, "action"? }
```

Points may also be `{ "lat", "lng" }`. Colors are `#AARRGGBB`, `#RRGGBB` or CSS colors. `action` (per feature, or
the layer default) is `{ "method", "params"? }` (the plugin is called with `{ "layer", "featureId", "feature",
"lat", "lng", "data", "params" }`) or `{ "command": { ...command } }` (e.g. `openAsset`, `openUiPage`). Taps also
emit `map.featureTapped` and run through `map.featureTap`. Layer ids are per plugin.

## Host functions

| Name | Args | Result |
| --- | --- | --- |
| `albums.open` | `[albumId, { kind?: "remote"\|"app"\|"device" }]` | bool (opens the album page) |
| `albums.openList` | `[{ kind?: "remote"\|"device" }]` | true |
| `albums.openOptions` | `[albumId]` | bool |
| `albums.openCreate` | `[]` | true |
| `albums.openActivities` | `[albumId, { assetId? }]` | bool |
| `albums.pick` | `[{ title? }]` | Album (remote) or null: the app's album picker sheet |
| `albums.pickUsers` | `[albumId]` | `[userId]` or null: the invite picker (does not share) |
| `people.open` | `[personId]` | bool |
| `people.openList` | `[]` | true |
| `people.editName` | `[personId]` | new name or null (built-in dialog; saves) |
| `people.editBirthday` | `[personId]` | ISO date or null (built-in dialog; saves) |
| `places.open` | `[city]` | true |
| `places.openList` | `[{ lat?, lng? }]` | true |
| `places.list` | `[]` | `[Place]` |
| `search.open` | `[SearchFilter?]` | true (opens search, applying the filter) |
| `search.setFilter` | `[SearchFilter]` | true (applies to the open search page) |
| `search.run` | `[SearchFilter, { page? }]` | `{ "assets": [Asset], "nextPage" }` (through `search.query`) |
| `search.state` | `[]` | `{ "filter", "count", "nextPage", "loading" }` of the search page |
| `map.open` | `[{ lat?, lng? }]` | true |
| `map.pickLocation` | `[{ lat?, lng? }]` | `{ "lat", "lng" }` or null |
| `map.layers.set` | `[layerId, layer]` | `{ "layer", "features" }` |
| `map.markers.set` | `[layerId, [marker]]` | `{ "layer", "features" }` |
| `map.layers.setVisible` | `[layerId, bool]` | bool |
| `map.layers.remove` | `[layerId]` | bool |
| `map.layers.clear` | `[]` | count removed (this plugin's) |
| `map.layers.list` | `[]` | `[layer]` (this plugin's) |
| `map.camera.get` | `[]` | `{ "lat", "lng", "zoom", "bounds" }`, null without an open map |
| `map.camera.move` | `[{ lat, lng, zoom?, animate? } \| { zoom } \| { bounds, padding? }]` | bool |
| `map.settings.get` | `[]` | MapSettings |
| `map.settings.set` | `[partial MapSettings]` | MapSettings |
| `folders.open` | `[path?]` | bool (root without a path) |
| `folders.list` | `[path?]` | `[Folder]` (subfolders) |
| `partners.list` | `[{ direction?: "sharedWith"\|"sharedBy" }]` | `[Partner]` |
| `partners.open` | `[userId]` | bool |
| `partners.openList` | `[]` | true |
| `sharedLinks.list` | `[]` | `[SharedLink]` |
| `sharedLinks.open` | `[linkId?]` | bool (the list without an id) |
| `sharedLinks.openCreate` | `[{ albumId?, assetIds? }]` | true |
| `library.open` | `[]` | true |
| `lockedFolder.open` | `[]` | true (asks for the PIN) |
| `private.open` | `[]` | true |
| `private.isUnlocked` | `[]` | bool |
| `private.lock` | `[]` | true |
| `downloads.open` | `[]` | true |

Album, asset, person, tag and shared link data operations (create, update, delete, add assets, ...) are data area
host functions (`data.md`).

## Status

Wired: ids and built-in lists, every hook and event above, page-view queries, map layers (rendering, taps through the
plugin that drew the feature, camera), every host function (registered with the kernel), hide and order rules from
`contributes.builtins` on every arranged list.
Also wired: plugin buttons, menu entries, tiles and sections merged into every arranged widget list (by slot suffix:
`.actions` buttons, `.menu` entries, else tiles), badge/wrap/replace decorations on album, place and people tiles.
Not yet: decorations on the remaining tiles (partner, folder, shared link), long-press menus.
