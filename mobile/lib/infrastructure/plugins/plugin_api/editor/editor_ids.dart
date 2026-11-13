/// Ids the image editor exposes to plugins: tool surface, slots, hooks, events and host functions.
///
/// Documented in `docs/plugins/editor.md`. Slot ids follow the page naming rule (`EditImageRoute` -> `editImage`).
library;

abstract final class EditorPluginIds {
  /// `contributes.tools[].surface` for image editor tools.
  static const toolSurface = 'editor.image';

  /// Call type of editor tool methods.
  static const toolCallType = 'EditorToolV1';

  /// JSON UI surface id of a plugin tool panel: `editor.tool.<tool id>` (scoped to the plugin by the kernel).
  static String panelSurface(String toolId) => 'editor.tool.$toolId';

  // ---- slots ---------------------------------------------------------------------------
  /// Tool selector. Built-in ids: [EditorBuiltinToolIds.all]. Plugin tools come from `contributes.tools`.
  static const toolsSlot = 'editImage.tools';
  static const appBarActions = 'editImage.appBar.actions';
  static const appBarMenu = 'editImage.appBar.menu';
  static const cropControls = 'editImage.crop.controls';
  static const mosaicControls = 'editImage.mosaic.controls';
  static const header = 'editImage.header';
  static const footer = 'editImage.footer';
  static const body = 'editImage.body';
  static const overlay = 'editImage.overlay';

  // ---- hooks ---------------------------------------------------------------------------
  static const openHook = 'editor.open';
  static const saveHook = 'editor.save';
  static const toolApplyHook = 'editor.tool.apply';

  // ---- events --------------------------------------------------------------------------
  static const openedEvent = 'editor.opened';
  static const toolChangedEvent = 'editor.toolChanged';
  static const imageChangedEvent = 'editor.imageChanged';
  static const savedEvent = 'editor.saved';
  static const closedEvent = 'editor.closed';

  // ---- host functions ------------------------------------------------------------------
  static const hostOpen = 'editor.open';
  static const hostClose = 'editor.close';
  static const hostState = 'editor.state';
  static const hostSetTool = 'editor.setTool';
  static const hostApply = 'editor.apply';
  static const hostPreview = 'editor.preview';
  static const hostApplyImage = 'editor.applyImage';
  static const hostUndo = 'editor.undo';
  static const hostSource = 'editor.source';
  static const hostSave = 'editor.save';
}

abstract final class EditorBuiltinToolIds {
  static const crop = 'crop';
  static const mosaic = 'mosaic';

  static const all = [crop, mosaic];
}

/// Built-in item ids of the editor's bars, usable in `contributes.builtins` rules.
abstract final class EditorBuiltinItemIds {
  // editImage.appBar.actions
  static const save = 'save';
  static const undoTool = 'undoTool';

  // editImage.crop.controls
  static const rotateLeft = 'rotateLeft';
  static const rotateRight = 'rotateRight';
  static const flipHorizontal = 'flipHorizontal';
  static const flipVertical = 'flipVertical';
  static const aspectRatios = 'aspectRatios';

  // editImage.mosaic.controls
  static const brush = 'brush';
  static const eraser = 'eraser';
  static const undo = 'undo';
  static const redo = 'redo';
  static const styles = 'styles';
  static const brushSize = 'brushSize';
  static const blockSize = 'blockSize';
}
