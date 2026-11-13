# Timeline, selection, actions, app menu and tabs

Everything the timeline area exposes to plugins. Ids live in code in
`lib/presentation/actions/action_ids.dart` (`ActionIds`, `ActionSlots`, `SelectionSheets`) and
`lib/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart` (`TimelinePages`, `TimelineSlots`,
`TimelineItemIds`, `TimelineHooks`, `TimelineEvents`, `TimelineHostNames`).

Rules (`contributes.builtins.<slot>`: `hide`, `order`, `rename`) work on every slot below that lists built-in ids.
In `order`, `*` marks where unnamed items go; plugin items are named `plugin:<plugin>/<id>`. Plugin items without
`order` go after the built-ins; built-in `i` (in the order listed here) has order `(i + 1) * 100`.

## Asset JSON (timeline)

Slot contexts, hook arguments and host results use a synchronous AssetV1 subset:
`{ "id", "localId", "remoteId", "type": "IMAGE|VIDEO|AUDIO|OTHER", "originalFileName", "checksum", "fileCreatedAt",
"fileModifiedAt", "localDateTime", "width", "height", "durationMs", "isFavorite", "isEdited",
"storage": "local|remote|merged", "isLocal", "isRemote", "playbackStyle" }`, plus for server assets `"ownerId",
"visibility", "stackId", "livePhotoVideoId", "deletedAt", "isTrashed", "isArchived"` and for device assets
`"latitude", "longitude", "orientation"`. A plugin names an asset by `id`, `localId` or `remoteId`. The full AssetV1
comes from `assets.get`.

## Slots

| Slot | Kinds | Context | Built-in ids |
| --- | --- | --- | --- |
| `selection.actions` | `button`, `menuItem` | `sheet`, `selectionCount`, `assets` | every action of the sheet (below) |
| `selection.<sheet>.actions` | `button`, `menuItem` | as above | see the sheet table |
| `selection.sections` | `section`, `view` | `sheet`, `selectionCount` | `addToAlbum` (the album picker) |
| `selection.status` | `button`, `toggle` | `selectionCount`, `total`, `origin` | `clear`, `selectAll` |
| `viewer.addMenu` | `menuItem` | `assets` | `album`, `archive`, `lock` |
| `app.appBar.actions` | `button`, `toggle` | | `settings`, `menu` |
| `app.menu` | `menuItem` | | `settings`, `plugins`, `trash`, `lockedFolder` (with a server), `appLogs` |
| `<page>.appBar.actions` | `button`, `toggle` | `page` (+ page fields) | per page, below |
| `<page>.appBar.menu` | `menuItem` | `page` | per page, below |
| `<page>.header`, `timeline.header` | `section`, `view` | `page`, `origin`, `total`, `selectionCount` | |
| `<page>.footer`, `timeline.footer` | `section`, `view` | as header | |
| `<page>.empty`, `timeline.empty` | `section`, `view` | as header (shown when the timeline has no assets) | |
| `<page>.fab` | `section`, `view`, `button` | `page`, `origin` | (download status button stays) |
| `<page>.body` | `wrap`, `replace` | as header | |
| `timeline.tile` | `badge`, `wrap`, `replace` | `page`, `origin`, `index`, `selected`, `width`, `height`, `asset` | |
| `timeline.groupHeader` | `badge`, `wrap`, `replace` | `page`, `origin`, `header` (`month`, `day`, `monthAndDay`), `group` (`firstIndex`, `count`, `date`, `title`?, `subtitle`?, `label`?, `large`?) | `title`, `selectGroup` |
| `tabShell.tabs` | `tab` (or `contributes.tabs`) | | `photos`, `albums`, `private` |
| `deviceTrash.selection.actions` | `button` | `selectionCount`, `items` | `restore`, `deleteForever` |

Tiles and group headers are decorated with app-rendered JSON UI (`uiMethod`/`ui`), never one native view per tile.
Tiles show whatever the shared thumbnail providers return, so `image.thumbnail` hooks (viewer area) apply.

Sheets (`<sheet>` of `selection.<sheet>.actions`) and their built-ins in order:

| Sheet | Built-in action ids |
| --- | --- |
| `general` (main timelines, map, people, places, search) | `advancedInfo`, `share`, `shareLink`, `download`, `delete`, `favorite`, `archive`, `tag`, `editDateTime`, `editLocation`, `lock`, `stack`, `deleteLocal`, `upload` |
| `deviceLibrary` (Photos tab, device albums) | `share`, `addToAppAlbum`, `removeFromAppAlbum` (in an app album), `deviceFavorite`, `moveToPrivate`, `plugins`, `delete` |
| `archive` | `advancedInfo`, `share`, `shareLink`, `archive`, `favorite`, `download`, `delete`, `editDateTime`, `editLocation`, `lock`, `stack`, `deleteLocal` |
| `favorite` | `advancedInfo`, `share`, `shareLink`, `favorite`, `archive`, `download`, `delete`, `editDateTime`, `editLocation`, `lock`, `stack`, `deleteLocal` |
| `localAlbum` | `advancedInfo`, `share`, `delete`, `deleteLocal`, `upload` |
| `partner` | `advancedInfo`, `share`, `download` |
| `remoteAlbum` | `advancedInfo`, `share`, `shareLink`, `archive`, `favorite`, `download`, `delete`, `editDateTime`, `editLocation`, `lock`, `stack`, `deleteLocal`, `removeFromAlbum`, `setAlbumCover` (owner-only ones only for the album owner) |
| `lockedFolder` | `advancedInfo`, `share`, `download`, `delete`, `lock` |
| `trash` | `advancedInfo`, `delete`, `restoreTrash` |
| `private` | `share`, `moveToPrivate`, `delete` |

An action only shows when it applies to the selection (a built-in may be absent even when not hidden).

Pages (`<page>`): `mainTimeline` (actions: `galleryView`; then `app.appBar.actions`), `archive`, `favorite`,
`recentlyAdded`, `recentlyTaken`, `localTimeline` (actions: `galleryView`), `trash` (menu: `emptyTrash`, `restoreAll`),
`assetSelectionTimeline`, `cleanupPreview`, `deviceTrash` (actions: `selectAll`; header, footer, empty),
`localMediaSummary`, `remoteMediaSummary`. Any other page that shows a `Timeline` with `page:` gets the same
timeline slots. Legacy button slots keep working: `main.appBar`, `album.appBar`, `selection` (the Plugins action),
`viewer.topBar`.

## Hooks

| Hook | Args | Result | Cancellable |
| --- | --- | --- | --- |
| `action.<actionId>` | `{ "actionId", "source"?: "timeline"\|"viewer", "assetIds", "assets": [asset], ...extra }` | none | yes: `before` → `{ "cancel": true, "message"? }`; `instead` replaces the action |
| `timeline.query` | `{ "origin", "groupBy": "day"\|"month"\|"none", "total", "albumId"?, "place"?, "personId"?, "galleryView"? }` | `{ "assets": [asset or id], "groups"?: [{ "title"?, "subtitle"?, "label"?, "date"?, "large"?, "count" }] }` | no (a cancel shows the timeline unchanged) |
| `timeline.openAsset` | `{ "page", "origin", "index", "asset" }` | none | yes; `instead` replaces opening the viewer |
| `tab.select` | `{ "id", "previous" }` | tab id (string) | yes; `before` may redirect with `{ "args": { "id": other } }` |

`action.<actionId>` exists for every id in `ActionIds.all` and `ActionIds.pageActions`: `addToAppAlbum`,
`advancedInfo`, `archive`, `cast`, `delete`, `deleteLocal`, `deviceFavorite`, `download`, `edit`, `editDateTime`,
`editLocation`, `favorite`, `lock`, `moveToPrivate`, `openInBrowser`, `partnerAdd`, `partnerRemove`, `passkeyCreate`,
`passkeyDelete`, `passkeyRename`, `plugins`, `removeFromAlbum`, `removeFromAppAlbum`, `restoreTrash`,
`setAlbumCover`, `setProfilePicture`, `share`, `shareLink`, `similarPhotos`, `slideshow`, `stack`, `tag`, `untag`,
`upload`, `emptyTrash`, `restoreAllTrash`, `deviceTrashRestore`, `deviceTrashDelete`. Toggle actions keep one id
(`archive` = archive/unarchive, `favorite`, `lock`, `stack`, `moveToPrivate`). Extra args: `addToAppAlbum`
`currentAlbumId`; `removeFromAppAlbum`, `removeFromAlbum`, `setAlbumCover` `albumId`; `untag` `tagId`;
`similarPhotos` `assetId`; `openInBrowser` `remoteId`, `origin`; `partnerRemove` `sharedWithId`, `partnerName`;
`passkeyRename`, `passkeyDelete` `passkeyId`; `emptyTrash`, `restoreAllTrash` `userId`; `deviceTrashRestore`,
`deviceTrashDelete` `items: [{ "id", "name", "isVideo", "expires" }]`. Argument changes from `before` are ignored.

`timeline.query`: `after` returns `{ "result": { "assets": [...], "groups": [...] } }`. A subset of assets filters,
another order sorts, unknown ids are dropped. Without valid `groups` (counts must add up to the assets) the app
groups by `groupBy`; a `before` handler may change `groupBy`. Groups get their own header (`title`, `subtitle`,
`large` for a big header, no header without both) and scrubber `label`. Gallery views (`GalleryViewV1`) are applied
first and passed as `galleryView`. While any plugin hooks `timeline.query`, every timeline loads all its assets to
run the hook.

## Events

| Event | Payload | Throttle |
| --- | --- | --- |
| `selection.changed` | `{ "page", "origin", "enabled", "count", "assetIds" }` | none |
| `tab.selected` | `{ "id", "previous" }` | none |
| `timeline.reloaded` | `{ "origin", "total" }` | none |
| `timeline.scrolled` | `{ "page", "origin", "firstIndex", "lastIndex", "total" }` | 4/s |
| `action.performed` | `{ "id", "source"?, "assetIds" }` (after the action ran, not when cancelled) | none |

## Host functions

They act on the visible timeline (else the last one opened), the visible action bar and the home tabs.

| Name | Args | Result |
| --- | --- | --- |
| `timeline.refresh` | `[]` | `bool` (runs `timeline.query` again) |
| `timeline.scrollTo` | `[assetId]` or `[{ "assetId"? , "index"?, "date"? }]` | `bool` |
| `timeline.visibleRange` | `[]` | `{ "page", "origin", "firstIndex", "lastIndex", "total", "assetIds" }` or null |
| `timeline.current` | `[]` | `{ "page", "origin", "total", "visible" }` or null |
| `timeline.assets` | `[{ "offset"?, "limit"? }]` (default 0, 100) | `[asset]` in display order |
| `selection.get` | `[]` | `{ "enabled", "count", "assetIds" }` |
| `selection.set` / `selection.add` / `selection.remove` | `[[assetId]]` | new count |
| `selection.clear` | `[]` | `true` |
| `selection.all` | `[]` | new count |
| `actions.list` | `[{ "surface"?: "selection"\|"viewer" }]` | `[{ "id", "label", "icon" (code point), "builtin" }]` that apply now |
| `actions.run` | `[actionId, [assetId]?, { "surface"? }?]` or `[{ "id", "assetIds"?, "surface"? }]` | `bool` (selects `assetIds` first) |
| `tabs.list` | `[]` | `[{ "id", "title", "builtin", "selected" }]` |
| `tabs.select` | `[tabId]` | `bool` |
