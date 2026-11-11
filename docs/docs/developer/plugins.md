---
sidebar_position: 9
---

# Plugins

Plugins add **filters** and **actions** that people can use as steps in [workflows](#rest-api). A plugin is a WebAssembly module (built with [Extism](https://extism.org/)) plus a `manifest.json` that describes its methods. The server runs plugins in a sandbox and passes data to them as JSON. A plugin can only reach the rest of Immich through a small set of [host functions](#host-functions).

:::warning Status
The plugin system is an early preview. The manifest format, SDK and host functions can still change between releases, the SDK is not published to npm, and there is no UI or API to install, enable or remove plugins. Expect to rebuild plugins when you upgrade.
:::

## How it works

```
 manifest.json + plugin.wasm          (folder per plugin)
          │  imported at startup by the microservices worker
          ▼
 plugin / plugin_method tables         (stored in Postgres, wasm bytes included)
          │  loaded into an Extism instance pool (1–5 instances per plugin)
          ▼
 trigger fires ─▶ WorkflowAssetTrigger job ─▶ for each enabled step, in order:
     build payload { trigger, type, data, config, workflow } ─▶ call plugin method
     ◀─ response { workflow.continue, changes, data, config }
         changes  → applied to the asset as the workflow owner, then data is re-read
         continue → false stops the workflow (this is how filters work)
         config   → saved back onto the step
```

- **Filters** look at `data` and return `{ workflow: { continue: false } }` to stop the workflow.
- **Actions** either return `changes`, which the server applies, or call host functions such as `addAssetsToAlbum` or `editAsset`.
- Each step runs as the **workflow owner**. Host functions get a short-lived token for that user, so they have the same access checks as that user's REST calls.
- A method that doesn't set `hostFunctions: true` runs in an instance where every host function throws. Methods that do set it run in a separate instance, in a worker thread.

## Project layout

Start by copying `packages/plugin-core`:

```
my-plugin/
├── manifest.json      # metadata, methods, config schemas, templates
├── package.json       # devDeps: @immich/plugin-sdk, @immich/sdk, @extism/js-pdk, esbuild, typescript
├── esbuild.js         # bundle to CJS, target es2020 (QuickJS limit)
├── tsconfig.json
└── src/index.ts       # method implementations
```

`package.json` scripts:

```json
{
  "build": "pnpm build:tsc && pnpm build:wasm",
  "build:tsc": "plugin-sdk prepareBuild && tsc --noEmit && node esbuild.js",
  "build:wasm": "extism-js dist/index.js -i dist/index.d.ts -o dist/plugin.wasm"
}
```

`plugin-sdk prepareBuild` reads `manifest.json` and writes `dist/index.d.ts`. That file declares the host-function imports for `extism-js` and exports the manifest as a `Manifest` type, which types each method's `config`.

### Toolchain

| Tool | Version | Notes |
| --- | --- | --- |
| Node + pnpm | see root `mise.toml` | |
| `extism-js` | js-pdk v1.7.0 | Compiles the JS bundle to WASM (QuickJS) |
| binaryen (`wasm-opt`, `wasm-merge`) | version_124 | Must be on `PATH` for `extism-js` |

Inside the monorepo, run `mise //:plugins`. That installs and builds `@immich/sdk`, `@immich/plugin-sdk` and `@immich/plugin-core`. Outside the monorepo, link or pack `packages/plugin-sdk` and `packages/sdk`, since neither is on npm.

## Manifest reference

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "title": "My Plugin",
  "description": "What it does",
  "author": "You",
  "wasmPath": "dist/plugin.wasm",
  "methods": [ /* see below */ ],
  "templates": [ /* optional, see below */ ]
}
```

| Field | Rules |
| --- | --- |
| `name` | Lowercase letters, digits and `-`, and can't end with `-`. Must be unique across all plugins. Steps refer to methods as `name#method`. |
| `version` | Semver. Bumping it upgrades the plugin in place: methods keep their ids, so existing workflows keep working. |
| `wasmPath` | Relative to the plugin folder. |

### Methods

```json
{
  "name": "assetEdit",
  "title": "Edit image",
  "description": "Rotate, mirror, or reset edits on an image",
  "types": ["AssetV1"],
  "hostFunctions": true,
  "allowedHosts": [],
  "uiHints": ["Filter"],
  "schema": { "type": "object", "properties": { ... }, "required": [ ... ] }
}
```

| Field | Meaning |
| --- | --- |
| `name` | Must match a function exported from `src/index.ts`. |
| `types` | Data types the method accepts. Only `AssetV1` exists today. The UI only offers a method for triggers whose type it supports. |
| `hostFunctions` | Must be `true` for the method to call any [host function](#host-functions). |
| `allowedHosts` | Hostnames `httpRequest` may contact. `*` is a wildcard (`*.example.com`, or `*` for any host). Matching is anchored to the whole hostname. |
| `uiHints` | `["Filter"]` puts the method in the filter list in the workflow editor. |
| `schema` | The config schema. The editor builds the step's settings form from it, and it types `config` in your code. |

#### Config schema

The schema uses a subset of JSON Schema, plus a few Immich extensions:

| Key | Use |
| --- | --- |
| `type` | `string`, `number`, `boolean`, `object` |
| `array: true` | Makes the value an array of `type`. This is an Immich extension, used instead of `type: "array"`. |
| `enum` | Allowed string values. Shown as a select. |
| `default`, `title`, `description` | Shown in the form. |
| `minimum`, `maximum`, `precision` | Number inputs. |
| `properties`, `required` | Nested objects. |
| `uiHint.order` | Order of fields in the form. |
| `uiHint.type` | Picker to use: `AlbumId`, `TagId`, `TagValue`, `PersonId`, `AssetId`. |

### Templates

Templates are ready-made workflows that appear in the "new workflow" picker:

```json
{
  "name": "receipts",
  "title": "Receipts",
  "description": "Automatically add receipt assets to an album",
  "trigger": "AssetOcrExtraction",
  "steps": [
    { "method": "immich-plugin-core#assetOcrFilter", "config": { "pattern": "receipt.+total", "matchType": "regex" } },
    { "method": "immich-plugin-core#assetAddToAlbums", "config": { "albumName": "Receipts", "albumIds": [] } }
  ],
  "uiHints": ["SmartAlbum"]
}
```

## Writing methods

```ts
import { wrapper } from '@immich/plugin-sdk';
import type { Manifest } from '../dist/index.d.ts';

const methods = wrapper<Manifest>({
  // filter: stop the workflow unless the file is a PNG
  onlyPng: ({ data }) => ({
    workflow: { continue: data.asset.originalFileName.toLowerCase().endsWith('.png') },
  }),

  // action via changes: the server applies these to the asset
  favorite: ({ data }) => (data.asset.isFavorite ? {} : { changes: { asset: { isFavorite: true } } }),

  // action via host functions (requires "hostFunctions": true)
  rotateUpright: ({ data, functions }) => {
    functions.editAsset(data.asset.id, [{ action: 'rotate', parameters: { angle: 90 } }]);
    return {};
  },
});

// Every method must be exported by name for extism-js.
export const { onlyPng, favorite, rotateUpright } = methods;
```

Code runs **synchronously** in QuickJS, at ES2020. There's no `fetch`, `fs` or `process`; use host functions instead. `console.log`, `console.debug` and similar go to the server log under `Plugin:<name>@<version>`.

### Input payload

```ts
{
  trigger: 'AssetCreate' | 'AssetMetadataExtraction' | 'AssetOcrExtraction' | 'AssetTagged';
  type: 'AssetV1';
  data: AssetV1;               // see below
  config: /* the step's config, typed from your schema */;
  workflow: { id: string; stepId: string; authToken: string; debug?: boolean };
  functions: HostFunctions;    // added by wrapper()
}
```

### Response

All fields are optional. Returning nothing, or `{}`, means "continue with no changes".

| Field | Effect |
| --- | --- |
| `workflow.continue` | `false` stops the workflow, and the run is logged as `Halted`. |
| `changes.asset` | Applied as the owner. Supported fields: `isFavorite`, `visibility`, `exifInfo.dateTimeOriginal`, `exifInfo.latitude`, `exifInfo.longitude`, `exifInfo.description`, `exifInfo.rating`. After the change is applied, `data` is re-read for the next step. |
| `data` | Reserved, for passing data to later steps. It isn't used yet. |
| `config` | Saved as the step's new config. If you modify `config` in place, it's saved automatically. For example, `assetAddToAlbums` uses this to store the id of the album it creates. |

Throwing an error, or calling a host function that fails, fails the run. The run is logged as `Error` and later steps don't run.

### `AssetV1` data

`data.asset` includes the following fields. See `packages/plugin-sdk/src/types.ts` for the full type.

- **Identity:** `id`, `ownerId`, `type` (`IMAGE`/`VIDEO`/…), `originalFileName`, `originalPath`, `checksum`
- **Dates:** `fileCreatedAt`, `fileModifiedAt`, `localDateTime`, `createdAt`, `updatedAt`, `deletedAt`
- **State:** `isFavorite`, `visibility`, `isOffline`, `isExternal`, `isEdited`, `libraryId`, `stackId`, `duplicateId`, `livePhotoVideoId`
- `tags[]`: `id`, `value` (full path, e.g. `Places/Canada`), `name`, …
- `exifInfo`: camera and lens, dimensions (`exifImageWidth`/`exifImageHeight`), `orientation`, GPS and `city`/`state`/`country`, `timeZone`, `rating`, `description`, `projectionType`, …
- `ocr[]`: `text`, `textScore`, `boxScore`. Only present for `AssetOcrExtraction`.

Plugins get metadata only. They can't read pixel data or files.

## Host functions

All of these are available on `functions` when the method sets `hostFunctions: true`. They run as the workflow owner, use the same service code as the REST API (so the same access checks apply), and throw on failure.

| Function | REST equivalent | Returns |
| --- | --- | --- |
| `searchAlbums(dto)` | `GET /albums` | `AlbumResponseDto[]` |
| `createAlbum(dto)` | `POST /albums` | `AlbumResponseDto` |
| `addAssetsToAlbum(albumId, assetIds)` | `PUT /albums/:id/assets` | `BulkIdResponseDto[]` |
| `addAssetsToAlbums({ albumIds, assetIds })` | `PUT /albums/assets` | result |
| `bulkTagAssets({ tagIds, assetIds })` | `PUT /tags/assets` | `TagBulkAssetsResponseDto` |
| `httpRequest(url, { method, headers, body })` | — (outbound) | `{ ok, status, body }`. The host must match `allowedHosts`. |
| `getAssetEdits(assetId)` | `GET /assets/:id/edits` | `AssetEditsResponseDto` |
| `editAsset(assetId, edits)` | `PUT /assets/:id/edits` | `AssetEditsResponseDto` |
| `removeAssetEdits(assetId)` | `DELETE /assets/:id/edits` | — |

### Image editing

The three edit functions connect plugins to the same non-destructive edit system the web editor uses. Edits are stored as a list of actions. After `editAsset` or `removeAssetEdits`, the server queues `AssetEditThumbnailGeneration`, which regenerates the thumbnails and preview. The original file is never changed.

```ts
type AssetEditActionItemDto =
  | { action: 'crop';   parameters: { x: number; y: number; width: number; height: number } }
  | { action: 'rotate'; parameters: { angle: 0 | 90 | 180 | 270 } }
  | { action: 'mirror'; parameters: { axis: 'horizontal' | 'vertical' } };
```

Rules, enforced by the server:

- **`editAsset` replaces the whole list.** To change one action and keep the rest, read the current list with `getAssetEdits`, change it, and send it all back. Remove the `id` fields before sending.
- **`crop` must come first** and must fit within `exifInfo.exifImageWidth` × `exifInfo.exifImageHeight`.
- **Each action at most once.** `mirror` can appear once per axis.
- **Images only.** Videos, live photos, panoramas, GIF and SVG are rejected. Check `data.asset.type`, `livePhotoVideoId` and the file extension first if you don't want the run to fail.

The core plugin's `immich-plugin-core#assetEdit` step uses these functions and shows the read-merge-write pattern. Its config takes `rotate` (`keep|0|90|180|270`), `mirror` (`keep|none|horizontal|vertical|both`) and `reset`.

## Installing a plugin

1. Put the plugin in its own folder: `<install folder>/<plugin>/manifest.json` and the `.wasm` file at the manifest's `wasmPath`.
2. Set these on the `immich-server` container (both are needed):
   ```
   IMMICH_ALLOW_EXTERNAL_PLUGINS=true
   IMMICH_PLUGINS_INSTALL_FOLDER=/usr/src/app/plugins   # absolute path inside the container
   ```
3. Restart. At startup the microservices worker imports each subfolder. A plugin is skipped if its manifest hash hasn't changed. The worker then loads all enabled plugins.
4. Check the logs for `Imported plugin …`, `Upgraded plugin …`, `Invalid plugin manifest …` or `Failed to import plugin …`.

:::tip Reloading during development
The manifest **hash** decides whether a plugin is re-imported, and the `.wasm` file isn't part of the hash. If you only rebuilt the WASM, change something in the manifest (for example the version) or the server keeps the old bytes. In development (`IMMICH_ENV=development`) the core plugin is always re-imported. The dev compose file mounts `packages/plugin-core` into the container.
:::

## REST API

All endpoints need an authenticated user. They're listed in the OpenAPI spec under the **Plugins** and **Workflows** tags.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/plugins` | List plugins (filter by `name`, `version`, …) |
| GET | `/plugins/:id` | Get one plugin, including its methods |
| GET | `/plugins/methods?trigger=…&type=…` | List methods, optionally only those compatible with a trigger |
| GET | `/plugins/templates` | List workflow templates from all plugins |
| GET | `/workflows/triggers` | List triggers and their data types |
| GET/POST | `/workflows` | List or create workflows |
| GET/PUT/PATCH/DELETE | `/workflows/:id` | Read, replace, update or delete a workflow |
| GET | `/workflows/:id/share` | Export a workflow without ids, for sharing |
| GET | `/workflows/:id/logs` | Run history (`Completed`, `Halted`, `Error`), recorded when `logging: true` |

Creating a workflow:

```json
POST /api/workflows
{
  "trigger": "AssetCreate",
  "name": "Rotate scans",
  "enabled": true,
  "logging": true,
  "steps": [
    { "method": "immich-plugin-core#assetFileFilter", "config": { "pattern": "scan", "matchType": "startsWith" } },
    { "method": "immich-plugin-core#assetEdit", "config": { "rotate": "90", "mirror": "keep" } }
  ]
}
```

Steps run in the order given. `method` is `pluginName#methodName`. A step whose `types` don't match the trigger is rejected.

## Triggers

| Trigger | Fires when | Notes |
| --- | --- | --- |
| `AssetCreate` | An asset is uploaded or imported | Runs before metadata extraction, so EXIF may be empty. |
| `AssetMetadataExtraction` | Metadata extraction finishes | Also fires on rescans and for external libraries, which can mean a lot of runs. Doesn't fire for sidecar writes, to avoid loops. |
| `AssetOcrExtraction` | OCR finishes | `data.asset.ocr` is filled in. |
| `AssetTagged` | A tag is added to an asset | |

## Debugging

- Set `IMMICH_LOG_LEVEL=debug` to log each step's inputs and outputs (`Inputs: …` / `Outputs: …`) under `Plugin:<name>@<version>`.
- Turn on `logging` on the workflow and read `GET /workflows/:id/logs`.
- If a WASM instance crashes (for example `memory access out of bounds`), it's discarded and the pool creates a new one. Only that run fails ([#30625](https://github.com/immich-app/immich/issues/30625)).

## Limitations

- Only the `AssetV1` data type and the four asset triggers exist.
- `changes` covers a limited set of fields. Use host functions for anything else.
- No pixel or file access. Plugins can't analyse or produce image content.
- No install/enable/uninstall API. The `enabled` column exists but nothing sets it.
- Plugin versions aren't yet tied to workflow compatibility. Only one version of each plugin is loaded.
