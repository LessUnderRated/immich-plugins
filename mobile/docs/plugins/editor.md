# Editor

The image editor (`EditImageRoute`) edits photos non-destructively (crop, rotate, mirror, mosaic) and hosts plugin
tools that may produce an image of any size (upscalers, filters, AI erase, ...). Plugins add tools, panels, bar
items and hooks; built-in items have ids and can be hidden or reordered.

## Tools

Tools of the selector: built-ins `crop` (crop, rotate, mirror, aspect ratio) and `mosaic` (censor brush, styles from
`CensorStyleV1` methods, unchanged), then plugin tools from `contributes.tools` with `"surface": "editor.image"`.
Hide or reorder any of them with `contributes.builtins["editImage.tools"]` (`hide`, `order`; plugin tool ids are
`plugin:<plugin>/<id>`; `"..."` in `order` sends the following ids to the end).

```json
"tools": [{
  "id": "upscale", "surface": "editor.image", "title": "Upscale", "subtitle": "Real-ESRGAN, anime models",
  "icon": "auto_awesome", "method": "upscaleTool", "uiMethod": "upscalePanel", "order": 10,
  "when": { "isImage": true },
  "params": { "source": "rgba", "preview": true, "livePreview": false, "previewMaxSize": 512,
              "task": true, "cancellable": true, "applyLabel": "Upscale", "taskTitle": "Upscaling", "config": {} }
}]
```

| `params` key | Default | Meaning |
| --- | --- | --- |
| `source` | `rgba` | Source handed to `preview`/`apply`: `rgba`, `png` or `jpeg` |
| `preview` | false | The tool implements `preview` (a Preview button is shown) |
| `livePreview` | false | Re-run `preview` after every panel change (debounced) |
| `previewMaxSize` | 1024 | Longest side of the preview source |
| `task` | true | `apply` runs as a kernel Task (app progress UI and notification) |
| `cancellable` | true | The task can be cancelled |
| `applyLabel`, `taskTitle` | `title` | Apply button label, task title |
| `config` | `{}` | Passed as the call's `config` |

## EditorToolV1

Every phase calls `method` (the `panel` phase calls `uiMethod` when set) with `type: "EditorToolV1"`:

```json
{ "type": "EditorToolV1", "config": {},
  "data": {
    "phase": "panel" | "preview" | "apply" | "cancel" | "dispose",
    "tool": "upscale",
    "session": "lq3x9k2",
    "generation": 0,
    "image": { "width": 4000, "height": 3000 },
    "source": { "path": "/.../editor/lq3x9k2/3-...-source.rgba", "width": 4000, "height": 3000, "format": "rgba" },
    "state": { "model": "realesrgan-x4plus", "scale": 4 },
    "asset": AssetV1,
    "preview": { "maxSize": 512 },
    "task": { "id": "editor-lq3x9k2-0" },
    "output": { "dir": "/.../editor/lq3x9k2" },
    "limits": { "maxPixels": 67108864, "maxDimension": 65535 },
    "params": { ... }
  } }
```

| Phase | When | Fields present | Response |
| --- | --- | --- | --- |
| `panel` | tool selected | `image`, `state` (current values) | `{ "ui": tree, "state"?, "title"?, "applyLabel"? }` or `{ "view": "<native view>", "params"?, "height"? }` |
| `preview` | Preview pressed, `livePreview` change, `editor.preview` | `source` (downscaled to `preview.maxSize`), `state` | `{ "image", "region"? }`, `{ "unchanged": true }` |
| `apply` | Apply pressed, `editor.apply` | `source` (full size), `state`, `task` | `{ "image" }`, `{ "unchanged": true }`, `{ "pending": true }` |
| `cancel` | user cancelled a running `apply` | `task` | ignored |
| `dispose` | tool deselected, editor closed | | ignored |

- **Source.** Exactly what the user sees: the working image with every pending crop, rotation, mirror and mosaic
  baked in. `rgba` is raw RGBA8888, `width * height * 4` bytes, row-major, no padding, straight alpha; `png`/`jpeg`
  are encoded files. Orientation is applied, there is no metadata. The file is read-only (never modify or delete it);
  the editor deletes it after the call.
- **Results.** `"image": { "path", "width", "height", "format": "rgba" | "encoded" }`. `encoded` accepts PNG, JPEG
  and WebP (`width`/`height` optional, read from the file). Any size up to `limits` (default 64 MiP) is accepted, so
  results may be larger (upscale) or smaller than the source. Write results into `output.dir`; the editor takes
  ownership of the file (moves or copies it, then deletes the original). Raw `rgba` results are stored as PNG.
- **Preview** `region` (`{ "x", "y", "width", "height" }`, 0-1 of the source): the preview covers only that part
  (e.g. a 100 % crop of a slow upscale) and is shown over it. Hold the image to compare with the original.
- **Apply** replaces the working image: crop and mosaic restart on the new image (their pending edits are part of
  it), later tools receive it as their source, the app bar gets Undo (restores the previous image and its pending
  edits) and Reset reverts to the asset itself.
- **Long applies.** With `params.task` the app shows progress with a Cancel button in the tool panel and as a kernel
  Task. Report progress with `tasks.update(task.id, { "progress": 0..1, "message" })`. On cancel the editor stops
  waiting at once, calls the method again with `phase: "cancel"` and the same `task.id` on another thread (plugin calls
  run concurrently), and deletes the result if it still arrives.
- **Pending results.** Return `{ "pending": true }` and deliver later with `editor.applyImage(image, { "task": id })`
  (also valid before `apply` returns).
- `message` in any response is shown as a toast; `actions` run as commands. A thrown exception is shown and leaves
  the image unchanged.
- **Panels.** A `ui` tree is rendered with the app theme on surface `editor.tool.<id>`; update it any time with
  `ui.update("editor.tool.<id>", tree)` / `ui.patch`. Input values are sent as `state` with `preview` and `apply`
  and kept per tool while the editor is open. `UiEventV1` context: `{ "session", "tool", "image", "generation" }`.
  A native `view` gets `params` plus `session` and `tool`, and drives the editor with the host functions below.

## Saving

- No tool applied: the existing non-destructive save (server edits for remote assets, device edits for local ones).
- A tool applied (e.g. upscaled): the result is baked (pending edits rendered on the CPU above 8192 px per side) and
  the user is asked every time: **Save copy** (new photo, in `Pictures/Gallery Edits` for device saves) or
  **Replace original** (local JPEG/PNG photos on Android; the original stays backed up, the result becomes the base
  for later edits, `removeAssetEdits` restores the original). Server-only assets save as a copy.

## Slots

Context of every editor slot: `route` (`EditImageRoute`), `session`, `asset` (AssetV1), `assetType`, `isLocal`,
`isRemote`, `tool` (selected tool id), `generation`, `baked`, `hasUnsavedEdits`.

| Slot | Kinds | Built-in ids |
| --- | --- | --- |
| `editImage.tools` | tools come from `contributes.tools` (`editor.image`); builtins rules apply | `crop`, `mosaic` |
| `editImage.appBar.actions` | `button`, `toggle` | `undoTool`, `save` |
| `editImage.appBar.menu` | `menuItem` (the ⋮ button appears only with items) | |
| `editImage.crop.controls` | `button` | `rotateLeft`, `rotateRight`, `flipHorizontal`, `flipVertical`, `aspectRatios` |
| `editImage.mosaic.controls` | `button` | `brush`, `eraser`, `undo`, `redo`, `styles`, `brushSize`, `blockSize` |
| `editImage.header`, `editImage.footer` | `section`, `view` | |
| `editImage.overlay` | `overlay` (over the image area) | |
| `editImage.body` | `replace`, `wrap` | |

## Hooks

| Hook | Args | Result | Cancellable |
| --- | --- | --- | --- |
| `editor.open` | `{ "asset": AssetV1 }` | `{ "opened": bool, "session"? }`; `instead` returning a result means the plugin opened its own editor | yes |
| `editor.tool.apply` | `{ "session", "tool", "state", "source": image, "asset"? }` | `{ "image": image }`, `{ "unchanged": true }`; `instead` produces the image, `after` may post-process it | yes |
| `editor.save` | `{ "session", "asset", "mode": "edits" \| "baked", "edits": [edit JSON], "target"?: "copy" \| "replace" }` | `{ "target": "edits" \| "copy" \| "replace", "assetId", "createdId"? }` | yes |

`editor.save` runs before the save question: a `before` that sets `target` answers it; `instead` saves elsewhere
and the editor closes as saved. `edits` uses the `getAssetEdits` format.

## Events

| Event | Payload | Throttle |
| --- | --- | --- |
| `editor.opened` | `{ "session", "asset", "tool", "tools": [ids] }` | no |
| `editor.toolChanged` | `{ "session", "tool", "previous" }` | no |
| `editor.imageChanged` | `{ "session", "generation", "tool", "width", "height", "reason": "apply" \| "undo" \| "reset" \| "external" }` | no |
| `editor.saved` | `{ "session", "asset", "target", "assetId", "createdId"? }` | no |
| `editor.closed` | `{ "session", "saved" }` | no |

## Host functions

| Name | Args | Result |
| --- | --- | --- |
| `editor.open` | `[assetId]` (local or remote id) | `{ "opened", "session" }` |
| `editor.close` | `[{ "discard"? }]` | `true` (asks about unsaved edits unless `discard`) |
| `editor.state` | `[]` | `{ "open", "session", "assetId", "tool", "tools", "generation", "image", "edits", "baked", "history", "run"?, "preview"? }` |
| `editor.setTool` | `[toolId]` (`crop`, `mosaic`, `plugin:<p>/<id>` or the caller's own tool id) | bool |
| `editor.apply` | `[{ "tool"?, "state"? }]` | `{ "outcome": "applied" \| "unchanged" \| "cancelled", "message"? }` |
| `editor.preview` | `[{ "tool"?, "state"? }]` | `{ "region" }` or null |
| `editor.applyImage` | `[image, { "task"?, "tool"? }]` | `"delivered"` (completes a pending apply) or `"applied"` (replaces the working image) |
| `editor.undo` | `[]` | bool |
| `editor.source` | `[{ "format"?: "rgba" \| "png" \| "jpeg", "maxSize"? }]` | image (what the user sees; deleted when the editor closes) |
| `editor.save` | `[{ "target"? }]` | `{ "target", "assetId", "createdId"? }` |

## Mosaic brush styles

Unchanged: methods with `types: ["CensorStyleV1"]` (see `PLUGINS.md`). They also render on tool results of any size.
